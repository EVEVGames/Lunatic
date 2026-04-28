-- spec/yield_safety_spec.lua
-- Regression tests for the "yield across C-call boundary" / "yield from
-- outside a coroutine" crashes that surfaced on Windows builds of LuaJIT
-- and Lua 5.2.
--
-- The original safe_yield helper used coroutine.isyieldable() as a heuristic
-- to decide whether to yield. Its behaviour differs subtly between Lua
-- versions and platforms (especially LuaJIT on Windows, where the function
-- existed but did not always reflect the real running state). The fix moves
-- to a single source of truth: the parent loop's _inside_coroutine flag,
-- which is explicitly set by Runner / Subagent before resuming.
--
-- These tests pin that contract.

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

-- Helper: install a hook that patches each spawned subagent's provider on
-- its first :next() so we don't have to script the subagent's calls
-- through the full chain.
local function patch_subagents(agent, reply)
    agent.hooks = agent.hooks or {}
    agent.hooks.on_subagent_spawn = function(p)
        local sub = agent:get_subagent(p.id)
        local origNext = sub["next"]
        sub["next"] = function(self)
            if self.lunatic and not self._patched then
                local r = reply
                if type(reply) == "function" then r = reply(self) end
                self.lunatic.provider.chat = function()
                    return { content = r, finish = "stop", raw = {} }, nil
                end
                self._patched = true
            end
            return origNext(self)
        end
    end
end

describe("Yield safety: synchronous run with single subagent", function()
    it("does not crash when agent:run is called outside a coroutine", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "spawn_subagent",
                  arguments = { task = "do work" } } },
              finish = "tool_calls", raw = {} },
            { content = "main done", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "sub-result")
        expect(function() agent:run("delegate this") end):does_not_throw()
    end)

    it("synchronous run produces correct subagent_result message", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "spawn_subagent",
                  arguments = { task = "tt" } } },
              finish = "tool_calls", raw = {} },
            { content = "fin", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "the answer")
        local final = agent:run("go")
        expect(final.content):eq("fin")
        local msgs = agent:messages()
        local sub_result
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_result" then sub_result = m end
        end
        expect(sub_result):not_nil()
        expect(sub_result.content):contains("the answer")
    end)
end)

describe("Yield safety: synchronous run with multiple subagents (run_pool)", function()
    it("does not crash with 2 spawn_subagent calls in the same turn", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = {
                  { id = "ca", name = "spawn_subagent",
                    arguments = { task = "a" } },
                  { id = "cb", name = "spawn_subagent",
                    arguments = { task = "b" } },
              },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        local n = 0
        patch_subagents(agent, function()
            n = n + 1; return "sub#" .. n
        end)
        expect(function() agent:run("two please") end):does_not_throw()
        expect(agent.loop.status):eq("done")
    end)

    it("emits one tool_result per subagent in original order", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = {
                  { id = "ca", name = "spawn_subagent",
                    arguments = { task = "a" } },
                  { id = "cb", name = "spawn_subagent",
                    arguments = { task = "b" } },
                  { id = "cc", name = "spawn_subagent",
                    arguments = { task = "c" } },
              },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        patch_subagents(agent, function(sub) return "sub:" .. sub.task end)
        agent:run("three")
        local msgs = agent:messages()
        local order = {}
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_result" then
                order[#order + 1] = m.tool_call_id
            end
        end
        expect(#order):eq(3)
        expect(order[1]):eq("ca")
        expect(order[2]):eq("cb")
        expect(order[3]):eq("cc")
    end)

    it("one bad arg does not block the others (mixed success / failure)", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = {
                  { id = "ca", name = "spawn_subagent",
                    arguments = { task = "" } }, -- empty -> sentinel error
                  { id = "cb", name = "spawn_subagent",
                    arguments = { task = "ok" } },
              },
              finish = "tool_calls", raw = {} },
            { content = "fin", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "ok-result")
        agent:run("mixed")
        local msgs = agent:messages()
        local results = {}
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_result" then
                results[m.tool_call_id] = m.content
            end
        end
        expect(results["ca"]):contains("failed")
        expect(results["cb"]):contains("ok-result")
    end)

    it("mixes spawn_subagent with regular tool calls in the same turn", function()
        local agent = helpers.build_agent()
        agent:register_tool("ping", function() return "pong" end)
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = {
                  { id = "tc1", name = "ping", arguments = {} },
                  { id = "tc2", name = "spawn_subagent",
                    arguments = { task = "x" } },
                  { id = "tc3", name = "spawn_subagent",
                    arguments = { task = "y" } },
                  { id = "tc4", name = "ping", arguments = {} },
              },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "subok")
        expect(function() agent:run("mix") end):does_not_throw()
        local msgs = agent:messages()
        local kinds = {}
        for _, m in ipairs(msgs) do kinds[m.kind] = (kinds[m.kind] or 0) + 1 end
        -- 2 tool_results from ping, 2 subagent_results
        expect(kinds["tool_result"]):eq(2)
        expect(kinds["subagent_result"]):eq(2)
    end)
end)

describe("Yield safety: Runner cooperative path still yields", function()
    it("Runner driving a subagent records the yield stages", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "c1", name = "spawn_subagent",
                  arguments = { task = "x" } } },
              finish = "tool_calls", raw = {} },
            { content = "done", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "sub-ok")

        local r = L.Runner.new(agent)
        r:submit("delegate")
        local stages = {}
        while not r:is_ready() do
            r:next()
            local y = r:last_yield()
            if y then stages[y.stage] = (stages[y.stage] or 0) + 1 end
        end
        expect(r:status()):eq("done")
        expect(stages["before_tool"]):not_nil()
        expect(stages["after_tool"]):not_nil()
        -- The subagent_progress yield only fires when the parent IS in a
        -- coroutine — that's the whole point of the fix. With Runner driving,
        -- it must appear at least once.
        expect(stages["subagent_progress"]):not_nil()
    end)
end)

describe("Yield safety: SubagentManager:run_pool (manual API)", function()
    it("is safe to call without any coroutine in scope", function()
        local agent = helpers.build_agent()
        local h1 = agent:spawn_subagent({ task = "one" })
        local h2 = agent:spawn_subagent({ task = "two" })
        h1:next(); h2:next()
        helpers.script_provider(h1.lunatic,
            { { content = "first", finish = "stop", raw = {} } })
        helpers.script_provider(h2.lunatic,
            { { content = "second", finish = "stop", raw = {} } })
        expect(function()
            agent.subagents:run_pool({ h1, h2 })
        end):does_not_throw()
        expect(h1:result()):eq("first")
        expect(h2:result()):eq("second")
    end)

    it("is safe inside a coroutine driven by Runner", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = {
                  { id = "ca", name = "spawn_subagent",
                    arguments = { task = "a" } },
                  { id = "cb", name = "spawn_subagent",
                    arguments = { task = "b" } },
              },
              finish = "tool_calls", raw = {} },
            { content = "fin", finish = "stop", raw = {} },
        })
        patch_subagents(agent, "okok")
        local r = L.Runner.new(agent)
        r:submit("two")
        expect(function()
            while not r:is_ready() do r:next() end
        end):does_not_throw()
        expect(r:status()):eq("done")
    end)
end)
