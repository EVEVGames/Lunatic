-- lunatic/runner.lua
-- Cooperative scheduler that wraps a Lunatic instance in a coroutine,
-- allowing external code to advance the agent step-by-step.
--
-- Typical usage:
--   local runner = Runner.new(lunatic)
--   runner:submit("hello")
--   while not runner:is_ready() do
--       runner:next()
--       -- yield to your own event loop here (sleep / select / etc.)
--   end
--   local result, err = runner:result()
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local M = {}
local Runner = {}
Runner.__index = Runner

function M.new(lunatic_instance)
    if not lunatic_instance then
        error("Runner.new requires a Lunatic instance")
    end
    local self = setmetatable({}, Runner)
    self.lunatic = lunatic_instance
    self.co = nil
    self._status = "idle"   -- idle | running | done | error | cancelled
    self._result = nil
    self._error = nil
    self._last_yield = nil
    return self
end

-- Start a new task. Replaces any existing coroutine. Does NOT advance — call
-- :next() afterwards to actually execute the first step.
function Runner:submit(user_message)
    self._result = nil
    self._error = nil
    self._last_yield = nil
    self._status = "running"

    local lunatic = self.lunatic
    -- Reset loop state for a fresh task.
    lunatic.loop:reset()

    self.co = coroutine.create(function()
        lunatic.loop._inside_coroutine = true
        local final, err = lunatic.loop:run(user_message)
        lunatic.loop._inside_coroutine = false
        if err then
            return "error", err
        end
        local text = (type(final) == "table" and final.content) or ""
        return "ok", text, final
    end)
    return true
end

-- Advance the agent to the next yield point (or completion).
-- Returns (status, yield_data). status is "running" | "done" | "error" | "cancelled".
function Runner:next()
    if self._status == "done" or self._status == "error" or self._status == "cancelled" then
        return self._status, nil
    end
    if not self.co then
        return "idle", nil
    end
    if coroutine.status(self.co) == "dead" then
        self._status = self._error and "error" or "done"
        return self._status, nil
    end

    local resumed = { coroutine.resume(self.co) }
    local ok = resumed[1]
    if not ok then
        self._error = "agent crashed: " .. tostring(resumed[2])
        self._status = "error"
        return self._status, nil
    end

    if coroutine.status(self.co) == "dead" then
        local kind = resumed[2]
        if kind == "ok" then
            self._result = resumed[3] or ""
            -- resumed[4] would be the message table if returned
            self._status = "done"
        elseif kind == "error" then
            self._error = resumed[3] or "agent error"
            self._status = "error"
        else
            self._result = tostring(kind or "")
            self._status = "done"
        end
        return self._status, nil
    end

    -- Still alive; payload is yield args.
    self._last_yield = { stage = resumed[2], data = resumed[3] }
    return "running", self._last_yield
end

function Runner:is_ready()
    return self._status == "done" or self._status == "error" or self._status == "cancelled"
end

function Runner:result()
    if self._status == "error" then
        return nil, self._error
    end
    if self._status == "cancelled" then
        return nil, "cancelled"
    end
    return self._result, nil
end

function Runner:status()
    return self._status
end

function Runner:last_yield()
    return self._last_yield
end

-- Cancel the current task. Cannot truly kill a coroutine in standard Lua, so
-- we just stop scheduling it and mark the runner cancelled. Any in-flight
-- network call that has already been issued will run to completion before the
-- coroutine is garbage-collected.
function Runner:cancel()
    if self._status == "running" then
        self._status = "cancelled"
        self._error = "cancelled"
    end
    return true
end

return M
