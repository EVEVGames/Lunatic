-- tests/smoke.lua
-- Exercises every Lunatic module without making real network calls.
-- We inject a fake provider, fake http, fake fs, and fake json to verify
-- the loop / runner / autocompact / subagent flows.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ============================================================
-- Fake JSON: encode tables to a string, decode strings back.
-- We just round-trip via a Lua-table marker so we don't need a real encoder.
-- ============================================================
local fake_json = {}
local function _serialise(v, depth)
    depth = depth or 0
    if depth > 20 then return "null" end
    local t = type(v)
    if t == "string" then
        return string.format("%q", v):gsub("\\\n", "\\n")
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        -- decide array vs object
        local is_array = #v > 0
        local parts = {}
        if is_array then
            for i = 1, #v do parts[#parts + 1] = _serialise(v[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. _serialise(val, depth + 1)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end
function fake_json.encode(v) return _serialise(v) end
function fake_json.decode(s)
    -- Tests that need decode use canned fixtures; this is just for round-trip.
    -- We return an empty table to avoid having to implement a real parser.
    return {}
end

-- ============================================================
-- Fake fs that uses real io.open under the hood (test runs in tmp dir)
-- ============================================================
local fake_fs = { open = function(p, m) return io.open(p, m) end }

-- ============================================================
-- Fake provider factory: returns canned responses scripted in a table.
-- ============================================================
local provider_m = require("lunatic.provider")

local function make_scripted_provider(script)
    -- script is an array of fake response tables; chat() returns them in order.
    local idx = 0
    local adapter = {
        name = "scripted",
        chat = function(self, req, ctx)
            idx = idx + 1
            local resp = script[idx]
            if not resp then
                return { content = "(end of script)", finish = "stop", raw = {} }, nil
            end
            return resp, nil
        end,
    }
    return adapter
end
provider_m.register("scripted", function() return make_scripted_provider({}) end)

-- ============================================================
-- Pre-populate workspace inside /tmp
-- ============================================================
local workspace = "/tmp/lunatic_test_" .. tostring(os.time()) .. "/"
os.execute('mkdir -p "' .. workspace .. '"')

-- Seed AGENTS.md
local seed = io.open(workspace .. "AGENTS.md", "wb")
seed:write("You are a test agent. Always answer briefly.\n")
seed:close()

-- ============================================================
-- Test 1: Lunatic boots, tools register, listing works
-- ============================================================
print("[test 1] Lunatic boot + tools")

local L = require("lunatic")
local lun = L.Lunatic.new({
    workspace = workspace,
    http = function(opts) return "{}", 200 end,
    json = fake_json,
    fs = fake_fs,
    llm = { provider = "scripted", model = "mock-1" },
    log = function() end, -- silence in test
    builtin_tools = true,
})

assert(lun:has_tool("read_file"))
assert(lun:has_tool("save_memory"))
assert(lun:has_tool("spawn_subagent"))
assert(#lun:list_tools() >= 7)

-- Register a custom function tool
local called_with
lun:register_tool({
    name = "echo",
    description = "Echoes its input",
    parameters = { type = "object", properties = { msg = { type = "string" } }, required = { "msg" } },
}, function(args, ctx)
    called_with = args
    return "echoed: " .. tostring(args.msg)
end)
assert(lun:has_tool("echo"))

-- Unregister and confirm it's gone
lun:unregister_tool("echo")
assert(not lun:has_tool("echo"))

-- Disable / enable
lun:disable_tool("read_file")
local list = lun:list_tools()
local found_disabled = false
for _, t in ipairs(list) do
    if t["function"].name == "read_file" then found_disabled = true end
end
assert(not found_disabled, "disabled tool should not appear in list")
lun:enable_tool("read_file")

print("  OK")

-- ============================================================
-- Test 2: Memory store reads bootstrap
-- ============================================================
print("[test 2] Memory bootstrap read")

local boot = lun.memory:read_bootstrap()
assert(boot:find("test agent"), "should read AGENTS.md content")

local sys = lun.context:build_system_prompt()
assert(sys:find("test agent"), "system prompt should contain bootstrap")
assert(sys:find("Runtime Context"), "system prompt should contain runtime block")

print("  OK")

-- ============================================================
-- Test 3: Single-iteration final answer (no tool calls)
-- ============================================================
print("[test 3] Simple final answer")

-- Replace adapter with a scripted one returning a final answer.
lun.provider.chat = function(self, req)
    return {
        content = "hi there",
        finish = "stop",
        raw = {},
    }, nil
end

local final, err = lun:run("hello")
assert(not err, "no error: " .. tostring(err))
assert(final and final.content == "hi there", "got final answer")
assert(lun.loop.status == "done")

print("  OK")

-- ============================================================
-- Test 4: Tool-calling iteration
-- ============================================================
print("[test 4] Tool call dispatch")

lun:reset()

-- Re-register a function tool
lun:register_tool({
    name = "echo",
    description = "Echoes its input",
    parameters = { type = "object", properties = { msg = { type = "string" } }, required = { "msg" } },
}, function(args)
    return "ECHO: " .. tostring(args.msg)
end)

local call_count = 0
lun.provider.chat = function(self, req)
    call_count = call_count + 1
    if call_count == 1 then
        return {
            content = nil,
            tool_calls = {
                { id = "call_1", name = "echo", arguments = { msg = "hello world" } },
            },
            finish = "tool_calls",
            raw = {},
        }, nil
    else
        return {
            content = "tool said: ECHO: hello world",
            finish = "stop",
            raw = {},
        }, nil
    end
end

local final2, err2 = lun:run("please echo")
assert(not err2, "no error: " .. tostring(err2))
assert(final2.content:find("hello world"), "final mentions echoed text")
assert(call_count == 2, "two LLM calls were made (got " .. call_count .. ")")

print("  OK")

-- ============================================================
-- Test 5: Runner cooperative execution
-- ============================================================
print("[test 5] Runner :next / :is_ready")

lun:reset()
call_count = 0
lun.provider.chat = function(self, req)
    call_count = call_count + 1
    if call_count == 1 then
        return {
            content = nil,
            tool_calls = { { id = "c1", name = "echo", arguments = { msg = "ping" } } },
            finish = "tool_calls", raw = {},
        }, nil
    else
        return { content = "pong", finish = "stop", raw = {} }, nil
    end
end

local Runner = L.Runner
local runner = Runner.new(lun)
runner:submit("ping?")

local steps = 0
while not runner:is_ready() and steps < 100 do
    runner:next()
    steps = steps + 1
end

assert(runner:is_ready(), "runner finished")
assert(runner:status() == "done", "runner status is done")
local result, rerr = runner:result()
assert(not rerr, "no result error")
assert(result == "pong", "got result string: " .. tostring(result))
assert(steps > 1, "took multiple ticks (got " .. steps .. ")")

print("  OK (" .. steps .. " ticks)")

-- ============================================================
-- Test 6: Autocompact triggers
-- ============================================================
print("[test 6] Autocompact threshold")

local L2 = require("lunatic")
local lun2 = L2.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json,
    fs = fake_fs,
    llm = { provider = "scripted", model = "mock" },
    log = function() end,
    builtin_tools = false,
    autocompact = { enabled = true, max_messages = 5, keep_last = 2, persist = false },
})

