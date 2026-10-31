--!strict
-- omp-usage model: normalizes `omp usage --json` into an account-aware
-- snapshot, summarizes it and formats durations. Pure functions of their input
-- (no tern globals, no clock, no I/O), so the host, the view and the tests can
-- all call them.
--
-- Rules the rest of the plugin relies on:
--   * normalize() REJECTS (error, message names the field path, never the
--     value) a payload that is not an object, lacks a numeric `generatedAt`, or
--     lacks a `reports` array; a present-but-malformed optional field rejects too.
--     A valid empty payload yields an empty snapshot.
--   * Every report, accountsWithoutUsage and disabledCredentials entry becomes
--     exactly one Account row. Nothing is merged or summed: same-label or
--     same-duration limits stay separate rows with unique keys, and shared-quota
--     aliases stay as individual limits.
--   * A missing amount is never 0: `remaining`/`usedFraction` are nil and
--     `amountText` is "not reported".
--   * Raw `cause`, endpoints, stack traces and credentials are never copied.
--   * `counts.exhausted` counts ACCOUNTS with at least one exhausted limit.
--   * Limit.resetLabel preserves the provider's reset/regeneration verb.

local M = {}

export type Limit = {
	key: string,
	label: string,
	remaining: number?,
	usedFraction: number?,
	amountText: string,
	resetsAt: number?,
	resetLabel: string,
	-- Window length in ms, when OMP reports one.
	windowMs: number?,
	-- True for a tier- or model-specific bucket rather than the account-wide one.
	scoped: boolean,
	-- "ok" | "low" | "exhausted" | "unknown"
	status: string,
	notes: { string },
}

export type Account = {
	key: string,
	label: string,
	detail: string,
	-- "reported" | "disabled" | "unknown"
	state: string,
	fetchedAt: number?,
	limits: { Limit },
	savedResets: number?,
	notes: { string },
}

export type Provider = { id: string, name: string, accounts: { Account } }

export type Counts = { accounts: number, reported: number, disabled: number, unknown: number, exhausted: number }

export type Snapshot = { generatedAt: number, providers: { Provider }, counts: Counts }

export type Segment = { text: string, tone: string? }

-- `segments`: per-account weekly usage for the status line, then the alert counts.
export type Summary = { text: string, tone: string, segments: { Segment }? }

-- A report older than this (or without fetchedAt) is stale, whatever generatedAt says.
M.STALE_MS = 10 * 60 * 1000
-- A limit with less than this fraction left (and more than none) is "low".
M.LOW_FRACTION = 0.15

local PROVIDER_NAMES: { [string]: string } = {
	anthropic = "Anthropic",
	openai = "OpenAI",
	["openai-codex"] = "OpenAI Codex",
	["google-antigravity"] = "Google Antigravity",
	["google-gemini-cli"] = "Google Gemini CLI",
	["github-copilot"] = "GitHub Copilot",
	zai = "Z.AI",
}

local PROVIDER_RANK: { [string]: number } = { anthropic = 1, ["openai-codex"] = 2, openai = 3 }

local STATE_RANK: { [string]: number } = { reported = 1, disabled = 2, unknown = 3 }

local EMPTY: { [string]: any } = {}

----------------------------------------------------------------------------
-- small helpers

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k in v do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		n += 1
	end
	return n == #v
end

local function fail(path: string, why: string): never
	error("usage: invalid payload at " .. path .. ": " .. why, 0)
end

-- Printable single-line text, at most `max` characters.
local function clean(s: string, max: number): string
	local out = (s:gsub("%c", " "))
	if utf8.len(out) == nil then
		out = (out:gsub("[\128-\255]", "?"))
	end
	out = (out:gsub("%s+", " "))
	out = out:match("^%s*(.-)%s*$") or ""
	local len = utf8.len(out)
	if len ~= nil and len > max then
		local cut = utf8.offset(out, max)
		if cut ~= nil then
			out = out:sub(1, cut - 1) .. "…"
		end
	end
	return out
end

local function nonEmpty(s: string?, max: number): string?
	if s == nil then
		return nil
	end
	local c = clean(s, max)
	if c == "" then
		return nil
	end
	return c
end

