-- One collector per host VM. Dependencies are injected for deterministic lifecycle checks.
local M = {}
local INTERVAL = 60_000
local TIMEOUT = 30_000
local LEASE = TIMEOUT + 5_000

function M.new(deps, priorLease)
	local self = {
		snapshot = nil,
		status = { refreshing = false },
		leaseUntil = math.min(tonumber(priorLease) or 0, deps.now() + LEASE),
		nextFetch = 0,
	}

	function self:publish()
		local now = deps.now()
		self.status.heartbeat = now
		local summary = if self.snapshot then deps.summary(self.snapshot, now)
			else { text = "Usage · loading", tone = "muted" }
		if self.status.error then
			summary = { text = "Usage · " .. (if self.snapshot then "stale" else "unavailable"), tone = "warning" }
		end
		deps.publish({
			text = summary.text, tone = summary.tone, heartbeat = now,
			leaseUntil = self.leaseUntil, refreshing = self.status.refreshing,
			error = self.status.error,
		})
		deps.changed()
	end

	local function finish(snapshot, message)
		self.status.refreshing = false
		self.leaseUntil = 0
		self.nextFetch = deps.now() + INTERVAL
		if snapshot then
			self.snapshot = snapshot
			self.status.lastSuccess = deps.now()
			self.status.error = nil
		else
			-- Keep the last good snapshot and its timestamps, not a fresh-looking empty list.
			self.status.error = message
		end
		self:publish()
	end

	function self:refresh()
		local now = deps.now()
		if self.status.refreshing or now < self.leaseUntil then return false end
		self.status.refreshing = true
		self.leaseUntil = now + LEASE
		-- Save the process deadline before spawning. Reload drops the callback, not the process.
		self:publish()
		local ok = pcall(deps.fetch, TIMEOUT, function(result)
			if result.timed_out then
				finish(nil, "Usage refresh timed out after 30s. Press r to retry.")
			elseif result.status ~= 0 then
				finish(nil, "OMP usage failed (exit " .. tostring(result.status) .. "). Check omp usage, then press r.")
			else
				local parsed, snapshot = pcall(function()
					return deps.normalize(deps.decode(result.stdout))
				end)
				if parsed then finish(snapshot, nil)
				else finish(nil, "OMP returned an unsupported usage report. Check omp usage --json, then press r.") end
			end
		end)
		if not ok then
			finish(nil, "Could not start omp. Install it on Tern's PATH or set TERN_OMP_BIN, then reload the plugin.")
		end
		return true
	end

	function self:tick()
		if deps.now() >= self.nextFetch and not self.status.refreshing and deps.now() >= self.leaseUntil then
			self:refresh()
		else
			self:publish()
		end
	end

	return self
end

return M
