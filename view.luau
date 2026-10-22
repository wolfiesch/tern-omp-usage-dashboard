--!strict
-- omp-usage view: pure render of a usage snapshot into native Tern nodes.
-- render(snapshot, status, nowMs, ui) -> { main = col, dock = row }.
-- `ui` is tern.ui, injected so this module never touches the tern global.

local usage = require("./usage")

type Ui = any
type UiNode = any

type Limit = usage.Limit
type Account = usage.Account
type Provider = usage.Provider
type Snapshot = usage.Snapshot

export type Status = { refreshing: boolean, error: string?, lastSuccess: number?, heartbeat: number? }

type Ctx = {
	ui: Ui,
	now: number,
	status: Status,
	-- Why retained data may no longer be current, independent of fetch age.
	retained: string?,
}

local STALE_REPORT_MS = usage.STALE_MS
local HEARTBEAT_STALE_MS = 15 * 1000
local LOW_FRACTION = usage.LOW_FRACTION

local TONE_TOKENS: { [string]: boolean } = {
	success = true,
	warning = true,
	error = true,
	info = true,
	muted = true,
	accent = true,
}

local function with(node: UiNode, props: { [string]: any }): UiNode
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function span(ctx: Ctx, t: string, s: string?): UiNode
	return ctx.ui.span(t, s)
end

local function toneToken(tone: string?): string?
	if tone ~= nil and TONE_TOKENS[tone] then
		return tone
	end
	return nil
end

local function plural(n: number, one: string, many: string): string
	return tostring(n) .. " " .. (if n == 1 then one else many)
end

local function uniqueKey(seen: { [string]: boolean }, base: string): string
	local key = base
	local n = 2
	while seen[key] do
		key = base .. "~" .. n
		n += 1
	end
	seen[key] = true
	return key
end

local function ago(now: number, at: number): string
	local d = now - at
	if d < 1000 then
		return "just now"
	end
	return usage.duration(d) .. " ago"
end

-- The collector supplies fixed actionable messages, never provider stderr or exceptions.
local function errorReason(err: string?): string
	return err or "The last refresh failed. Check omp usage, then press r."
end


local function remainingOf(l: Limit): number?
	if l.remaining ~= nil then
		return l.remaining
	end
	if l.usedFraction ~= nil then
		return 1 - l.usedFraction
	end
	return nil
end

-- "exhausted" | "low" | "ok" | "unknown"
local function severity(l: Limit): string
	local rem = remainingOf(l)
	local st = string.lower(l.status or "")
	if st == "exhausted" or st == "exceeded" or (rem ~= nil and rem <= 0) then
		return "exhausted"
	elseif st == "warning" or st == "low" or (rem ~= nil and rem < LOW_FRACTION) then
		return "low"
	elseif rem == nil then
		return "unknown"
	end
	return "ok"
end

local function remainingFill(l: Limit): number?
	local used = l.usedFraction
	if used == nil then
		local rem = l.remaining
		if rem == nil then
			return nil
		end
		used = 1 - rem
	end
	return math.clamp(1 - (used :: number), 0, 1)
end

local function staleReasons(ctx: Ctx, a: Account): { string }
	local reasons: { string } = {}
	if a.fetchedAt == nil then
		table.insert(reasons, "fetch time unknown")
	elseif ctx.now - a.fetchedAt > STALE_REPORT_MS then
		table.insert(reasons, "older than " .. usage.duration(STALE_REPORT_MS))
	end
	if ctx.retained ~= nil then
		table.insert(reasons, ctx.retained)
	end
	return reasons
end

local function limitTone(sev: string): string?
	return if sev == "exhausted" then "error" elseif sev == "low" then "warning" elseif sev == "ok" then "success" else nil
end

