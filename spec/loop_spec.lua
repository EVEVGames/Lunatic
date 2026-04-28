-- spec/loop_spec.lua
-- Tests for lunatic.loop AgentLoop. We exercise the loop through a Lunatic
-- instance with a scripted provider, since wiring AgentLoop directly is
-- tedious and the public API is what matters.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local Loop    = require("lunatic.loop")

local describe, it, expect = t.describe, t.it, t.expect
local before_each = t.before_each

-- Ensure scripted provider is registered.
do
    local pm = require("lunatic.provider")
    if not pm.has("scripted") then
        pm.register("scripted", function()
            return { name = "scripted",
                chat = function() return { content = "?", finish = "stop", raw = {} }, nil end }
        end)
    end
end

describe("AgentLoop: kind constants", function()
    it("exposes integer message-kind constants", function()
        expect(Loop.MK_USER_TEXT):is_a("number")
        expect(Loop.MK_TOOL_CALL):is_a("number")
        expect(Loop.MK_TOOL_RESULT):is_a("number")
        expect(Loop.MK_COMPACT_SUMMARY):is_a("number")
        expect(Loop.MK_SUBAGENT_CALL):is_a("number")
        expect(Loop.MK_SUBAGENT_RESULT):is_a("number")
    end)

    it("KIND_NAME maps integers to friendly strings", function()
        expect(Loop.KIND_NAME[Loop.MK_USER_TEXT]):eq("user_text")
        expect(Loop.KIND_NAME[Loop.MK_TOOL_CALL]):eq("tool_call")
        expect(Loop.KIND_NAME[Loop.MK_COMPACT_SUMMARY]):eq("compact_summary")
    end)
end)

describe("AgentLoop: add_message", function()
    local agent
    before_each(function() agent = helpers.build_agent() end)

    it("appends and returns the index", function()
        local idx = agent:add_message({ role = "user", content = "hello" })
        expect(idx):eq(1)
        expect(#agent.loop.history):eq(1)
    end)

    it("rejects bad input", function()
        local idx, err = agent:add_message("not a table")
        expect(idx):nil_()
        expect(err):not_nil()
    end)

    it("rejects messages without role", function()
        local idx, err = agent:add_message({ content = "x" })
        expect(idx):nil_()
        expect(err):contains("role")
    end)

    it("infers MK_USER_TEXT for user role", function()
        local idx = agent:add_message({ role = "user", content = "hi" })
        expect(agent.loop.kinds[idx]):eq(Loop.MK_USER_TEXT)
    end)

    it("infers MK_ASSISTANT_TEXT for plain assistant", function()
        local idx = agent:add_message({ role = "assistant", content = "ok" })
        expect(agent.loop.kinds[idx]):eq(Loop.MK_ASSISTANT_TEXT)
    end)

    it("infers MK_TOOL_CALL when tool_calls present", function()
        local idx = agent:add_message({
            role = "assistant", content = nil,
            tool_calls = { { id = "x", ["function"] = { name = "ping" } } },
        })
        expect(agent.loop.kinds[idx]):eq(Loop.MK_TOOL_CALL)
    end)

    it("infers MK_SUBAGENT_CALL when tool_calls is spawn_subagent", function()
        local idx = agent:add_message({
            role = "assistant", content = nil,
            tool_calls = { { id = "x",
                ["function"] = { name = "spawn_subagent", arguments = '{"task":"x"}' } } },
        })
        expect(agent.loop.kinds[idx]):eq(Loop.MK_SUBAGENT_CALL)
    end)

    it("respects explicit kind override", function()
        local idx = agent:add_message(
            { role = "assistant", content = "x" }, Loop.MK_PINNED_NOTE)
        expect(agent.loop.kinds[idx]):eq(Loop.MK_PINNED_NOTE)
    end)
end)

describe("AgentLoop: messages() structured view", function()
    local agent
    before_each(function() agent = helpers.build_agent() end)

    it("returns empty list for empty conversation", function()
        local msgs = agent:messages()
        expect(#msgs):eq(0)
    end)

    it("returns one entry per message with kind tag", function()
        agent:add_message({ role = "user", content = "hi" })
        agent:add_message({ role = "assistant", content = "yo" })
        local msgs = agent:messages()
        expect(#msgs):eq(2)
        expect(msgs[1].kind):eq("user_text")
        expect(msgs[2].kind):eq("assistant_text")
        expect(msgs[1].content):eq("hi")
    end)

    it("exposes tool_calls structurally", function()
        agent:add_message({
            role = "assistant", content = nil,
            tool_calls = { { id = "c1",
                ["function"] = { name = "echo", arguments = "{\"x\":1}" } } },
        })
        local msgs = agent:messages()
        expect(msgs[1].kind):eq("tool_call")
        expect(msgs[1].tool_calls):not_nil()
        expect(msgs[1].tool_calls[1].name):eq("echo")
        expect(msgs[1].tool_calls[1].id):eq("c1")
    end)

    it("exposes tool result fields", function()
        agent:add_message({
            role = "tool", tool_call_id = "c1", name = "echo", content = "result"
        })
        local msgs = agent:messages()
        expect(msgs[1].kind):eq("tool_result")
        expect(msgs[1].tool_call_id):eq("c1")
        expect(msgs[1].tool_name):eq("echo")
    end)

    it("filters system messages with include_system=false", function()
        agent:add_message({ role = "system", content = "policy" })
        agent:add_message({ role = "user", content = "hi" })
        local msgs = agent:messages({ include_system = false })
        expect(#msgs):eq(1)
        expect(msgs[1].kind):eq("user_text")
    end)

    it("includes pinned flag", function()
        local idx = agent:add_message({ role = "user", content = "important" })
        agent.loop:pin(idx)
        local msgs = agent:messages()
        expect(msgs[1].pinned):truthy()
    end)

    it("provides agent_id on every entry", function()
        agent:add_message({ role = "user", content = "hi" })
        local msgs = agent:messages()
        expect(msgs[1].agent_id):eq("main")
    end)
end)

describe("AgentLoop: run with scripted provider", function()
    local agent
    before_each(function() agent = helpers.build_agent() end)

    it("returns final assistant message on plain answer", function()
        helpers.script_provider(agent,
            { { content = "the answer is 42", finish = "stop", raw = {} } })
        local final, err = agent:run("what?")
        expect(err):nil_()
        expect(final.content):eq("the answer is 42")
        expect(agent.loop.status):eq("done")
    end)

    it("dispatches tool_calls and re-iterates", function()
        agent:register_tool({ name = "double",
            parameters = { type = "object",
                properties = { n = { type = "number" } } } },
            function(args) return tostring((args.n or 0) * 2) end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "double", arguments = { n = 5 } } },
              finish = "tool_calls", raw = {} },
            { content = "result is 10", finish = "stop", raw = {} },
        })
        local final, err = agent:run("double 5")
        expect(err):nil_()
        expect(final.content):eq("result is 10")
        local found_tool_result = false
        for _, m in ipairs(agent.loop.history) do
            if m.role == "tool" and m.content == "10" then
                found_tool_result = true
            end
        end
        expect(found_tool_result):truthy()
    end)

    it("stops at max_iterations", function()
        agent.loop.max_iterations = 3
        -- Provider keeps issuing tool calls forever
        agent:register_tool({ name = "noop",
            parameters = { type = "object", properties = {} } },
            function() return "ok" end)
        agent.provider.chat = function()
            return { content = nil,
                tool_calls = { { id = "x", name = "noop", arguments = {} } },
                finish = "tool_calls", raw = {} }, nil
        end
        local final, err = agent:run("loop forever")
        expect(final):nil_()
        expect(err):contains("max_iterations")
    end)

    it("reports provider error", function()
        helpers.script_provider(agent, {
            { content = nil, finish = "error", error = "rate limited", raw = {} },
        })
        local final, err = agent:run("hi")
        expect(final):nil_()
        expect(err):contains("rate")
    end)
end)

