-- spec/context_spec.lua
-- Tests for lunatic.context ContextBuilder.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local Context = require("lunatic.context")
local Memory  = require("lunatic.memory")

local describe, it, expect = t.describe, t.it, t.expect

local function build(memory_overrides, ctx_overrides)
    local fs = helpers.make_memory_fs()
    if memory_overrides and memory_overrides.files then
        for path, content in pairs(memory_overrides.files) do
            fs.set(path, content)
        end
    end
    local memory = Memory.new({ fs = fs, json = helpers.fake_json,
                                 workspace = "/ws/" })
    local cfg = { memory = memory, agent_id = "main" }
    if ctx_overrides then
        for k, v in pairs(ctx_overrides) do cfg[k] = v end
    end
    return Context.new(cfg), fs
end

describe("Context: construction", function()
    it("returns an instance", function()
        local ctx = Context.new({})
        expect(type(ctx.build_system_prompt)):eq("function")
    end)

    it("uses default agent_id when not given", function()
        local ctx = Context.new({})
        expect(ctx.agent_id):eq("main")
    end)
end)

describe("Context: system prompt assembly", function()
    it("includes runtime metadata block", function()
        local ctx = build()
        local sys = ctx:build_system_prompt()
        expect(sys):contains("Runtime Context")
        expect(sys):contains("agent_id: main")
        expect(sys):matches("timestamp:%s+%d%d%d%d%-")
    end)

    it("includes bootstrap content when AGENTS.md present", function()
        local ctx = build({ files = { ["/ws/AGENTS.md"] = "be a test agent" } })
        expect(ctx:build_system_prompt()):contains("be a test agent")
    end)

    it("includes facts under MEMORY.md header", function()
        local ctx = build({ files = { ["/ws/MEMORY.md"] = "fact 1\nfact 2" } })
        local sys = ctx:build_system_prompt()
        expect(sys):contains("MEMORY.md (long-term facts)")
        expect(sys):contains("fact 1")
    end)

    it("appends extra_system text", function()
        local ctx = build(nil, { extra_system = "EXTRA TEXT BLOCK" })
        expect(ctx:build_system_prompt()):contains("EXTRA TEXT BLOCK")
    end)

    it("tail-truncates long history", function()
        local lines = {}
        for i = 1, 200 do lines[i] = "line " .. i end
        local hist = table.concat(lines, "\n") .. "\n"
        local ctx = build(
            { files = { ["/ws/HISTORY.md"] = hist } },
            { history_tail_lines = 5 }
        )
        local sys = ctx:build_system_prompt()
        -- only the last 5 lines should appear
        expect(sys):contains("line 200")
        expect(sys):contains("line 196")
        expect(sys:find("line 100", 1, true)):nil_()
    end)
end)

describe("Context: skills integration (lazy)", function()
    it("does not add skills section when no catalog or loaded set", function()
        local ctx = build()
        local sys = ctx:build_system_prompt()
        expect(sys:find("Available skills", 1, true)):nil_()
        expect(sys:find("Loaded skills", 1, true)):nil_()
    end)

    it("lists available skills (catalog only, no body)", function()
        local ctx = build({ files = {
            ["/ws/SKILL.git.md"] = "this body should NOT appear yet",
        } }, { available_skills = {
            { name = "git", description = "Git workflow tips" },
        } })
        local sys = ctx:build_system_prompt()
        expect(sys):contains("Available skills")
        expect(sys):contains("git")
        expect(sys):contains("Git workflow tips")
        -- body must remain hidden until loaded
        expect(sys:find("body should NOT appear", 1, true)):nil_()
    end)

    it("injects body once a skill is loaded via add_skill", function()
        local ctx = build({ files = {
            ["/ws/SKILL.git.md"] = "FULL_BODY_TEXT here",
        } }, { available_skills = {
            { name = "git", description = "Git workflow tips" },
        } })
        ctx:add_skill("git")
        local sys = ctx:build_system_prompt()
        expect(sys):contains("Loaded skills")
        expect(sys):contains("FULL_BODY_TEXT here")
    end)

    it("set_available_skills replaces the catalog", function()
        local ctx = build()
        ctx:set_available_skills({
            { name = "a", description = "A" },
        })
        ctx:set_available_skills({
            { name = "b", description = "B" },
        })
        local sys = ctx:build_system_prompt()
        expect(sys):contains("- **b**")
        expect(sys:find("- **a**", 1, true)):nil_()
    end)

    it("add_available_skill appends and dedups by name", function()
        local ctx = build()
        ctx:add_available_skill({ name = "x", description = "first" })
        ctx:add_available_skill({ name = "x", description = "updated" })
        ctx:add_available_skill({ name = "y", description = "y" })
        expect(#ctx.available_skills):eq(2)
        local sys = ctx:build_system_prompt()
        expect(sys):contains("updated")
        expect(sys:find("first", 1, true)):nil_()
    end)

    it("add_skill is idempotent", function()
        local ctx = build()
        ctx:add_skill("x")
        ctx:add_skill("x")
        ctx:add_skill("y")
        expect(#ctx.loaded_skills):eq(2)
    end)

    it("remove_skill drops a loaded skill", function()
        local ctx = build()
        ctx:set_skills({ "a", "b", "c" })
        expect(ctx:remove_skill("b")):truthy()
        expect(#ctx.loaded_skills):eq(2)
        expect(ctx:remove_skill("missing")):falsy()
    end)
end)

describe("Context: build_messages", function()
    it("prepends system message before history", function()
        local ctx = build()
        local msgs = ctx:build_messages({
            { role = "user", content = "hi" },
            { role = "assistant", content = "hello" },
        })
        expect(#msgs):eq(3)
        expect(msgs[1].role):eq("system")
        expect(msgs[2].role):eq("user")
        expect(msgs[3].role):eq("assistant")
    end)

    it("does not mutate the history input", function()
        local ctx = build()
        local hist = { { role = "user", content = "hi" } }
        ctx:build_messages(hist)
        expect(#hist):eq(1)
    end)

    it("handles nil history gracefully", function()
        local ctx = build()
        local msgs = ctx:build_messages(nil)
        expect(#msgs):eq(1)
        expect(msgs[1].role):eq("system")
    end)
end)