local function safeNotes(t: any, path: string): { string }
	local out: { string } = {}
	if t.notes == nil then return out end
	if not isArray(t.notes) then return fail(path .. ".notes", "must be an array") end
	for _, note in ipairs(t.notes :: { any }) do
		if type(note) ~= "string" then return fail(path .. ".notes", "must contain strings") end
		local text = nonEmpty(note, 256)
		if text then table.insert(out, text) end
	end
	return out
end

local function optString(t: any, field: string, path: string): string?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) ~= "string" then
		fail(path .. "." .. field, "must be a string")
	end
	return v
end

local function optNumber(t: any, field: string, path: string): number?
	local v = t[field]
	if v == nil then
		return nil
	end
	if not isFinite(v) then
		fail(path .. "." .. field, "must be a finite number")
	end
	return v
end

local function optBool(t: any, field: string, path: string): boolean?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) ~= "boolean" then
		fail(path .. "." .. field, "must be a boolean")
	end
	return v
end

local function optTable(t: any, field: string, path: string): { [string]: any }?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) ~= "table" then
		fail(path .. "." .. field, "must be an object")
	end
	return v
end

-- Identifiers arrive as strings, occasionally as numbers.
local function optId(t: any, field: string, path: string): string?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) == "string" then
		return v
	end
	if isFinite(v) then
		return string.format("%.14g", v)
	end
	return fail(path .. "." .. field, "must be a string or number")
end

local function shorten(id: string): string
	local s = (id:gsub("[^\32-\126]", "?"))
	if #s > 14 then
		return s:sub(1, 6) .. "…" .. s:sub(-4)
	end
	return s
end

local function capitalize(s: string): string
	return s:sub(1, 1):upper() .. s:sub(2)
end

-- FNV-1a, 32 bit. Stable, non-reversible-looking key material (no emails in keys).
local function hash32(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, s:byte(i))
		-- h * 16777619 mod 2^32 without leaving double precision: 16777619 = 2^24 + 403.
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function fmtNumber(n: number): string
	local neg = n < 0
	local a = math.abs(n)
	local s: string
	if a % 1 == 0 and a < 1e15 then
		s = string.format("%d", a)
	elseif a >= 1e15 then
		s = string.format("%.3g", a)
	else
		s = string.format("%.2f", a)
		s = (s:gsub("0+$", ""))
		s = (s:gsub("%.$", ""))
	end
	if not s:find("e", 1, true) then
		while true do
			local k: number
			s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
			if k == 0 then
				break
			end
		end
	end
	return neg and ("-" .. s) or s
end

local function formatPercent(fraction: number): string
	local p = math.abs(fraction) * 100
	if p > 0 and p < 1 then
		return "<1%"
	end
	local r = math.floor(p + 0.5)
	if r >= 100 and p < 100 then
		r = 99
	end
	return string.format("%d%%", r)
end

----------------------------------------------------------------------------
-- duration

