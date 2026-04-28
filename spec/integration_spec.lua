-- spec/integration_spec.lua
-- End-to-end integration tests covering common Lunatic workflows.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local L       = require("lunatic")
local Loop    = require("lunatic.loop")

local describe, it, expect = t.describe, t.it, t.expect

do
    local pm = require("lunatic.provider")
    if not pm.has("scripted") then
        pm.register("scripted", function()
            return { name = "scripted",
                chat = function() return { content = "?", finish = "stop", raw = {} }, nil end }
        end)
    end
end

describe("Integration: full conversation with tool calls", function()
    it("persists conversation history with kinds tagged correctly", function()
        local agent = helpers.build_agent()
        agent:register_tool("multiply", function(args)
            return tostring((args.a or 0) * (args.b or 0))
        end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "multiply",
                  arguments = { a = 6, b = 7 } } },
              finish = "tool_calls", raw = {} },
            { content = "the answer is 42", finish = "stop", raw = {} },
        })
        local final = agent:run("what is 6*7?")
        expect(final.content):eq("the answer is 42")
        local msgs = agent:messages()
        local kinds = {}
        for _, m in ipairs(msgs) do kinds[m.kind] = (kinds[m.kind] or 0) + 1 end
        expect(kinds["user_text"]):eq(1)
        expect(kinds["tool_call"]):eq(1)
        expect(kinds["tool_result"]):eq(1)
        expect(kinds["assistant_text"]):eq(1)
    end)

    it("messages() preserves tool argument structure", function()
        local agent = helpers.build_agent()
        agent:register_tool("noop", function() return "ok" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c-noop", name = "noop",
                  arguments = { x = 42, y = "z" } } },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        agent:run("go")
        local msgs = agent:messages()
        local tc_entry
        for _, m in ipairs(msgs) do
            if m.kind == "tool_call" then tc_entry = m end
        end
        expect(tc_entry):not_nil()
        expect(tc_entry.tool_calls[1].name):eq("noop")
        expect(tc_entry.tool_calls[1].id):eq("c-noop")
    end)
end)

describe("Integration: session save/load preserves kinds", function()
    it("kinds and pinned survive a round trip", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = "hi back", finish = "stop", raw = {} },
        })
        agent:run("hello")
        local idx = agent:add_message({ role = "system", content = "pinned note" },
            Loop.MK_PINNED_NOTE)
        agent.loop:pin(idx)
        agent:save_session("sess-x")

        -- Fresh agent, load session.
        local agent2 = helpers.build_agent({ workspace = agent._config.workspace,
            fs = agent._config.fs })
        agent2:load_session("sess-x")
        expect(#agent2.loop.history):eq(#agent.loop.history)
        local pinned_count = 0
        for _ in pairs(agent2.loop.pinned) do pinned_count = pinned_count + 1 end
        expect(pinned_count):eq(1)
        -- The same index should still be tagged MK_PINNED_NOTE.
        expect(agent2.loop.kinds[idx]):eq(Loop.MK_PINNED_NOTE)
    end)
end)

describe("Integration: hook order on a multi-iteration run", function()
    it("emits expected lifecycle events in order", function()
        local seq = {}
        local function rec(name)
            return function() seq[#seq + 1] = name end
        end
        local agent = helpers.build_agent({
            hooks = {
                on_iteration = rec("iter"),
                on_llm_request = rec("req"),
                on_llm_response = rec("resp"),
                on_tool_call = rec("call"),
                on_tool_result = rec("result"),
                on_done = rec("done"),
            },
        })
        agent:register_tool("p", function() return "ok" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "p", arguments = {} } },
              finish = "tool_calls", raw = {} },
            { content = "fin", finish = "stop", raw = {} },
        })
        agent:run("go")
        -- First iteration block: iter, req, resp, call, result.
        -- Second iteration: iter, req, resp, then done.
        expect(seq[1]):eq("iter")
        local saw_call = false
        local saw_done = false
        for _, ev in ipairs(seq) do
            if ev == "call" then saw_call = true end
            if ev == "done" then saw_done = true end
        end
        expect(saw_call):truthy()
        expect(saw_done):truthy()
        -- done is always last.
        expect(seq[#seq]):eq("done")
    end)
end)

describe("Integration: register_tool name-first signature in real flow", function()
    it("works through the loop without spec.name", function()
        local agent = helpers.build_agent()
        agent:register_tool("greet", function(args)
            return "hi " .. tostring(args.who)
        end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "greet",
                  arguments = { who = "Lua" } } },
              finish = "tool_calls", raw = {} },
            { content = "greeted", finish = "stop", raw = {} },
        })
        agent:run("hello")
        local msgs = agent:messages()
        local found_result
        for _, m in ipairs(msgs) do
            if m.kind == "tool_result" and m.content == "hi Lua" then
                found_result = m
            end
        end
        expect(found_result):not_nil()
    end)
end)

describe("Integration: subagent transcript embedding", function()
    it("messages() exposes the subagent transcript on the result entry", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c-sub", name = "spawn_subagent",
                  arguments = { task = "subtask" } } },
              finish = "tool_calls", raw = {} },
            { content = "main wrap", finish = "stop", raw = {} },
        })
        agent.hooks = agent.hooks or {}
        agent.hooks.on_subagent_spawn = function(p)
            local sub = agent:get_subagent(p.id)
            local origNext = sub["next"]
            sub["next"] = function(self)
                if self.lunatic and not self._patched then
                    self.lunatic.provider.chat = function()
                        return { content = "sub answer here",
                            finish = "stop", raw = {} }, nil
                    end
                    self._patched = true
                end
                return origNext(self)
            end
        end
        agent:run("delegate")
        local msgs = agent:messages()
        local sub_result
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_result" then sub_result = m end
        end
        expect(sub_result):not_nil()
        expect(sub_result.subagent):not_nil()
        expect(sub_result.subagent.task):eq("subtask")
        expect(#sub_result.subagent.transcript):gt(0)
    end)
end)

describe("Integration: Runner inside an event-loop-like driver", function()
    it("returns predictable yield stages over a tool-calling task", function()
        local agent = helpers.build_agent()
        agent:register_tool("ping", function() return "pong" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "ping", arguments = {} } },
              finish = "tool_calls", raw = {} },
            { content = "all good", finish = "stop", raw = {} },
        })
        local r = L.Runner.new(agent)
        r:submit("tick please")
        local stages_seen = {}
        while not r:is_ready() do
            r:next()
            local y = r:last_yield()
            if y then stages_seen[y.stage] = (stages_seen[y.stage] or 0) + 1 end
        end
        expect(r:status()):eq("done")
        expect(stages_seen["before_llm"]):not_nil()
        expect(stages_seen["before_tool"]):not_nil()
    end)
end)
