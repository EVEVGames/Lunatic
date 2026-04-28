-- tests/edge.lua
-- Additional coverage: session round-trip, provider builds for every adapter,
-- hooks firing in expected order, subagent kill, error paths.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Minimal JSON impl that actually round-trips simple data, so save/load
-- session can verify history reconstitution.
local fake_json = {}

-- Tiny pure-Lua JSON encoder (handles strings, numbers, booleans, tables).
local function enc(v)
    local t = type(v)
    if t == "string" then
        local s = v:gsub("\\", "\\\\"):gsub('"', '\\"')
                   :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. s .. '"'
    elseif t == "number" then
        return tostring(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        local is_array = (#v > 0)
        if not is_array then
            local has_keys = false
            for _ in pairs(v) do has_keys = true; break end
            if not has_keys then return "{}" end
        end
        local parts = {}
        if is_array then
            for i = 1, #v do parts[i] = enc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end
fake_json.encode = enc

-- Tiny JSON decoder for session round-trips. Handles only what enc produces.
local function dec(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value
    local function parse_string()
        if s:sub(pos, pos) ~= '"' then
            error("expected string at " .. pos)
        end
        pos = pos + 1
        local buf = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                local nc = s:sub(pos + 1, pos + 1)
                if nc == "n" then buf[#buf + 1] = "\n"
                elseif nc == "r" then buf[#buf + 1] = "\r"
                elseif nc == "t" then buf[#buf + 1] = "\t"
                elseif nc == "\\" then buf[#buf + 1] = "\\"
                elseif nc == '"' then buf[#buf + 1] = '"'
                elseif nc == "/" then buf[#buf + 1] = "/"
                else buf[#buf + 1] = nc end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parse_number()
        local start = pos
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c:match("[%-%d%.eE%+]") then
                pos = pos + 1
            else
                break
            end
        end
        return tonumber(s:sub(start, pos - 1))
    end

    local function parse_array()
        pos = pos + 1; skip_ws()
        local arr = {}
        if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            skip_ws()
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; return arr
            else error("expected , or ] at " .. pos) end
        end
    end

    local function parse_object()
        pos = pos + 1; skip_ws()
        local obj = {}
        if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            if s:sub(pos, pos) ~= ":" then error("expected : at " .. pos) end
            pos = pos + 1; skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; return obj
            else error("expected , or } at " .. pos) end
        end
    end

    parse_value = function()
        skip_ws()
        local c = s:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == "t" then pos = pos + 4; return true
        elseif c == "f" then pos = pos + 5; return false
        elseif c == "n" then pos = pos + 4; return nil
        else return parse_number() end
    end

    return parse_value()
end
fake_json.decode = dec

local fake_fs = { open = function(p, m) return io.open(p, m) end }

local provider_m = require("lunatic.provider")
provider_m.register("scripted", function()
    return { name = "scripted", chat = function(self, req, ctx)
        return { content = "stub", finish = "stop", raw = {} }, nil
    end }
end)

local workspace = "/tmp/lunatic_edge_" .. tostring(os.time()) .. "/"
os.execute('mkdir -p "' .. workspace .. '"')

local L = require("lunatic")

-- ============================================================
-- Test E1: Session save / load round-trip
-- ============================================================
print("[E1] Session save/load round-trip")

local lun = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json,
    fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end,
    builtin_tools = false,
})

lun:add_message({ role = "user", content = "first" })
lun:add_message({ role = "assistant", content = "ok one" })
lun:add_message({ role = "user", content = "second" })
lun.loop.compact_cursor = 2

local ok_save, save_err = lun:save_session("sess1")
assert(ok_save, "save failed: " .. tostring(save_err))

-- Fresh agent, load.
local lun2 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end,
    builtin_tools = false,
})
local ok_load, load_err = lun2:load_session("sess1")
assert(ok_load, "load failed: " .. tostring(load_err))
assert(#lun2.loop.history == 3, "history length restored: " .. #lun2.loop.history)
assert(lun2.loop.history[1].content == "first", "first message preserved")
assert(lun2.loop.history[2].content == "ok one", "second message preserved")
assert(lun2.loop.compact_cursor == 2, "cursor restored")

print("  OK")

-- ============================================================
-- Test E2: All built-in providers can be built
-- ============================================================
print("[E2] Provider builds for all built-in adapters")

local providers = { "openai", "openrouter", "generic_openai", "anthropic", "gemini", "ollama" }
for _, name in ipairs(providers) do
    local ok, err = pcall(function()
        local agent = L.Lunatic.new({
            workspace = workspace,
            http = function() return "{}", 200 end,
            json = fake_json, fs = fake_fs,
            llm = { provider = name, model = "any-model", api_key = "fake" },
            log = function() end, builtin_tools = false,
        })
        assert(agent.provider, name .. " provider object exists")
        assert(type(agent.provider.chat) == "function", name .. " has chat")
    end)
    assert(ok, "failed to build " .. name .. ": " .. tostring(err))
end

print("  OK (" .. #providers .. " providers)")

-- ============================================================
-- Test E3: Hooks fire in expected order on a tool-call iteration
-- ============================================================
print("[E3] Hook order")

local events = {}
local function rec(name)
    return function(payload) events[#events + 1] = name end
end

local lun3 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end,
    builtin_tools = false,
    hooks = {
        on_message       = rec("on_message"),
        on_iteration     = rec("on_iteration"),
        on_llm_request   = rec("on_llm_request"),
        on_llm_response  = rec("on_llm_response"),
        on_tool_call     = rec("on_tool_call"),
        on_tool_result   = rec("on_tool_result"),
        on_done          = rec("on_done"),
    },
})

lun3:register_tool({
    name = "ping", description = "ping",
    parameters = { type = "object", properties = {} },
}, function() return "pong" end)

local n = 0
lun3.provider.chat = function(self, req)
    n = n + 1
    if n == 1 then
        return { content = nil,
            tool_calls = { { id = "c1", name = "ping", arguments = {} } },
            finish = "tool_calls", raw = {} }, nil
    end
    return { content = "all done", finish = "stop", raw = {} }, nil
end

lun3:run("go")

-- Expected sequence (first iteration):
--   on_iteration, on_llm_request, on_llm_response,
--   on_message (assistant w/ tool_calls), on_tool_call, on_message (tool result), on_tool_result,
-- second iteration:
--   on_iteration, on_llm_request, on_llm_response, on_message (final), on_done
local function find(seq, name, from)
    for i = (from or 1), #seq do
        if seq[i] == name then return i end
    end
    return nil
end

local i_iter1 = find(events, "on_iteration")
local i_req1  = find(events, "on_llm_request", i_iter1)
local i_resp1 = find(events, "on_llm_response", i_req1)
local i_call  = find(events, "on_tool_call", i_resp1)
local i_res   = find(events, "on_tool_result", i_call)
local i_iter2 = find(events, "on_iteration", i_res)
local i_done  = find(events, "on_done", i_iter2)

assert(i_iter1 and i_req1 and i_resp1 and i_call and i_res, "first iteration events")
assert(i_iter2 and i_done, "second iteration + done")
assert(i_iter1 < i_req1 and i_req1 < i_resp1, "request before response")
assert(i_call < i_res, "tool call before tool result")
assert(i_iter2 > i_res, "second iteration after first tool result")

print("  OK (" .. #events .. " events fired)")

-- ============================================================
-- Test E4: Kill subagent
-- ============================================================
print("[E4] Kill subagent")

local lun4 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end, builtin_tools = false,
})

local h = lun4:spawn_subagent({ task = "do thing" })
assert(h:status() == "idle", "starts idle")
h:next() -- boots
local cancelled = lun4:cancel_subagent(h.id)
assert(cancelled, "cancel returns true")
assert(h:status() == "error", "cancelled subagent ends in error state")
local _, kerr = h:result()
assert(kerr == "cancelled", "cancel error message: " .. tostring(kerr))

print("  OK")

-- ============================================================
-- Test E5: Runner cancel
-- ============================================================
print("[E5] Runner cancel")

local lun5 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end, builtin_tools = false,
})
lun5.provider.chat = function() return { content = "hi", finish = "stop", raw = {} }, nil end

local runner = L.Runner.new(lun5)
runner:submit("go")
runner:cancel()
assert(runner:status() == "cancelled", "status cancelled")
assert(runner:is_ready(), "is_ready after cancel")
local _, cerr = runner:result()
assert(cerr == "cancelled", "result error: " .. tostring(cerr))

print("  OK")

-- ============================================================
-- Test E6: Custom provider registration
-- ============================================================
print("[E6] Custom provider registration")

L.register_provider("custom_test", function()
    return {
        name = "custom_test",
        chat = function(self, req, ctx)
            return { content = "from custom", finish = "stop", raw = {} }, nil
        end,
    }
end)

local lun6 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "custom_test", model = "anything" },
    log = function() end, builtin_tools = false,
})

local f, e = lun6:run("hi")
assert(not e, "no err: " .. tostring(e))
assert(f.content == "from custom", "custom provider used: " .. tostring(f.content))

print("  OK")

-- ============================================================
-- Test E7: tool error propagation (handler returns nil, err)
-- ============================================================
print("[E7] Tool error propagates as tool message")

local lun7 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end, builtin_tools = false,
})