-- Countdown/age text: "due" for <= 0, otherwise at most two of d/h/m/s.
local function duration(ms: number): string
	if type(ms) ~= "number" or ms ~= ms or ms == math.huge then
		return "unknown"
	end
	if ms <= 0 then
		return "due"
	end
	local secs = math.ceil(ms / 1000)
	local d = math.floor(secs / 86400)
	local h = math.floor((secs % 86400) / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if d > 0 then
		if h > 0 then
			return string.format("%dd %dh", d, h)
		end
		return string.format("%dd", d)
	elseif h > 0 or secs >= 3600 then
		if m > 0 then
			return string.format("%dh %dm", h, m)
		end
		return string.format("%dh", h)
	elseif m > 0 then
		if s > 0 then
			return string.format("%dm %ds", m, s)
		end
		return string.format("%dm", m)
	end
	return string.format("%ds", s)
end

M.duration = duration

----------------------------------------------------------------------------
-- limits

-- OMP precedence: usedFraction > used/positive limit > percent-unit used/100 >
-- inverted remainingFraction > remaining/positive limit > percent-unit remaining/100.
-- Returns nil when nothing in the amount lets a fraction be derived (never 0).
local function deriveUsed(a: { [string]: any }, unit: string?): number?
	local used: number? = nil
	local usedFraction, usedAmt, limit, remainingFraction, remaining =
		a.usedFraction, a.used, a.limit, a.remainingFraction, a.remaining
	local isPercent = unit ~= nil and unit:lower() == "percent"
	if usedFraction ~= nil then
		used = usedFraction
	elseif usedAmt ~= nil and limit ~= nil and limit > 0 then
		used = usedAmt / limit
	elseif usedAmt ~= nil and isPercent then
		used = usedAmt / 100
	elseif remainingFraction ~= nil then
		used = 1 - remainingFraction
	elseif remaining ~= nil and limit ~= nil and limit > 0 then
		used = 1 - remaining / limit
	elseif remaining ~= nil and isPercent then
		used = 1 - remaining / 100
	end
	if used == nil then
		return nil
	end
	if used < 0 then
		used = 0
	end
	return used
end

local function deriveStatus(payloadStatus: string?, remaining: number?): string
	local s = payloadStatus and payloadStatus:lower() or ""
	if remaining ~= nil then
		if remaining <= 0 or s == "exhausted" then
			return "exhausted"
		end
		if s == "warning" or s == "low" or remaining < M.LOW_FRACTION then
			return "low"
		end
		return "ok"
	end
	if s == "exhausted" then
		return "exhausted"
	elseif s == "warning" or s == "low" then
		return "low"
	elseif s == "ok" then
		return "ok"
	end
	return "unknown"
end

local function amountText(remaining: number?, a: { [string]: any }, unit: string?): string
	if remaining ~= nil then
		if remaining < 0 then
			return formatPercent(remaining) .. " over limit"
		end
		return formatPercent(remaining) .. " left"
	end
	local suffix = unit ~= nil and (" " .. unit) or ""
	if a.remaining ~= nil then
		return fmtNumber(a.remaining) .. suffix .. " left"
	end
	if a.used ~= nil then
		return fmtNumber(a.used) .. suffix .. " used"
	end
	return "not reported"
end

local function sanitizeKey(s: string): string
	local k = (s:gsub("[^%w%-_%.:/#]", "_"))
	return k:sub(1, 80)
end

-- Returns the limit (key still provisional) and the key material it came from.
local function parseLimit(l: any, path: string, index: number): Limit
	if type(l) ~= "table" then
		fail(path, "must be an object")
	end
	local id = nonEmpty(optString(l, "id", path), 80)
	local labelRaw = nonEmpty(optString(l, "label", path), 40)
	local statusRaw = optString(l, "status", path)

	local scope = optTable(l, "scope", path) or EMPTY
	local scopePath = path .. ".scope"
	optString(scope, "provider", scopePath)
	local scopeWindowId = nonEmpty(optString(scope, "windowId", scopePath), 40)
	local tier = nonEmpty(optString(scope, "tier", scopePath), 32)
	local modelId = nonEmpty(optString(scope, "modelId", scopePath), 48)
	local shared = optBool(scope, "shared", scopePath)
	local sharedGroup = nonEmpty(optString(scope, "sharedGroup", scopePath), 32)

	local window = optTable(l, "window", path) or EMPTY
	local windowPath = path .. ".window"
	local winId = nonEmpty(optString(window, "id", windowPath), 40)
	local winLabel = nonEmpty(optString(window, "label", windowPath), 32)
	local durationMs = optNumber(window, "durationMs", windowPath)
	local resetsAt = optNumber(window, "resetsAt", windowPath)

	local amount = optTable(l, "amount", path) or EMPTY
	local amountPath = path .. ".amount"
	local unit = nonEmpty(optString(amount, "unit", amountPath), 16)
	if unit ~= nil and not unit:match("^[%w%._%%%-/ ]+$") then
		unit = nil
	end
	local a = {
		usedFraction = optNumber(amount, "usedFraction", amountPath),
		remainingFraction = optNumber(amount, "remainingFraction", amountPath),
		used = optNumber(amount, "used", amountPath),
		limit = optNumber(amount, "limit", amountPath),
		remaining = optNumber(amount, "remaining", amountPath),
	}

	local used = deriveUsed(a, unit)
	local remaining: number? = nil
	if used ~= nil then
		remaining = math.floor((1 - used) * 1e9 + 0.5) / 1e9
	end

	local label: string = labelRaw or winLabel or winId or scopeWindowId or id or "Limit"

	local windowDesc: string? = winLabel
	if windowDesc == nil and durationMs ~= nil and durationMs > 0 then
		windowDesc = duration(durationMs)
	end
	-- A verb the view prefixes to the countdown ("resets in 3h"); resetsAt carries the time.
	local resetLabel = nonEmpty(optString(window, "resetLabel", windowPath), 24) or "resets"

	local notes: { string } = safeNotes(l, path)
	if shared == true or sharedGroup ~= nil then
		notes[#notes + 1] = sharedGroup ~= nil and ("Shared quota: " .. sharedGroup) or "Shared quota"
	end
	if tier ~= nil then
		notes[#notes + 1] = "Tier: " .. tier
	end
	if modelId ~= nil then
		notes[#notes + 1] = "Model: " .. modelId
	end
	if windowDesc ~= nil and not label:lower():find(windowDesc:lower(), 1, true) then
		notes[#notes + 1] = "Window: " .. windowDesc
	end

	return {
		key = sanitizeKey(id or string.format("limit-%d", index)),
		label = label,
		remaining = remaining,
		usedFraction = used,
		amountText = amountText(remaining, a, unit),
		resetsAt = resetsAt,
		resetLabel = resetLabel,
		windowMs = durationMs,
		scoped = tier ~= nil or modelId ~= nil,
		status = deriveStatus(statusRaw, remaining),
		notes = notes,
	}
end

-- Short, unique, stable tags for a group of distinct keys: the part of each key
-- between the group's common prefix and common suffix ("pro" / "flash" for
-- "x-pro-weekly" / "x-flash-weekly"); when that is empty or ambiguous, the
-- shortest unique key tail.
local function distinguishers(keys: { string }): { string }
	local minLen = #keys[1]
	for _, k in keys do
		minLen = math.min(minLen, #k)
	end
	local cp = 0
	while cp < minLen do
		local c = keys[1]:byte(cp + 1)
		local same = true
		for _, k in keys do
			if k:byte(cp + 1) ~= c then
				same = false
				break
			end
		end
		if not same then
			break
		end
		cp += 1
	end
	local cs = 0
	while cp + cs < minLen do
		local c = keys[1]:byte(#keys[1] - cs)
		local same = true
		for _, k in keys do
			if k:byte(#k - cs) ~= c then
				same = false
				break
			end
		end
		if not same then
			break
		end
		cs += 1
	end
	local tags: { string } = {}
	local seen: { [string]: boolean } = {}
	local ok = true
	for i, k in keys do
		local mid = k:sub(cp + 1, #k - cs)
		if mid == "" or seen[mid] then
			ok = false
			break
		end
		seen[mid] = true
		tags[i] = mid
	end
	if ok then
		return tags
	end

	local maxLen = 0
	for _, k in keys do
		maxLen = math.max(maxLen, #k)
	end
	local len = math.min(4, maxLen)
	while len < maxLen do
		local tails: { [string]: boolean } = {}
		local unique = true
		for _, k in keys do
			local tail = k:sub(-len)
			if tails[tail] then
				unique = false
				break
			end
			tails[tail] = true
		end
		if unique then
			break
		end
		len += 1
	end
	for i, k in keys do
		tags[i] = k:sub(-len)
	end
	return tags
end

local function finalizeLimits(limits: { Limit })
	local used: { [string]: boolean } = {}
	for _, l in limits do
		local candidate = l.key
		local n = 1
		while used[candidate] do
			n += 1
			candidate = l.key .. "#" .. n
		end
		used[candidate] = true
		l.key = candidate
	end

	local groups: { [string]: { Limit } } = {}
	for _, l in limits do
		local g = l.label:lower()
		local list = groups[g]
		if list == nil then
			list = {}
			groups[g] = list
		end
		list[#list + 1] = l
	end
	for _, list in groups do
		if #list > 1 then
			local keys: { string } = {}
			for i, l in list do
				keys[i] = l.key
			end
			local tags = distinguishers(keys)
			for i, l in list do
				l.label = l.label .. " [" .. tags[i] .. "]"
			end
		end
	end
end

----------------------------------------------------------------------------
-- accounts

type Meta = {
	email: string?,
	accountId: string?,
	orgId: string?,
	orgName: string?,
	projectId: string?,
	planType: string?,
}

type Entry = { provider: string, account: Account, identity: string }

-- `t` is the report's metadata object or a disabled-credential entry.
local function parseMeta(t: { [string]: any }, path: string): Meta
	return {
		email = nonEmpty(optString(t, "email", path), 64),
		accountId = nonEmpty(optId(t, "accountId", path), 64),
		orgId = nonEmpty(optId(t, "orgId", path), 64),
		orgName = nonEmpty(optString(t, "orgName", path), 48),
		projectId = nonEmpty(optId(t, "projectId", path), 64),
		planType = nonEmpty(optString(t, "planType", path), 24),
	}
end

local function metaLabel(meta: Meta, kind: string?): string
	if meta.email ~= nil then
		return meta.email
	elseif meta.orgName ~= nil then
		return meta.orgName
	elseif meta.accountId ~= nil then
		return shorten(meta.accountId)
	elseif meta.projectId ~= nil then
		return shorten(meta.projectId)
	elseif meta.orgId ~= nil then
		return shorten(meta.orgId)
	elseif kind == "api_key" then
		return "API key"
	end
	return "Account"
end

local function typeDescription(kind: string?): string?
	if kind == nil then
		return nil
	elseif kind == "api_key" then
		return "API key"
	elseif kind == "oauth" then
		return "OAuth"
	end
	return kind
end

local function metaDetail(meta: Meta, label: string, kind: string?): string
	local parts: { string } = {}
	local td = typeDescription(kind)
	if td ~= nil then
		parts[#parts + 1] = td
	end
	if meta.planType ~= nil then
		parts[#parts + 1] = capitalize(meta.planType)
	end
	if meta.orgName ~= nil and meta.orgName ~= label then
		parts[#parts + 1] = meta.orgName
	elseif meta.orgName == nil and meta.orgId ~= nil and shorten(meta.orgId) ~= label then
		parts[#parts + 1] = "org " .. shorten(meta.orgId)
	end
	if meta.projectId ~= nil and shorten(meta.projectId) ~= label then
		parts[#parts + 1] = "project " .. shorten(meta.projectId)
	end
	if meta.accountId ~= nil and shorten(meta.accountId) ~= label then
		parts[#parts + 1] = "id " .. shorten(meta.accountId)
	end
	if meta.email ~= nil and meta.email ~= label then
		parts[#parts + 1] = meta.email
	end
	return table.concat(parts, " · ")
end

local function identityString(provider: string, source: string, meta: Meta, extra: string?): string
	return table.concat({
		provider,
		source,
		extra or "",
		meta.accountId or "",
		meta.email and meta.email:lower() or "",
		meta.orgId or "",
		meta.projectId or "",
	}, "\0")
end

local function parseReport(r: any, path: string): Entry
	if type(r) ~= "table" then
		fail(path, "must be an object")
	end
	local provider = nonEmpty(optString(r, "provider", path), 64)
	if provider == nil then
		return fail(path .. ".provider", "must be a non-empty string")
	end
	local fetchedAt = optNumber(r, "fetchedAt", path)
	if not isArray(r.limits) then
		fail(path .. ".limits", "must be an array")
	end
	local meta = parseMeta(optTable(r, "metadata", path) or EMPTY, path .. ".metadata")

	local savedResets: number? = nil
	local credits = optTable(r, "resetCredits", path)
	if credits ~= nil then
		local count = optNumber(credits, "availableCount", path .. ".resetCredits")
		if count ~= nil then
			savedResets = math.floor(math.max(0, count))
		end
	end

	local limits: { Limit } = {}
	local anyShared = false
	for i, l in ipairs(r.limits :: { any }) do
		local limit = parseLimit(l, string.format("%s.limits[%d]", path, i), i)
		for _, n in limit.notes do
			if n:sub(1, 6) == "Shared" then
				anyShared = true
			end
		end
		limits[#limits + 1] = limit
	end
	finalizeLimits(limits)

	local notes: { string } = safeNotes(r, path)
	local state = "reported"
	if #limits == 0 then
		state = "unknown"
	elseif anyShared then
		notes[#notes + 1] = "Some limits share one quota; aliases are listed separately and not summed."
	end

	local label = metaLabel(meta, nil)
	return {
		provider = provider,
		identity = identityString(provider, "report", meta, nil),
		account = {
			key = "",
			label = label,
			detail = metaDetail(meta, label, nil),
			state = state,
			fetchedAt = fetchedAt,
			limits = limits,
			savedResets = savedResets,
			notes = notes,
		},
	}
end

local function parseWithoutUsage(e: any, path: string): Entry
	if type(e) ~= "table" then
		fail(path, "must be an object")
	end
	local provider = nonEmpty(optString(e, "provider", path), 64)
	if provider == nil then
		return fail(path .. ".provider", "must be a non-empty string")
	end
	local kind = nonEmpty(optString(e, "type", path), 24)
	local meta = parseMeta(e, path)
	local label = metaLabel(meta, kind)
	return {
		provider = provider,
		identity = identityString(provider, "nousage", meta, kind),
		account = {
			key = "",
			label = label,
			detail = metaDetail(meta, label, kind),
			state = "unknown",
			fetchedAt = nil,
			limits = {},
			savedResets = nil,
			notes = {},
		},
	}
end

local function parseDisabled(d: any, path: string): Entry
	if type(d) ~= "table" then
		fail(path, "must be an object")
	end
	local provider = nonEmpty(optString(d, "provider", path), 64)
	if provider == nil then
		return fail(path .. ".provider", "must be a non-empty string")
	end
	local kind = nonEmpty(optString(d, "type", path), 24)
	local credentialId = nonEmpty(optId(d, "id", path), 64)
	optNumber(d, "disabledAtMs", path)
	-- `cause` is raw exception text: deliberately never read, validated or copied.
	local meta = parseMeta(d, path)
	local label = metaLabel(meta, kind)
	return {
		provider = provider,
		identity = identityString(provider, "disabled", meta, (kind or "") .. "\0" .. (credentialId or "")),
		account = {
			key = "",
			label = label,
			detail = metaDetail(meta, label, kind),
			state = "disabled",
			fetchedAt = nil,
			limits = {},
			savedResets = nil,
			notes = {},
		},
	}
end

local function providerName(id: string): string
	local known = PROVIDER_NAMES[id:lower()]
	if known ~= nil then
		return known
	end
	local words: { string } = {}
	for w in id:gmatch("[^%-_%s%.]+") do
		words[#words + 1] = capitalize(w)
	end
	if #words == 0 then
		return id
	end
	return table.concat(words, " ")
end

----------------------------------------------------------------------------
-- normalize

function M.normalize(payload: any): Snapshot
	if type(payload) ~= "table" then
		fail("$", "must be an object")
	end
	local generatedAt = payload.generatedAt
	if not isFinite(generatedAt) then
		fail("$.generatedAt", "must be a finite number")
	end
	if not isArray(payload.reports) then
		fail("$.reports", "must be an array")
	end
	if payload.accountsWithoutUsage ~= nil and not isArray(payload.accountsWithoutUsage) then
		fail("$.accountsWithoutUsage", "must be an array")
	end
	if payload.disabledCredentials ~= nil and not isArray(payload.disabledCredentials) then
		fail("$.disabledCredentials", "must be an array")
	end

	local entries: { Entry } = {}
	for i, r in payload.reports do
		entries[#entries + 1] = parseReport(r, string.format("$.reports[%d]", i))
	end
	if payload.accountsWithoutUsage ~= nil then
		for i, e in payload.accountsWithoutUsage do
			entries[#entries + 1] = parseWithoutUsage(e, string.format("$.accountsWithoutUsage[%d]", i))
		end
	end
	if payload.disabledCredentials ~= nil then
		for i, d in payload.disabledCredentials do
			entries[#entries + 1] = parseDisabled(d, string.format("$.disabledCredentials[%d]", i))
		end
	end

	-- Unique, identity-derived (but PII-free) keys; repeats get a #n suffix.
	local usedKeys: { [string]: boolean } = {}
	for _, e in entries do
		local base = sanitizeKey(e.provider) .. ":" .. hash32(e.identity)
		local candidate = base
		local n = 1
		while usedKeys[candidate] do
			n += 1
			candidate = base .. "#" .. n
		end
		usedKeys[candidate] = true
		e.account.key = candidate
	end

	-- Identical labels within a provider get a numeric suffix, in input order.
	local labelGroups: { [string]: { Entry } } = {}
	for _, e in entries do
		local g = e.provider .. "\0" .. e.account.label:lower()
		local list = labelGroups[g]
		if list == nil then
			list = {}
			labelGroups[g] = list
		end
		list[#list + 1] = e
	end
	for _, list in labelGroups do
		if #list > 1 then
			for i, e in list do
				e.account.label = string.format("%s #%d", e.account.label, i)
			end
		end
	end

	local byProvider: { [string]: Provider } = {}
	local providers: { Provider } = {}
	local counts: Counts = { accounts = 0, reported = 0, disabled = 0, unknown = 0, exhausted = 0 }
	for _, e in entries do
		local p = byProvider[e.provider]
		if p == nil then
			p = { id = e.provider, name = providerName(e.provider), accounts = {} }
			byProvider[e.provider] = p
			providers[#providers + 1] = p
		end
		p.accounts[#p.accounts + 1] = e.account
		counts.accounts += 1
		local state = e.account.state
		if state == "reported" then
			counts.reported += 1
		elseif state == "disabled" then
			counts.disabled += 1
		else
			counts.unknown += 1
		end
		for _, l in e.account.limits do
			if l.status == "exhausted" then
				counts.exhausted += 1
				break
			end
		end
	end

	for _, p in providers do
		table.sort(p.accounts, function(a: Account, b: Account): boolean
			local ra, rb = STATE_RANK[a.state] or 9, STATE_RANK[b.state] or 9
			if ra ~= rb then
				return ra < rb
			end
			local la, lb = a.label:lower(), b.label:lower()
			if la ~= lb then
				return la < lb
			end
			return a.key < b.key
		end)
	end
	table.sort(providers, function(a: Provider, b: Provider): boolean
		local ra, rb = PROVIDER_RANK[a.id] or 4, PROVIDER_RANK[b.id] or 4
		if ra ~= rb then
			return ra < rb
		end
		local na, nb = a.name:lower(), b.name:lower()
		if na ~= nb then
			return na < nb
		end
		return a.id < b.id
	end)

	return { generatedAt = generatedAt, providers = providers, counts = counts }
end

----------------------------------------------------------------------------
-- summary

local WEEK_MS = 7 * 24 * 3600 * 1000

-- Providers whose accounts get their own status-line percentage, in order.
local STATUS_PROVIDERS: { { id: string, name: string } } = {
	{ id = "anthropic", name = "Claude" },
	{ id = "openai-codex", name = "Codex" },
	{ id = "openai", name = "OpenAI" },
}

-- Short account names for the status line: the email local part, minus the
-- prefix every shown name shares, cut to the shortest unique prefix (at least
-- four characters). One identity keeps one name across providers.
local function shortNames(labels: { string }): { string }
	local bases: { string } = {}
	for i, label in labels do
		local base = label:match("^([^@]+)@") or label
		bases[i] = (base:gsub("[^\33-\126]", ""))
	end
	if #bases > 1 then
		local common = #bases[1]
		for _, b in bases do
			common = math.min(common, #b)
			for i = 1, common do
				if b:byte(i) ~= bases[1]:byte(i) then
					common = i - 1
					break
				end
			end
		end
		-- Keep at least four characters of every name.
		local shortest = math.huge
		for _, b in bases do
			shortest = math.min(shortest, #b)
		end
		common = math.min(common, math.max(0, shortest - 4))
		if common > 0 then
			for i, b in bases do
				bases[i] = b:sub(common + 1)
			end
		end
	end
	local names: { string } = {}
	for i, b in bases do
		local n = math.min(#b, 4)
		while n < #b do
			local unique = true
			for j, other in bases do
				if j ~= i and other ~= b and other:sub(1, n) == b:sub(1, n) then
					unique = false
					break
				end
			end
			if unique then
				break
			end
			n += 1
		end
		names[i] = if n < 1 then "acct" else b:sub(1, n)
	end
	return names
end

-- The account-wide 7-day bucket with a reported amount (the most used one if
-- several); a tier/model 7-day bucket only when no account-wide one exists.
local function weeklyLimit(limits: { Limit }): Limit?
	local best: Limit? = nil
	for _, l in limits do
		if l.windowMs == WEEK_MS and l.usedFraction ~= nil then
			if best == nil
				or (best.scoped and not l.scoped)
				or (best.scoped == l.scoped and (l.usedFraction :: number) > (best.usedFraction :: number))
			then
				best = l
			end
		end
	end
	return best
end

-- One segment per account with fresh 7-day data. Stale, logged-out and
-- non-weekly accounts are left out rather than shown with old or other numbers.
local function accountSegments(snapshot: Snapshot, now: number): { Segment }
	local rows: { { provider: string, limit: Limit } } = {}
	local labels: { string } = {}
	for _, sp in STATUS_PROVIDERS do
		for _, p in snapshot.providers do
			if p.id == sp.id then
				for _, a in p.accounts do
					local fresh = a.fetchedAt ~= nil and now - a.fetchedAt <= M.STALE_MS
					local l = if a.state == "reported" and fresh then weeklyLimit(a.limits) else nil
					if l ~= nil then
						rows[#rows + 1] = { provider = sp.name, limit = l }
						labels[#labels + 1] = a.label
					end
				end
			end
		end
	end
	local names = shortNames(labels)
	local segments: { Segment } = {}
	local lastProvider: string? = nil
	local seen: { [string]: number } = {}
	for i, row in rows do
		local l = row.limit
		local tone = if l.status == "exhausted" then "error" elseif l.status == "low" then "warning" else nil
		if row.provider ~= lastProvider then
			seen = {}
		end
		-- Two accounts of one provider never share a name, even with one identity.
		local name = names[i]
		seen[name] = (seen[name] or 0) + 1
		if seen[name] > 1 then
			name = string.format("%s#%d", name, seen[name])
		end
		local prefix = if row.provider ~= lastProvider then row.provider .. " " else ""
		lastProvider = row.provider
		segments[#segments + 1] = { text = prefix .. name .. " " .. formatPercent(l.usedFraction :: number), tone = tone }
	end
	return segments
end

function M.summary(snapshot: Snapshot?, nowMs: number): Summary
	if type(snapshot) ~= "table" or type(snapshot.providers) ~= "table" then
		return { text = "No usage data", tone = "muted" }
	end
	local now = isFinite(nowMs) and nowMs or snapshot.generatedAt

	local accounts, reported, exhausted, low, disabled, unknown, stale = 0, 0, 0, 0, 0, 0, 0
	for _, p in snapshot.providers do
		for _, a in p.accounts do
			accounts += 1
			if a.state == "reported" then
				reported += 1
				local hasExhausted, hasLow = false, false
				for _, l in a.limits do
					if l.status == "exhausted" then
						hasExhausted = true
					elseif l.status == "low" then
						hasLow = true
					end
				end
				if hasExhausted then
					exhausted += 1
				elseif hasLow then
					low += 1
				end
				if a.fetchedAt == nil or now - a.fetchedAt > M.STALE_MS then
					stale += 1
				end
			elseif a.state == "disabled" then
				disabled += 1
			else
				unknown += 1
			end
		end
	end

	if accounts == 0 then
		return { text = "No accounts reported", tone = "muted" }
	end

	-- Counts only: percentages of different plans are never averaged.
	local parts = { plural(#snapshot.providers, "provider"), plural(accounts, "account") }
	if exhausted > 0 then
		parts[#parts + 1] = string.format("%d exhausted", exhausted)
	end
	if low > 0 then
		parts[#parts + 1] = string.format("%d low", low)
	end
	if disabled > 0 then
		parts[#parts + 1] = string.format("%d login required", disabled)
	end
	if stale > 0 then
		parts[#parts + 1] = string.format("%d stale", stale)
	end
	if unknown > 0 then
		parts[#parts + 1] = string.format("%d no data", unknown)
	end

	local tone = "success"
	if exhausted > 0 then
		tone = "error"
	elseif low + disabled + stale > 0 then
		tone = "warning"
	elseif reported == 0 then
		tone = "muted"
	end
	local segments = accountSegments(snapshot, now)
	if #segments == 0 then
		segments[1] = { text = "Usage · no weekly data", tone = "muted" }
	end
	return { text = table.concat(parts, " · "), tone = tone, segments = segments }
end

return M