-- One aligned table row per quota bucket: name, remaining bar, amount, reset.
local function limitRow(ctx: Ctx, l: Limit): { any }
	local sev = severity(l)
	local tone = limitTone(sev)
	local amount = if l.amountText ~= "" then l.amountText else "not reported"
	local fill = remainingFill(l)

	local reset: { any }
	if l.resetsAt ~= nil then
		local left = l.resetsAt - ctx.now
		if left <= 0 then
			reset = { span(ctx, l.resetLabel .. " now", "warning") }
		else
			reset = { span(ctx, l.resetLabel .. " in ", "muted"), span(ctx, usage.duration(left), nil) }
		end
	else
		reset = { span(ctx, "reset not reported", "muted") }
	end

	local label: { any } = { span(ctx, l.label, if sev == "exhausted" then "error strong" elseif sev == "low" then "warning" else nil) }
	local status = string.lower(l.status or "")
	if sev == "unknown" then
		table.insert(label, span(ctx, " · unknown", "muted"))
	elseif sev == "ok" and status ~= "" and status ~= "ok" then
		table.insert(label, span(ctx, " · " .. string.sub(status, 1, 24), "muted"))
	end

	local bar: any = if fill ~= nil then { meter = { value = fill, tone = tone } } else { span(ctx, "·", "muted") }
	return {
		label,
		bar,
		{ span(ctx, amount, if fill == nil then "muted" else (toneToken(tone) or "num")) },
		reset,
	}
end

local LIMIT_COLS = {
	{ id = "quota", head = "Quota", grow = 2, truncate = "end", priority = 4 },
	{ id = "bar", head = "Remaining", grow = 3, priority = 1 },
	{ id = "left", head = "Left", align = "end", priority = 3 },
	{ id = "reset", head = "Resets in", align = "end", priority = 2 },
}

local function limitTable(ctx: Ctx, limits: { Limit }): UiNode
	local rows: { any } = {}
	for _, l in limits do
		table.insert(rows, limitRow(ctx, l))
	end
	return with(ctx.ui.table(LIMIT_COLS, rows), { key = "limits", role = "omp-usage.limits" })
end

-- Worst limit severity of an account: "exhausted" | "low" | "ok"
local function worst(a: Account): string
	local out = "ok"
	for _, l in a.limits do
		local sev = severity(l)
		if sev == "exhausted" then
			return "exhausted"
		elseif sev == "low" then
			out = "low"
		end
	end
	return out
end

local function badge(ctx: Ctx, text: string, tone: string, key: string, title: string?): UiNode
	return with(ctx.ui.badge(text, tone), { key = key, title = title })
end

local function accountNode(ctx: Ctx, a: Account, key: string): UiNode
	local ui = ctx.ui
	local badges: { UiNode } = {}
	local body: { UiNode } = {}
	local details: { UiNode } = {}
	if a.detail ~= "" then
		table.insert(details, with(ui.text({ span(ctx, a.detail, "muted") }), { key = "detail" }))
	end

	if a.state == "disabled" then
		table.insert(badges, badge(ctx, "login required", "warning", "state", "Sign in to this account again in omp."))
	elseif a.state == "unknown" then
		table.insert(badges, badge(ctx, "no usage data", "muted", "state", "No usage was reported. Refresh, or check this account's sign-in and plan in omp."))
	else
		local reasons = staleReasons(ctx, a)
		local stale = #reasons > 0
		local sev = worst(a)
		if sev == "exhausted" then
			table.insert(badges, badge(ctx, "exhausted", "error", "sev"))
		elseif sev == "low" then
			table.insert(badges, badge(ctx, "low", "warning", "sev"))
		end
		if stale then
			table.insert(badges, badge(ctx, "stale", "warning", "stale", "Stale: " .. table.concat(reasons, ", ")))
		end
		if a.savedResets ~= nil and a.savedResets > 0 then
			table.insert(badges, badge(ctx, plural(a.savedResets, "saved reset", "saved resets"), "info", "saved", "Available in omp; never used automatically."))
		end

		local fetched: { any }
		if a.fetchedAt ~= nil then
			fetched = { span(ctx, "fetched ", "muted"), span(ctx, ago(ctx.now, a.fetchedAt), if stale then "warning" else "num") }
		else
			fetched = { span(ctx, "fetch time unknown", "warning") }
		end
		if stale then
			table.insert(fetched, span(ctx, " · stale: " .. table.concat(reasons, ", "), "warning"))
		end
		table.insert(if stale then body else details, with(ui.text(fetched), { key = "fetched" }))

		if #a.limits == 0 then
			table.insert(body, with(ui.text({ span(ctx, "No quota buckets reported.", "muted") }), { key = "empty" }))
		else
			table.insert(body, limitTable(ctx, a.limits))
			for i, l in a.limits do
				if #l.notes > 0 then
					table.insert(details, with(ui.text({ span(ctx, l.label .. ": " .. table.concat(l.notes, " · "), "muted") }), { key = "lnote" .. i }))
				end
			end
		end
	end

	for i, note in a.notes do
		table.insert(details, with(ui.text({ span(ctx, note, "muted") }), { key = "note" .. i }))
	end

	local headItems: { UiNode } = {
		with(ui.text({ span(ctx, a.label, if a.state == "reported" then "strong" else "muted") }), { key = "label", role = "omp-usage.account-name", shrink = 1 }),
		with(ui.row({}), { key = "fill", grow = 1 }),
	}
	for _, b in badges do
		table.insert(headItems, b)
	end
	local nodes: { UiNode } = { with(ui.row(headItems), { key = "head", wrap = true }) }
	for _, n in body do
		table.insert(nodes, n)
	end
	if #details > 0 then
		table.insert(nodes, with(ui.section({ span(ctx, "Details", "muted") }, details), {
			key = "details", role = "omp-usage.details", collapsible = true, collapsed = true,
		}))
	end
	return with(ui.col(nodes), { key = key, gap = "xs", role = "omp-usage.account" })
