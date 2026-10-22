local usage = require("../usage")
local NOW = 1_800_000_000_000
local function limit(id, used, label)
	return { id = id, label = label or "Weekly", amount = { usedFraction = used },
		window = { durationMs = 604800000, resetsAt = NOW + 3600000 } }
end
local function report(provider, email, limits, plan)
	return { provider = provider, fetchedAt = NOW, limits = limits,
		metadata = { email = email, planType = plan } }
end
local function normalize(reports, unknown, disabled)
	return usage.normalize({ generatedAt = NOW, reports = reports,
		accountsWithoutUsage = unknown, disabledCredentials = disabled })
end
local function near(a, b) assert(a ~= nil and math.abs(a - b) < 1e-8, tostring(a) .. " != " .. b) end
local function rejects(payload) assert(not pcall(usage.normalize, payload), "malformed report accepted") end

-- Preferred providers remain first even when their accounts lack current usage.
local ordered = normalize({
	report("zai", "one@example.test", {limit("daily", 0.2)}),
	report("cursor", "two@example.test", {limit("daily", 0.2)}),
	report("openai-codex", "three@example.test", {limit("daily", 0.2)}),
}, {{provider="openai",type="api_key"}}, {{provider="anthropic",id=1,type="oauth"}})
local expectedOrder = {"anthropic", "openai-codex", "openai", "cursor", "zai"}
for i, id in expectedOrder do assert(ordered.providers[i].id == id) end

-- Account separation: different plans and identity-less accounts must never collapse.
local source = {
	report("openai-codex", "free@example.test", { limit("monthly", 0.5, "Monthly") }, "free"),
	report("openai-codex", "pro@example.test", { limit("weekly", 0.72) }, "pro"),
}
local snapshot = normalize(source, {{provider="devin",type="api_key"},{provider="devin",type="api_key"}},
	{{provider="cursor",id=8,type="oauth",cause="private error must never reach UI"}})
assert(snapshot.counts.accounts == 5 and snapshot.counts.reported == 2)
assert(snapshot.counts.unknown == 2 and snapshot.counts.disabled == 1)
local codex, devin, cursor
for _, p in snapshot.providers do
	if p.id == "openai-codex" then codex = p end
	if p.id == "devin" then devin = p end
	if p.id == "cursor" then cursor = p end