-- Stuff history
for i = 1, 8 do
    lun2:add_message({ role = "user", content = "old message " .. i })
    lun2:add_message({ role = "assistant", content = "old reply " .. i })
end

local original_size = #lun2.loop.history
assert(original_size == 16, "history seeded")

-- Provider returns a summary then a final.
local turns = 0
lun2.provider.chat = function(self, req)
    turns = turns + 1
    if turns == 1 then
        -- This is the compact call
        return { content = "- consolidated note", finish = "stop", raw = {} }, nil
    end
    return { content = "ok", finish = "stop", raw = {} }, nil
end

local _, cerr = lun2:compact()
assert(not cerr, "compact ran: " .. tostring(cerr))
assert(#lun2.loop.history < original_size, "history shrunk after compact")
local found_summary = false
for _, m in ipairs(lun2.loop.history) do
    if m.role == "system" and type(m.content) == "string" and
        m.content:find("consolidated") then
        found_summary = true; break
    end
end
assert(found_summary, "summary message inserted")

print("  OK (history " .. original_size .. " -> " .. #lun2.loop.history .. ")")

-- ============================================================
-- Test 7: Subagent spawn and run cooperatively
-- ============================================================
print("[test 7] Subagent spawn")

local lun3 = L.Lunatic.new({
    workspace = workspace,
    http = function() return "{}", 200 end,
    json = fake_json,
    fs = fake_fs,
    llm = { provider = "scripted", model = "mock" },
    log = function() end,
    builtin_tools = false,
})

-- Sub uses scripted provider that returns final answer immediately.
local sub_calls = 0
local handle = lun3:spawn_subagent({ task = "do thing" })
-- Override the sub's provider AFTER it was created (handle inits lazily on next).
-- We need to drive one next() to instantiate, then override.
handle:next()
handle.lunatic.provider.chat = function(self, req)
    sub_calls = sub_calls + 1
    return { content = "subagent answer #" .. sub_calls, finish = "stop", raw = {} }, nil
end

local steps2 = 0
while not handle:is_ready() and steps2 < 100 do
    handle:next()
    steps2 = steps2 + 1
end

assert(handle:is_ready(), "subagent finished")
local sres, serr = handle:result()
assert(not serr, "no err: " .. tostring(serr))
assert(sres and sres:find("subagent answer"), "got sub result: " .. tostring(sres))

print("  OK")

-- ============================================================
-- Test 8: Tool registered as module-path string
-- ============================================================
print("[test 8] String-handler tool (module path)")

-- Create a tiny module file in the tmp dir and add to package.path.
local mod_dir = workspace
package.path = mod_dir .. "?.lua;" .. package.path

local mod_file = io.open(mod_dir .. "my_string_tool.lua", "wb")
mod_file:write([[
local args, ctx = ...
if type(args) ~= "table" then return nil, "args required" end
return "module-tool got: " .. tostring(args.x)
]])
mod_file:close()

lun3:register_tool({
    name = "my_string_tool",
    description = "A tool implemented as an external module",
    parameters = {
        type = "object",
        properties = { x = { type = "string" } },
        required = { "x" },
    },
}, "my_string_tool")

-- Drive a tool call through the loop directly:
lun3:reset()
local called_n = 0
lun3.provider.chat = function(self, req)
    called_n = called_n + 1
    if called_n == 1 then
        return {
            content = nil,
            tool_calls = { { id = "c1", name = "my_string_tool", arguments = { x = "hi" } } },
            finish = "tool_calls", raw = {},
        }, nil
    end
    return { content = "done", finish = "stop", raw = {} }, nil
end

local final3 = lun3:run("invoke")
assert(final3, "ran")
-- Find tool result message in history
local found = false
for _, m in ipairs(lun3.loop.history) do
    if m.role == "tool" and type(m.content) == "string" and
        m.content:find("module%-tool got: hi") then
        found = true; break
    end
end
assert(found, "module tool result captured in history")

print("  OK")

-- ============================================================
-- Cleanup
-- ============================================================
os.execute('rm -rf "' .. workspace .. '"')
print("\nAll smoke tests passed.")