end

-- Reported accounts first, then accounts needing sign-in, then those without data.
local function accountList(ctx: Ctx, p: Provider): { UiNode }
	local seen: { [string]: boolean } = {}
	local out: { UiNode } = {}
	for i, a in p.accounts do
		if i > 1 then
			table.insert(out, with(ctx.ui.rule(nil), { key = "sep" .. i }))
		end
		table.insert(out, accountNode(ctx, a, uniqueKey(seen, "a:" .. a.key)))
	end
	if #out == 0 then
		table.insert(out, with(ctx.ui.text({ span(ctx, "No accounts for this provider.", "muted") }), { key = "empty" }))
	end
	return out
end

local function providerHead(ctx: Ctx, p: Provider): ({ any }, string?)
	local disabled, unknown, exhausted, low, stale = 0, 0, 0, 0, 0
	for _, a in p.accounts do
		if a.state == "disabled" then
			disabled += 1
		elseif a.state == "unknown" then
			unknown += 1
		else
			local sev = worst(a)
			if sev == "exhausted" then
				exhausted += 1
			elseif sev == "low" then
				low += 1
			end
			if #staleReasons(ctx, a) > 0 then
				stale += 1
			end
		end
	end
	local head: { any } = { span(ctx, p.name, "strong"), span(ctx, "  " .. plural(#p.accounts, "account", "accounts"), "muted") }
	if exhausted > 0 then
		table.insert(head, span(ctx, " · " .. exhausted .. " exhausted", "error"))
	end
	if low > 0 then
		table.insert(head, span(ctx, " · " .. low .. " low", "warning"))
	end
	if disabled > 0 then
		table.insert(head, span(ctx, " · " .. disabled .. " login required", "warning"))
	end
	if unknown > 0 then
		table.insert(head, span(ctx, " · " .. unknown .. " no data", "muted"))
	end
	if stale > 0 then
		table.insert(head, span(ctx, " · " .. stale .. " stale", "warning"))
	end
	local tone: string? = if exhausted > 0 then "error" elseif low + disabled + stale > 0 then "warning" else nil
	return head, tone
end

local PRIMARY: { [string]: boolean } = { anthropic = true, ["openai-codex"] = true, openai = true }

-- Primary providers: framed panels side by side when the pane is wide enough.
local function primaryPanel(ctx: Ctx, p: Provider, key: string): UiNode
	local head, tone = providerHead(ctx, p)
	return with(ctx.ui.card(head, accountList(ctx, p)), {
		key = key, tone = tone, role = "omp-usage.panel", grow = 1, basis = 0.45, min = { w = "52ch" },
	})
end

-- Other providers: quiet disclosure rows, folded until needed.
local function otherSection(ctx: Ctx, p: Provider, key: string): UiNode
	local head, tone = providerHead(ctx, p)
	return with(ctx.ui.section(head, accountList(ctx, p)), {
		key = key, tone = tone, role = "omp-usage.other", collapsible = true, collapsed = true,
	})
end

-- Header chips: one per non-zero account count, using the same severity as the panels.
local function summaryBadges(ctx: Ctx, snapshot: Snapshot): { UiNode }
	local accounts, exhausted, low, disabled, unknown, stale = 0, 0, 0, 0, 0, 0
	for _, p in snapshot.providers do
		for _, a in p.accounts do
			accounts += 1
			if a.state == "disabled" then
				disabled += 1
			elseif a.state == "unknown" then
				unknown += 1
			else
				local sev = worst(a)
				if sev == "exhausted" then
					exhausted += 1
				elseif sev == "low" then
					low += 1
				end
				if #staleReasons(ctx, a) > 0 then
					stale += 1
				end
			end
		end
	end
	local out: { UiNode } = {
		badge(ctx, plural(#snapshot.providers, "provider", "providers") .. " · " .. plural(accounts, "account", "accounts"), "muted", "n-accounts"),
	}
	if exhausted > 0 then
		table.insert(out, badge(ctx, exhausted .. " exhausted", "error", "n-exhausted", "Accounts with at least one exhausted quota"))
	end
	if low > 0 then
		table.insert(out, badge(ctx, low .. " low", "warning", "n-low", string.format("Accounts with a quota below %d%% remaining", math.floor(LOW_FRACTION * 100 + 0.5))))
	end
	if disabled > 0 then
		table.insert(out, badge(ctx, disabled .. " login required", "warning", "n-disabled"))
	end
	if stale > 0 then
		table.insert(out, badge(ctx, stale .. " stale", "warning", "n-stale"))
	end
	if unknown > 0 then
		table.insert(out, badge(ctx, unknown .. " no data", "muted", "n-unknown"))
	end
	return out
end

local function refreshBadge(ctx: Ctx): UiNode
	local refreshing = ctx.status.refreshing
	local badge = ctx.ui.badge(if refreshing then "Refreshing…" else "Refresh", if refreshing then "info" else "accent")
	return with(badge, { key = "refresh", actions = { click = "refresh" }, title = "Refresh usage now (r)" })
end

-- Retained data is stale on refresh error or when the collector goes quiet.
local function banner(ctx: Ctx): UiNode?
	local ui = ctx.ui
	local status = ctx.status
	local last = if status.lastSuccess ~= nil then ago(ctx.now, status.lastSuccess) else "never"
	if status.error ~= nil then
		return with(
			ui.card({ span(ctx, "Refresh failed", "error strong"), span(ctx, " · showing retained data (stale)", "warning") }, {
				ui.text({
					span(ctx, errorReason(status.error) .. " ", "muted"),
					span(ctx, "Last successful refresh: " .. last .. ". Click Refresh or press r to retry.", "muted"),
				}),
			}),
			{ key = "banner", tone = "error" }
		)
	elseif ctx.retained ~= nil then
		local beat = if status.heartbeat ~= nil then ago(ctx.now, status.heartbeat) else "never"
		return with(
			ui.card({ span(ctx, "Collector not responding", "warning strong"), span(ctx, " · data may be stale", "warning") }, {
				ui.text({
					span(ctx, "Last heartbeat: " .. beat .. ". Last successful refresh: " .. last .. ". Click Refresh or press r to retry.", "muted"),
				}),
			}),
			{ key = "banner", tone = "warning" }
		)
	end
	return nil
end

local function emptyState(ctx: Ctx, snapshotMissing: boolean): UiNode
	local ui = ctx.ui
	local status = ctx.status
	if not snapshotMissing then
		return with(
			ui.card({ span(ctx, "No accounts found", "strong") }, {
				ui.text({ span(ctx, "omp reported no signed-in or API-key accounts. Sign in to a provider in omp, then refresh.", "muted") }),
			}),
			{ key = "state", tone = "muted" }
		)
	end
	if status.error ~= nil then
		return with(
			ui.card({ span(ctx, "Usage unavailable", "error strong") }, {
				ui.text({ span(ctx, errorReason(status.error) .. " ", "muted"), span(ctx, "Click Refresh or press r to retry.", "muted") }),
			}),
			{ key = "state", tone = "error" }
		)
	end
	if status.refreshing or ctx.retained == nil then
		local fx = ctx.ui.span("Loading usage…", "muted")
		fx.fx = "pulse"
		return with(ui.card({ span(ctx, "OMP Usage", "strong") }, { ui.text({ fx }) }), { key = "state", tone = "info" })
	end
	return with(
		ui.card({ span(ctx, "Waiting for the usage collector", "warning strong") }, {
			ui.text({ span(ctx, "No usage has arrived yet and the collector has not reported in. Click Refresh or press r.", "muted") }),
		}),
		{ key = "state", tone = "warning" }
	)
end

local function dockNode(ctx: Ctx, snapshot: Snapshot?): UiNode
	local ui = ctx.ui
	local status = ctx.status
	local spans: { any } = {}
	if status.error ~= nil then
		table.insert(spans, span(ctx, "stale · refresh failed", "error strong"))
	elseif ctx.retained ~= nil then
		table.insert(spans, span(ctx, "stale · collector idle", "warning strong"))
	elseif status.refreshing then
		table.insert(spans, span(ctx, "refreshing…", "info"))
	elseif snapshot ~= nil then
		table.insert(spans, span(ctx, "collector active", "muted"))
	else
		table.insert(spans, span(ctx, "loading", "muted"))
	end
	if status.lastSuccess ~= nil then
		table.insert(spans, span(ctx, " · updated " .. ago(ctx.now, status.lastSuccess), "muted"))
	end
	table.insert(spans, span(ctx, " · read-only · refresh every minute · r to refresh", "muted"))
	return ui.row({ with(ui.text(spans), { key = "status" }) })
end

local function render(snapshot: Snapshot?, statusIn: Status?, nowMs: number, ui: Ui): { main: UiNode, dock: UiNode }
	local status: Status = statusIn or { refreshing = false }
	local heartbeatStale = status.heartbeat == nil or nowMs - status.heartbeat > HEARTBEAT_STALE_MS
	local retained: string? = nil
	if status.error ~= nil then
		retained = "refresh failed"
	elseif heartbeatStale then
		retained = "collector idle"
	end
	local ctx: Ctx = { ui = ui, now = nowMs, status = status, retained = retained }

	local children: { UiNode } = {
		with(ui.row({
			with(ui.text({ span(ctx, "OMP Usage", "strong accent") }), { key = "title" }),
			refreshBadge(ctx),
		}), { key = "header", role = "omp-usage.header" }),
	}

	if snapshot == nil then
		table.insert(children, with(ui.text({ span(ctx, "Usage not loaded yet", "muted") }), { key = "summary" }))
		table.insert(children, emptyState(ctx, true))
		return { main = ui.col(children), dock = dockNode(ctx, nil) }
	end

	table.insert(children, with(ui.row(summaryBadges(ctx, snapshot)), { key = "summary", role = "omp-usage.summary", wrap = true }))

	local note = banner(ctx)
	if note ~= nil then
		table.insert(children, note)
	end

	if #snapshot.providers == 0 then
		table.insert(children, emptyState(ctx, false))
	else
		local seen: { [string]: boolean } = {}
		local panels: { UiNode } = {}
		local others: { UiNode } = {}
		for _, p in snapshot.providers do
			local key = uniqueKey(seen, "p:" .. p.id)
			if PRIMARY[p.id] then
				table.insert(panels, primaryPanel(ctx, p, key))
			else
				table.insert(others, otherSection(ctx, p, key))
			end
		end
		if #panels > 0 then
			table.insert(children, with(ui.row(panels), { key = "primary", role = "omp-usage.primary", wrap = true, align = "start" }))
		end
		if #others > 0 then
			table.insert(children, with(ui.rule({ span(ctx, "Other providers", "muted") }), { key = "others-rule" }))
			table.insert(children, with(ui.col(others), { key = "others", role = "omp-usage.others", gap = "xs" }))
		end
	end

	return { main = ui.col(children), dock = dockNode(ctx, snapshot) }
end

return { render = render }