end
assert(#codex.accounts == 2 and codex.accounts[1].key ~= codex.accounts[2].key)
near(codex.accounts[1].limits[1].remaining, 0.5)
near(codex.accounts[2].limits[1].remaining, 0.28)
assert(codex.accounts[1].detail ~= codex.accounts[2].detail)
assert(#devin.accounts == 2 and devin.accounts[1].key ~= devin.accounts[2].key)
assert(cursor.accounts[1].state == "disabled" and cursor.accounts[1].cause == nil)
local reordered = normalize({source[2], source[1]})
for i, a in reordered.providers[1].accounts do assert(a.key == codex.accounts[i].key) end

-- Equal labels and equal durations are not equivalent quotas, including shared aliases.
local antigravity = normalize({
	report("google-antigravity", "one@example.test", {limit("gemini-pro",0.62),limit("gemini-flash",0)}),
	report("google-antigravity", "two@example.test", {limit("gemini-pro",0.73)}),
	report("google-antigravity", "three@example.test", {limit("gemini-pro",1)}),
})
assert(#antigravity.providers[1].accounts == 3)
local accounts = {}
for _, a in antigravity.providers[1].accounts do accounts[a.label] = a end
local buckets = accounts["one@example.test"].limits
assert(#buckets == 2 and buckets[1].key ~= buckets[2].key and buckets[1].label ~= buckets[2].label)
near(buckets[1].remaining,0.38); near(buckets[2].remaining,1)
assert(antigravity.counts.exhausted == 1)
local alias1, alias2 = limit("anthropic-alias",0.3), limit("openai-alias",0.3)
alias1.scope = { shared=true, sharedGroup="pool" }
alias2.scope = { shared=true, sharedGroup="pool" }
local aliases = normalize({report("google-antigravity","shared@example.test",{alias1,alias2})}).providers[1].accounts[1].limits
assert(#aliases == 2); near(aliases[1].usedFraction,0.3); near(aliases[2].usedFraction,0.3)

-- Identity includes project/org; same email must still produce separate account rows.
local first = report("google-antigravity","same@example.test",{limit("a",0.1)})
local second = report("google-antigravity","same@example.test",{limit("a",0.8)})
first.metadata.projectId = "project-a"; second.metadata.projectId = "project-b"
local same = normalize({first, second}).providers[1].accounts
assert(#same == 2 and same[1].key ~= same[2].key and same[1].detail ~= same[2].detail)

-- Amount precedence follows OMP; unknown, exhausted and overage remain distinguishable.
local function amount(value, status)
	local l = limit("quota",nil)
	l.amount = value; l.status = status
	return normalize({report("anthropic","one@example.test",{l})}).providers[1].accounts[1].limits[1]
end
near(amount({usedFraction=0.2,used=90,limit=100,remainingFraction=0.7}).remaining,0.8)
near(amount({used=80,limit=100,remainingFraction=0.7}).remaining,0.2)
near(amount({used=30,unit="percent",remainingFraction=0.1}).remaining,0.7)
near(amount({remainingFraction=0.19}).remaining,0.19)
near(amount({remaining=20,limit=80}).remaining,0.25)
local missing = amount({unit="tokens"})
assert(missing.remaining == nil and missing.usedFraction == nil and missing.status == "unknown")
local over = amount({usedFraction=1.2})
near(over.remaining,-0.2); assert(over.status == "exhausted")
assert(amount({remainingFraction=0.15}).status == "ok")
assert(amount({remainingFraction=0.149}).status == "low")
assert(amount({usedFraction=1},"ok").status == "exhausted")
assert(amount({usedFraction=0.1},"warning").status == "low")
assert(amount({},"exhausted").remaining == nil)
assert(normalize({report("anthropic","empty@example.test",{})}).counts.unknown == 1)
assert(normalize({}).counts.accounts == 0)

-- Preserve provider caveats and rolling-window reset semantics rather than implying a full reset.
local rolling = limit("rolling",0.2)
rolling.window.resetLabel = "regen"
rolling.notes = {"Overage requests: 3"}
local observed = report("provider","one@example.test",{rolling})
observed.notes = {"OMP-observed spend only"}
local normalized = normalize({observed}).providers[1].accounts[1]
assert(normalized.limits[1].resetLabel == "regen")
assert(table.find(normalized.limits[1].notes,"Overage requests: 3"))
assert(table.find(normalized.notes,"OMP-observed spend only"))
assert(rolling.label == "Weekly" and observed.metadata.email == "one@example.test")

-- A successful collector poll cannot make old provider data fresh.
local aged = normalize({report("anthropic","private@example.test",{limit("weekly",0.1)})})
assert(usage.summary(aged,NOW+600000).tone == "success")
assert(usage.summary(aged,NOW+600001).tone == "warning")
aged.providers[1].accounts[1].fetchedAt = nil
assert(usage.summary(aged,NOW).tone == "warning")
local summary = usage.summary(snapshot,NOW)
assert(not string.find(summary.text,"@",1,true) and not string.find(summary.text,"%",1,true))

-- Bad schema must fail visibly, never replace a good snapshot with a fabricated empty one.
rejects(nil)
rejects({generatedAt=NOW})
rejects({generatedAt=NOW,reports="bad"})
rejects({generatedAt=NOW,reports={},accountsWithoutUsage="bad"})
rejects({generatedAt=NOW,reports={},disabledCredentials="bad"})
rejects({generatedAt=NOW,reports={{provider="x",limits={limit("a",0/0)}}}})
rejects({generatedAt=NOW,reports={{provider="x",limits={},notes={false}}}})
print("quota identity, precedence, freshness and schema checks passed")
