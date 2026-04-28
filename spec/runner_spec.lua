-- spec/runner_spec.lua
-- Tests for the cooperative Runner.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local L       = require("lunatic")

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

describe("Runner: construction", function()
    it("requires a Lunatic instance", function()
        expect(function() L.Runner.new() end):throws()
        expect(function() L.Runner.new(nil) end):throws()
    end)

    it("starts in idle status", function()
        local agent = helpers.build_agent()
        local r = L.Runner.new(agent)
        expect(r:status()):eq("idle")
        expect(r:is_ready()):falsy()
    end)
end)

describe("Runner: simple completion", function()
    it("submit + next loop reaches done", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent,
            { { content = "answer here", finish = "stop", raw = {} } })
        local r = L.Runner.new(agent)
        r:submit("hi")
        local steps = 0
        while not r:is_ready() and steps < 50 do
            r:next()
            steps = steps + 1
        end
        expect(r:is_ready()):truthy()
        expect(r:status()):eq("done")
        local res, err = r:result()
        expect(err):nil_()
        expect(res):eq("answer here")
        expect(steps):gt(0)
    end)

    it("returns running status while in flight", function()
        local agent = helpers.build_agent()
        agent:register_tool({ name = "p",
            parameters = { type = "object", properties = {} } },
            function() return "x" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "1", name = "p", arguments = {} } },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        local r = L.Runner.new(agent)
        r:submit("go")
        r:next()  -- first yield
        expect(r:status()):eq("running")
    end)
end)

describe("Runner: cancel", function()
    it("marks runner as cancelled", function()
        local agent = helpers.build_agent()
        local r = L.Runner.new(agent)
        r:submit("x")
        r:cancel()
        expect(r:status()):eq("cancelled")
        expect(r:is_ready()):truthy()
        local _, err = r:result()
        expect(err):eq("cancelled")
    end)

    it("is harmless when called before submit", function()
        local agent = helpers.build_agent()
        local r = L.Runner.new(agent)
        r:cancel()  -- still idle
        expect(r:status()):eq("idle")
    end)
end)

describe("Runner: error path", function()
    it("captures provider error in result", function()
        local agent = helpers.build_agent()
        agent.provider.chat = function()
            return nil, "network down"
        end
        local r = L.Runner.new(agent)
        r:submit("hi")
        while not r:is_ready() do r:next() end
        expect(r:status()):eq("error")
        local _, err = r:result()
        expect(err):contains("network down")
    end)

    it("captures crash inside loop coroutine", function()
        local agent = helpers.build_agent()
        agent.provider.chat = function() error("oops") end
        local r = L.Runner.new(agent)
        r:submit("hi")
        while not r:is_ready() do r:next() end
        expect(r:status()):eq("error")
        local _, err = r:result()
        expect(err):not_nil()
    end)
end)

describe("Runner: yield introspection", function()
    it("last_yield returns the most recent stage payload", function()
        local agent = helpers.build_agent()
        agent:register_tool({ name = "z",
            parameters = { type = "object", properties = {} } },
            function() return "ok" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "1", name = "z", arguments = {} } },
              finish = "tool_calls", raw = {} },
            { content = "ok", finish = "stop", raw = {} },
        })
        local r = L.Runner.new(agent)
        r:submit("hi")
        r:next()  -- before_llm
        local y = r:last_yield()
        expect(y):not_nil()
        expect(y.stage):is_a("string")
    end)
end)

describe("Runner: re-submit", function()
    it("resets loop and runs a new task", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = "first", finish = "stop", raw = {} },
            { content = "second", finish = "stop", raw = {} },
        })
        local r = L.Runner.new(agent)
        r:submit("a")
        while not r:is_ready() do r:next() end
        local first = r:result()
        expect(first):eq("first")

        r:submit("b")
        while not r:is_ready() do r:next() end
        local second = r:result()
        expect(second):eq("second")
        -- History should reflect the latest task only (after reset).
        local user_msgs = 0
        for _, m in ipairs(agent.loop.history) do
            if m.role == "user" then user_msgs = user_msgs + 1 end
        end
        expect(user_msgs):eq(1)
    end)
end)
