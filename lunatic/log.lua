-- lunatic/log.lua
-- Default logger: enriched print-style formatter.
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}

local LEVEL_RANK = {
    debug = 1,
    info  = 2,
    warn  = 3,
    error = 4,
}

-- Cheap inline serialiser for log payloads: avoids requiring a json lib here
-- so the logger can be used before json is wired up. Truncates long strings.
local function fmt_value(v, depth, max_depth)
    depth = depth or 0
    max_depth = max_depth or 2
    local t = type(v)
    if t == "string" then
        if #v > 200 then
            return string.format("%q", v:sub(1, 200) .. "...")
        end
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "table" then
        if depth >= max_depth then
            return "{...}"
        end
        local parts = {}
        local count = 0
        for k, val in pairs(v) do
            count = count + 1
            if count > 8 then
                parts[#parts + 1] = "..."
                break
            end
            local key_str
            if type(k) == "string" then
                key_str = k
            else
                key_str = "[" .. tostring(k) .. "]"
            end
            parts[#parts + 1] = key_str .. "=" .. fmt_value(val, depth + 1, max_depth)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    else
        return "<" .. t .. ">"
    end
end

-- Build the default logger function. Takes options:
--   min_level: "debug" | "info" | "warn" | "error" (default "info")
--   writer:    function(line) — defaults to io.write + newline
function M.build_default(options)
    options = options or {}
    local min = LEVEL_RANK[options.min_level or "info"] or 2
    local writer = options.writer or function(line)
        io.write(line)
        io.write("\n")
    end

    return function(level, event, data)
        local rank = LEVEL_RANK[level] or 2
        if rank < min then
            return
        end
        local ts = util.iso_timestamp()
        local agent_id = "?"
        local payload = ""
        if type(data) == "table" then
            agent_id = data.agent_id or "?"
            -- Render everything except agent_id into payload string
            local fields = {}
            for k, v in pairs(data) do
                if k ~= "agent_id" then
                    fields[#fields + 1] = k .. "=" .. fmt_value(v)
                end
            end
            payload = table.concat(fields, " ")
        elseif data ~= nil then
            payload = fmt_value(data)
        end
        local line = string.format(
            "[%s][%s][%s] %s %s",
            ts, agent_id, level, tostring(event), payload
        )
        local ok, err = pcall(writer, line)
        if not ok then
            -- last resort: do not crash the agent over a bad logger
            io.stderr:write("lunatic logger error: " .. tostring(err) .. "\n")
        end
    end
end

-- A no-op logger (use when caller wants total silence).
function M.noop()
    return function() end
end

return M
