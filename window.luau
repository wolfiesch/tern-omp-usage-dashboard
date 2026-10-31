local current = { text = "Usage · loading", tone = "muted" }
local BLOCK = "omp-usage.dashboard"

local function open(cx)
	-- Reuse the panel in this session without moving any existing panes.
	local tabs = {}
	for _, session in cx.session:sessions() do
		if session.current then
			for _, tab in session.tabs do tabs[tab] = true end
		end
	end
	for _, pane in cx.session:panes() do
		if pane.block == BLOCK and tabs[pane.tab] and not pane.error then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if not cx:new_block(BLOCK, {}, "tab") then
		cx:toast("error", "Could not open OMP Usage", "Install the plugin on the current Tern host.")
	end
end

tern.command({
	id = "open", title = "Open OMP usage", icon = "gauge",
	keys = { "ctrl+alt+u" }, run = open,
})

tern.chrome.status(function()
	return {{ text = current.text, tone = current.tone, icon = "gauge", command = "plugin.omp-usage.open" }}
end)

local function pollOnce()
	local ok, record = pcall(tern.kv.get, "collector")
	local nextValue
	if not ok then
		nextValue = { text = "Usage · cache error", tone = "warning" }
	elseif type(record) ~= "table" or type(record.heartbeat) ~= "number"
		or os.time() * 1000 - record.heartbeat > 15_000 then
		nextValue = { text = "Usage · collector offline", tone = "warning" }
	else
		nextValue = { text = record.text or "Usage · loading", tone = record.tone or "muted" }
	end
	if current.text ~= nextValue.text or current.tone ~= nextValue.tone then
		current = nextValue
		tern.chrome.refresh()
	end
end

local function poll()
	-- Re-arm before work so one slow or failed read cannot freeze the status segment.
	tern.timer(2000, poll)
	pcall(pollOnce)
end

-- Window callbacks only read the small summary; provider polling belongs to the host.
tern.timer(100, poll)
