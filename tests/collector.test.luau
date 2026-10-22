local Collector = require("../collector")
local function harness(priorLease)
	local h = { time = 100_000, calls = 0, record = nil, callback = nil, throws = false }
	h.collector = Collector.new({
		now = function() return h.time end,
		fetch = function(_, callback)
			h.calls += 1
			if h.throws then error("private path / secret stderr") end
			h.callback = callback
		end,
		decode = function(text)
			if text == "invalid" then error("bad JSON") end
			return text
		end,
		normalize = function(value)
			if value == "unsupported" then error("unknown schema") end
			return { value = value }
		end,
		summary = function() return { text = "Usage · 2 accounts", tone = "muted" } end,
		publish = function(record) h.record = record end,
		changed = function() end,
	}, priorLease)
	function h:finish(status, stdout, timedOut)
		self.callback({ status = status, stdout = stdout, timed_out = timedOut == true })
	end
	return h
end

-- Multiple views/manual refreshes must not produce concurrent quota requests.
local h = harness()
h.collector:tick()
assert(h.calls == 1 and h.record.refreshing)
for _ = 1, 5 do h.collector:refresh(); h.collector:tick() end
assert(h.calls == 1)
h:finish(0, "good")
local good = h.collector.snapshot
local success = h.collector.status.lastSuccess
assert(good.value == "good" and not h.record.refreshing)
h.time += 59_999
h.collector:tick()
assert(h.calls == 1)
h.time += 1
h.collector:tick()
assert(h.calls == 2)

-- Failures preserve the actual snapshot and successful-fetch timestamp, never an empty success.
h:finish(1, "sensitive output")
assert(h.collector.snapshot == good and h.collector.status.lastSuccess == success)
assert(h.record.text == "Usage · stale" and h.collector.status.error ~= nil)
for _, result in { "invalid", "unsupported" } do
	h.collector:refresh()
	h:finish(0, result)
	assert(h.collector.snapshot == good and h.collector.status.lastSuccess == success)
end
h.collector:refresh()
h:finish(-1, "", true)
assert(string.find(h.collector.status.error, "30s", 1, true))
h.collector:refresh()
h:finish(0, "recovered")
assert(h.collector.snapshot.value == "recovered" and h.collector.status.error == nil)

-- A process launched before reload still has its deadline; the new VM waits it out.
local afterReload = harness(125_000)
afterReload.collector:tick()
assert(afterReload.calls == 0)
afterReload.time = 125_000
afterReload.collector:tick()
assert(afterReload.calls == 1)

-- A missing executable must release single-flight state and allow explicit retry.
local missing = harness()
missing.throws = true
missing.collector:refresh()
assert(not missing.collector.status.refreshing and missing.collector.leaseUntil == 0)
assert(missing.record.text == "Usage · unavailable")
assert(not string.find(missing.collector.status.error, "secret", 1, true))
missing.throws = false
missing.collector:refresh()
missing:finish(0, "installed")
assert(missing.collector.snapshot.value == "installed")
print("collector lifecycle checks passed")
