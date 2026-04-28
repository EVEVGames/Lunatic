-- spec/skills_spec.lua
-- Tests for the lazy-skill subsystem: catalog listing, on-demand loading
-- via the load_skill built-in tool, and Lunatic facade methods.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local L       = require("lunatic")

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

describe("Skills: facade methods", function()
    local agent
    before_each(function() agent = helpers.build_agent() end)

    it("set_available_skills replaces catalog", function()
        agent:set_available_skills({
            { name = "git", description = "git tips" },
            { name = "docker", description = "docker basics" },
        })
        local cat = agent:list_available_skills()
        expect(#cat):eq(2)
        expect(cat[1].name):eq("git")
        expect(cat[2].name):eq("docker")
    end)

    it("add_available_skill adds and dedups by name", function()
        agent:add_available_skill({ name = "x", description = "first" })
        agent:add_available_skill({ name = "x", description = "second" })
        agent:add_available_skill({ name = "y", description = "y" })
        local cat = agent:list_available_skills()
        expect(#cat):eq(2)
        local x_desc
        for _, s in ipairs(cat) do
            if s.name == "x" then x_desc = s.description end
        end
        expect(x_desc):eq("second")
    end)

    it("add_skill marks a skill as loaded", function()
        agent:add_skill("foo")
        expect(agent:list_loaded_skills()[1]):eq("foo")
    end)

    it("remove_skill drops from loaded list", function()
        agent:add_skill("a"); agent:add_skill("b")
        expect(agent:remove_skill("a")):truthy()
        local loaded = agent:list_loaded_skills()
        expect(#loaded):eq(1)
        expect(loaded[1]):eq("b")
    end)

    it("write_skill creates a flat-layout file", function()
        agent:write_skill("git", "# git body")
        expect(agent:has_skill("git")):truthy()
        expect(agent:read_skill("git")):eq("# git body")
    end)
end)

describe("Skills: system prompt content", function()
    it("catalog appears with description, body does not", function()
        local agent = helpers.build_agent()
        agent:write_skill("git", "FULL_SKILL_BODY")
        agent:set_available_skills({
            { name = "git", description = "Git workflow tips" },
        })
        local sys = agent.context:build_system_prompt()
        expect(sys):contains("Available skills")
        expect(sys):contains("Git workflow tips")
        -- body must NOT appear before load
        expect(sys:find("FULL_SKILL_BODY", 1, true)):nil_()
    end)

    it("body appears after add_skill loads the body", function()
        local agent = helpers.build_agent()
        agent:write_skill("git", "FULL_SKILL_BODY")
        agent:set_available_skills({
            { name = "git", description = "Git workflow tips" },
        })
        agent:add_skill("git")
        local sys = agent.context:build_system_prompt()
        expect(sys):contains("Loaded skills")
        expect(sys):contains("FULL_SKILL_BODY")
    end)
end)

describe("Skills: load_skill built-in tool", function()
    it("registers when builtin_tools = true", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        expect(agent:has_tool("load_skill")):truthy()
    end)

    it("does not register when enable_load_skill = false", function()
        local agent = helpers.build_agent({
            builtin_tools = true,
            enable_load_skill = false,
        })
        expect(agent:has_tool("load_skill")):falsy()
    end)

    it("does not register when builtin_tools = false (skill remains unset)", function()
        local agent = helpers.build_agent({ builtin_tools = false })
        expect(agent:has_tool("load_skill")):falsy()
    end)

    it("loading marks the skill as loaded and returns body", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        agent:write_skill("docker", "FULL_DOCKER_BODY")
        local result, err = agent.tools:dispatch("load_skill",
            { name = "docker" },
            { fs = agent._config.fs, json = agent._config.json,
              memory = agent.memory, agent = agent })
        expect(err):nil_()
        expect(result):contains("FULL_DOCKER_BODY")
        expect(agent:list_loaded_skills()[1]):eq("docker")
    end)

    it("rejects load of unknown skill", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        local result, err = agent.tools:dispatch("load_skill",
            { name = "ghost" },
            { fs = agent._config.fs, json = agent._config.json,
              memory = agent.memory, agent = agent })
        expect(result):nil_()
        expect(err):contains("not found")
    end)

    it("rejects empty skill body", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        agent:write_skill("empty", "")
        local result, err = agent.tools:dispatch("load_skill",
            { name = "empty" },
            { fs = agent._config.fs, json = agent._config.json,
              memory = agent.memory, agent = agent })
        expect(result):nil_()
        expect(err):contains("empty")
    end)

    it("rejects missing name argument", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        local result, err = agent.tools:dispatch("load_skill", {},
            { fs = agent._config.fs, json = agent._config.json,
              memory = agent.memory, agent = agent })
        expect(result):nil_()
        expect(err):contains("name")
    end)
end)

describe("Skills: end-to-end via run()", function()
    it("LLM calling load_skill makes the body show up next iteration", function()
        local agent = helpers.build_agent({ builtin_tools = true })
        agent:write_skill("kit", "BODY_OF_KIT")
        agent:set_available_skills({
            { name = "kit", description = "the kit skill" },
        })

        -- Provider script: 1) call load_skill, 2) acknowledge.
        local turn = 0
        local sys_at_turn2
        agent.provider.chat = function(self, req)
            turn = turn + 1
            if turn == 1 then
                return {
                    content = nil,
                    tool_calls = {
                        { id = "tc1", name = "load_skill",
                          arguments = { name = "kit" } },
                    },
                    finish = "tool_calls", raw = {},
                }, nil
            end
            -- Capture the system prompt of the second LLM call so we can
            -- verify the body has been spliced in.
            for _, m in ipairs(req.messages) do
                if m.role == "system" and type(m.content) == "string"
                    and m.content:find("BODY_OF_KIT", 1, true) then
                    sys_at_turn2 = true
                end
            end
            return { content = "thanks", finish = "stop", raw = {} }, nil
        end

        local final, err = agent:run("can you load kit?")
        expect(err):nil_()
        expect(final.content):eq("thanks")
        expect(sys_at_turn2):truthy()
        expect(agent:list_loaded_skills()[1]):eq("kit")
    end)
end)