lun7:register_tool({
    name = "broken", description = "always fails",
    parameters = { type = "object", properties = {} },
}, function() return nil, "intentional failure" end)

local turn = 0
lun7.provider.chat = function()
    turn = turn + 1
    if turn == 1 then
        return { content = nil,
            tool_calls = { { id = "c1", name = "broken", arguments = {} } },
            finish = "tool_calls", raw = {} }, nil
    end
    return { content = "ok", finish = "stop", raw = {} }, nil
end

lun7:run("go")
local found_err = false
for _, m in ipairs(lun7.loop.history) do
    if m.role == "tool" and type(m.content) == "string" and
        m.content:find("intentional failure") then
        found_err = true; break
    end
end
assert(found_err, "tool error appears in history")

print("  OK")

-- ============================================================
-- Test E8: clear_tools removes everything
-- ============================================================
print("[E8] clear_tools")

local lun8 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end, builtin_tools = true,
})
assert(#lun8:list_tools() > 0)
lun8:clear_tools()
assert(#lun8:list_tools() == 0)
assert(not lun8:has_tool("read_file"))

print("  OK")

-- ============================================================
-- Test E9: missing workspace gracefully degrades
-- ============================================================
print("[E9] Missing workspace -> empty bootstrap, no crash")

local lun9 = L.Lunatic.new({
    workspace = "/tmp/this_does_not_exist_xyz/",
    http = function() return "{}", 200 end,
    json = fake_json, fs = fake_fs,
    llm = { provider = "scripted", model = "x" },
    log = function() end, builtin_tools = false,
})

local boot = lun9.memory:read_bootstrap()
assert(boot == "", "empty bootstrap when workspace missing")
local sys = lun9.context:build_system_prompt()
assert(sys:find("Runtime Context"), "system prompt still has runtime block")

print("  OK")

-- Cleanup
os.execute('rm -rf "' .. workspace .. '"')
print("\nAll edge tests passed.")
