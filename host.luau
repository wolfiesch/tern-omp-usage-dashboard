local usage = require("./usage")
local view = require("./view")
local Collector = require("./collector")

local blocks = {}
local function now() return os.time() * 1000 end
local function renderLive()
	local live = {}
	for _, pane in tern.pane.list() do live[pane.pane] = true end
	for pane, cx in blocks do
		if live[pane] then cx:render() else blocks[pane] = nil end
	end
end

local home = tern.getenv("HOME") or tern.getenv("USERPROFILE") or ""
local binary = tern.getenv("TERN_OMP_BIN")
if not binary or binary == "" then
	local localBin = home .. "/.local/bin/omp"
	binary = if home ~= "" and tern.fs.exists(localBin) then localBin else "omp"
end

-- GUI-launched daemons may lack the runtime used by an OMP development launcher.
-- Add only conventional user executable directories; never invoke a login shell.
local search = {}
local binDir = binary:match("^(.*)[/\\]")
if binDir and binDir ~= "" then table.insert(search, binDir) end
if home ~= "" then
	table.insert(search, home .. "/.local/bin")
	table.insert(search, home .. "/.bun/bin")
end
table.insert(search, tern.getenv("PATH") or "/usr/bin:/bin")
local processEnv = { PATH = table.concat(search, if tern.runtime.os == "windows" then ";" else ":") }

-- Only the host writes this store. Windows read a small, identity-free status record.
local previous = tern.kv.get("collector")
local collector = Collector.new({
	now = now,
	normalize = usage.normalize,
	summary = usage.summary,
	decode = tern.json.decode,
	fetch = function(timeout, done)
		tern.process.run({ binary, "usage", "--json" }, { timeout_ms = timeout, env = processEnv }, done)
	end,
	publish = function(record) tern.kv.set("collector", record) end,
	changed = renderLive,
}, if type(previous) == "table" then previous.leaseUntil else nil)

tern.block.define("dashboard", {
	init = function(cx, _args, _saved)
		blocks[cx.pane] = cx
		return {}
	end,
	title = function() return "OMP Usage" end,
	view = function(_state, _cx)
		return view.render(collector.snapshot, collector.status, now(), tern.ui)
	end,
	key = function(_state, key, _cx)
		if key.name == "r" and not key.ctrl and not key.alt and not key.meta then
			collector:refresh()
			return true
		end
		return false
	end,
	event = function(_state, ev, _cx)
		if ev.ev == "action" and ev.act == "refresh" then collector:refresh() end
	end,
})

local function tick()
	collector:tick()
	tern.timer(5000, tick)
end
-- Defer IO until the entries and restored blocks have loaded.
tern.timer(100, tick)