describe("AgentLoop: autocompact", function()
    it("collapses old history into a summary", function()
        local agent = helpers.build_agent({
            autocompact = { enabled = true, max_messages = 4,
                            keep_last = 2, persist = false },
        })
        for i = 1, 6 do
            agent:add_message({ role = "user", content = "u" .. i })
            agent:add_message({ role = "assistant", content = "a" .. i })
        end
        local before = #agent.loop.history
        helpers.script_provider(agent,
            { { content = "compact note", finish = "stop", raw = {} } })
        agent:compact()
        expect(#agent.loop.history):lt(before)
        local found = false
        for _, m in ipairs(agent.loop.history) do
            if m.role == "system" and type(m.content) == "string"
                and m.content:find("compact note", 1, true) then
                found = true
            end
        end
        expect(found):truthy()
    end)

    it("tags compact summary with MK_COMPACT_SUMMARY", function()
        local agent = helpers.build_agent({
            autocompact = { enabled = true, max_messages = 2,
                            keep_last = 1, persist = false },
        })
        for i = 1, 4 do
            agent:add_message({ role = "user", content = "u" .. i })
        end
        helpers.script_provider(agent,
            { { content = "x", finish = "stop", raw = {} } })
        agent:compact()
        local has_summary = false
        for i, k in pairs(agent.loop.kinds) do
            if k == Loop.MK_COMPACT_SUMMARY then has_summary = true end
        end
        expect(has_summary):truthy()
    end)

    it("does not compact when no candidate slice (already-cursored)", function()
        local agent = helpers.build_agent({
            autocompact = { enabled = true, max_messages = 4,
                            keep_last = 10, persist = false },
        })
        agent:add_message({ role = "user", content = "u1" })
        local before = #agent.loop.history
        agent:compact()
        expect(#agent.loop.history):eq(before)
    end)
end)

describe("AgentLoop: cancel", function()
    it("marks status as error with 'cancelled'", function()
        local agent = helpers.build_agent()
        agent.loop.status = "running"
        agent:cancel()
        expect(agent.loop.status):eq("error")
        expect(agent.loop.last_error):eq("cancelled")
    end)

    it("is idempotent on already-done loop", function()
        local agent = helpers.build_agent()
        agent.loop.status = "done"
        agent:cancel()
        expect(agent.loop.status):eq("done")
    end)
end)

describe("AgentLoop: hooks", function()
    it("invokes on_message with index and kind", function()
        local seen
        local agent = helpers.build_agent({
            hooks = { on_message = function(p) seen = p end },
        })
        agent:add_message({ role = "user", content = "hi" })
        expect(seen.index):eq(1)
        expect(seen.kind):eq(Loop.MK_USER_TEXT)
    end)

    it("isolates hook crashes with pcall", function()
        local agent = helpers.build_agent({
            hooks = { on_message = function() error("hook bug") end },
        })
        expect(function()
            agent:add_message({ role = "user", content = "hi" })
        end):does_not_throw()
    end)
end)
