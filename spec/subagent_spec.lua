-- spec/subagent_spec.lua
-- Tests for subagent spawning, cooperative scheduling, and integration with
-- the main loop's messages() view.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local L       = require("lunatic")
local Loop    = require("lunatic.loop")

local describe, it, expect = t.describe, t.it, t.expect
local before_each = t.before_each

do
    local pm = require("lunatic.provider")
    if not pm.has("scripted") then
        pm.register("scripted", function()
            return { name = "scripted",
                chat = function() return { content = "?", finish = "stop", raw = {} }, nil end }
        end)
    end
end

describe("Subagent: spawn and run", function()
    it("creates an idle handle by default", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        expect(h:status()):eq("idle")
        expect(h.task):eq("x")
    end)

    it("runs a subagent to completion via :run()", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "describe" })
        h:next()  -- boot the coroutine, instantiates h.lunatic
        helpers.script_provider(h.lunatic,
            { { content = "subagent answer", finish = "stop", raw = {} } })
        local res, err = h:run()
        expect(err):nil_()
        expect(res):eq("subagent answer")
        expect(h:is_ready()):truthy()
    end)

    it("supports cooperative :next() until is_ready()", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        h:next()  -- boot
        helpers.script_provider(h.lunatic,
            { { content = "ok", finish = "stop", raw = {} } })
        local steps = 0
        while not h:is_ready() and steps < 50 do
            h:next()
            steps = steps + 1
        end
        expect(h:is_ready()):truthy()
        expect(steps):gt(0)
    end)

    it("only :next() exists — no tick alias", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        expect(type(h["next"])):eq("function")
        expect(h.tick):nil_()
    end)
end)

describe("Subagent: cancel", function()
    it("transitions to error 'cancelled'", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        h:next()
        h:cancel()
        expect(h:status()):eq("error")
        local _, err = h:result()
        expect(err):eq("cancelled")
    end)

    it("Lunatic:cancel_subagent works on the manager", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        h:next()
        expect(agent:cancel_subagent(h.id)):truthy()
        expect(h:status()):eq("error")
    end)

    it("returns false when cancelling unknown id", function()
        local agent = helpers.build_agent()
        expect(agent:cancel_subagent("ghost")):falsy()
    end)

    it("kill_subagent alias has been removed", function()
        local agent = helpers.build_agent()
        expect(agent.kill_subagent):nil_()
    end)
end)

describe("Subagent: parent_call_id correlation", function()
    it("links subagent handle to the spawning tool_call", function()
        local agent = helpers.build_agent()
        agent:register_tool({ name = "p",
            parameters = { type = "object", properties = {} } },
            function() return "x" end)
        -- Drive the loop directly: simulate tool_call for spawn_subagent.
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "tc-correlated", name = "spawn_subagent",
                  arguments = { task = "do thing" } } },
              finish = "tool_calls", raw = {} },
            { content = "main done", finish = "stop", raw = {} },
        })

        -- Subagents get their own scripted provider via build_subagent_loop's
        -- inheritance — we can't override it before the spawn happens, so we
        -- patch it as soon as a subagent appears. Cheat: register a hook.
        local spawned
        agent.hooks = agent.hooks or {}
        agent.hooks.on_subagent_spawn = function(p)
            spawned = agent:get_subagent(p.id)
            if spawned and spawned.lunatic == nil then
                -- The handle isn't booted yet; we'll patch its provider after
                -- the first :next() inside run_one which initialises lunatic.
                local original = spawned.next
                spawned.next = function(self)
                    if self.lunatic and self.lunatic.provider and
                        not self._patched then
                        self.lunatic.provider.chat = function()
                            return { content = "sub did it",
                                finish = "stop", raw = {} }, nil
                        end
                        self._patched = true
                    end
                    return original(self)
                end
            end
        end

        agent:run("go please")
        expect(spawned):not_nil()
        expect(spawned.parent_call_id):eq("tc-correlated")
        local found = agent.subagents:find_by_call_id("tc-correlated")
        expect(found):not_nil()
        expect(found.id):eq(spawned.id)
    end)
end)

describe("Subagent: messages() integration", function()
    it("subagent transcript embedded in main messages output", function()
        local agent = helpers.build_agent()
        helpers.script_provider(agent, {
            { content = nil,
              tool_calls = { { id = "tc-trace", name = "spawn_subagent",
                  arguments = { task = "small task" } } },
              finish = "tool_calls", raw = {} },
            { content = "main wrap-up", finish = "stop", raw = {} },
        })
        agent.hooks = agent.hooks or {}
        agent.hooks.on_subagent_spawn = function(p)
            local sub = agent:get_subagent(p.id)
            local origNext = sub.next
            sub.next = function(self)
                if self.lunatic and not self._patched then
                    self.lunatic.provider.chat = function()
                        return { content = "subagent reply",
                            finish = "stop", raw = {} }, nil
                    end
                    self._patched = true
                end
                return origNext(self)
            end
        end

        agent:run("go")
        local msgs = agent:messages()
        -- Find the subagent_call entry and verify its transcript field.
        local sub_call_entry
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_call" or m.kind == "tool_call" then
                if m.tool_calls and m.tool_calls[1] and
                    m.tool_calls[1].name == "spawn_subagent" then
                    sub_call_entry = m
                end
            end
        end
        -- Subagent transcript should be on the result entry that holds
        -- tool_call_id "tc-trace".
        local sub_result_entry
        for _, m in ipairs(msgs) do
            if m.kind == "subagent_result" and m.tool_call_id == "tc-trace" then
                sub_result_entry = m
            end
        end
        expect(sub_result_entry):not_nil()
        expect(sub_result_entry.subagent):not_nil()
        expect(sub_result_entry.subagent.transcript):not_nil()
        expect(#sub_result_entry.subagent.transcript):gt(0)
    end)

    it("Subagent:messages returns a list", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x" })
        h:next()
        helpers.script_provider(h.lunatic,
            { { content = "hi", finish = "stop", raw = {} } })
        h:run()
        local msgs = h:messages()
        expect(type(msgs)):eq("table")
    end)
end)

describe("SubagentManager: pool", function()
    it("run_pool drives multiple subagents in round-robin", function()
        local agent = helpers.build_agent()
        local h1 = agent:spawn_subagent({ task = "one" })
        local h2 = agent:spawn_subagent({ task = "two" })

        h1:next(); h2:next()
        helpers.script_provider(h1.lunatic,
            { { content = "first", finish = "stop", raw = {} } })
        helpers.script_provider(h2.lunatic,
            { { content = "second", finish = "stop", raw = {} } })

        -- Direct call (not in coroutine), pcall-guarded yields are no-ops.
        local results = agent.subagents:run_pool({ h1, h2 })
        expect(#results):eq(2)
        local got = {}
        for _, r in ipairs(results) do got[r.result] = true end
        expect(got["first"]):truthy()
        expect(got["second"]):truthy()
    end)
end)

describe("Subagent: list", function()
    it("enumerates spawned subagents with their parent_call_id", function()
        local agent = helpers.build_agent()
        local h = agent:spawn_subagent({ task = "x", parent_call_id = "p1" })
        local list = agent:list_subagents()
        local found
        for _, s in ipairs(list) do
            if s.id == h.id then found = s end
        end
        expect(found):not_nil()
        expect(found.parent_call_id):eq("p1")
        expect(found.task):eq("x")
    end)
end)
