-- spec/memory_spec.lua
-- Tests for lunatic.memory MemoryStore.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local Memory  = require("lunatic.memory")

local describe, it, expect = t.describe, t.it, t.expect
local before_each = t.before_each

local store
local fs
local workspace = "/tmp/spec-mem/"

describe("Memory: construction", function()
    it("returns a store object", function()
        local s = Memory.new({ fs = helpers.make_memory_fs(),
                                json = helpers.fake_json,
                                workspace = workspace })
        expect(type(s)):eq("table")
        expect(type(s.read_bootstrap)):eq("function")
    end)

    it("uses default workspace when not given", function()
        local s = Memory.new({ fs = helpers.make_memory_fs(),
                                json = helpers.fake_json })
        expect(s.workspace):not_nil()
    end)
end)

describe("Memory: path joining", function()
    it("joins workspace with file name using slash", function()
        local s = Memory.new({ fs = helpers.make_memory_fs(),
                                json = helpers.fake_json, workspace = "/foo/" })
        expect(s:path("X.md")):eq("/foo/X.md")
    end)

    it("does not double-slash", function()
        local s = Memory.new({ fs = helpers.make_memory_fs(),
                                json = helpers.fake_json, workspace = "/foo" })
        expect(s:path("X.md")):eq("/foo/X.md")
    end)

    it("supports backslash workspace (windows-like)", function()
        local s = Memory.new({ fs = helpers.make_memory_fs(),
                                json = helpers.fake_json, workspace = "C:\\proj" })
        expect(s:path("X.md")):matches("[/\\]X%.md$")
    end)
end)

describe("Memory: bootstrap files", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("returns empty when no bootstrap files exist", function()
        expect(store:read_bootstrap()):eq("")
    end)

    it("concatenates all known files when present", function()
        fs.set(workspace .. "AGENTS.md", "# agent rules")
        fs.set(workspace .. "SOUL.md", "# personality")
        fs.set(workspace .. "USER.md", "# about user")
        fs.set(workspace .. "TOOLS.md", "# tool docs")
        local boot = store:read_bootstrap()
        expect(boot):contains("agent rules")
        expect(boot):contains("personality")
        expect(boot):contains("about user")
        expect(boot):contains("tool docs")
    end)

    it("skips files that are missing", function()
        fs.set(workspace .. "AGENTS.md", "# only this one")
        local boot = store:read_bootstrap()
        expect(boot):contains("only this one")
        expect(boot):contains("AGENTS.md")
    end)
end)

describe("Memory: facts (MEMORY.md)", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("read_facts returns empty when missing", function()
        expect(store:read_facts()):eq("")
    end)

    it("write_facts then read_facts round-trips", function()
        local ok = store:write_facts("body")
        expect(ok):truthy()
        expect(store:read_facts()):eq("body")
    end)

    it("append_fact prefixes timestamp and writes a bullet", function()
        store:append_fact("we use UTC")
        local content = store:read_facts()
        expect(content):contains("we use UTC")
        expect(content):matches("%[%d%d%d%d%-")
        expect(content):matches("^\n%- ")
    end)

    it("append_fact rejects empty string", function()
        local ok, err = store:append_fact("")
        expect(ok):nil_()
        expect(err):not_nil()
    end)

    it("append_fact rejects non-string", function()
        local ok, err = store:append_fact(42)
        expect(ok):nil_()
    end)

    it("multiple appends preserve order", function()
        store:append_fact("first")
        store:append_fact("second")
        local content = store:read_facts()
        local p1 = content:find("first", 1, true)
        local p2 = content:find("second", 1, true)
        expect(p1):not_nil()
        expect(p2):not_nil()
        expect(p2 > p1):truthy()
    end)
end)

describe("Memory: history (HISTORY.md)", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("read_history empty when missing", function()
        expect(store:read_history()):eq("")
    end)

    it("appends timestamped lines", function()
        store:append_history("event one")
        store:append_history("event two")
        local content = store:read_history()
        expect(content):contains("event one")
        expect(content):contains("event two")
    end)

    it("append_history rejects empty input", function()
        local ok, err = store:append_history("")
        expect(ok):nil_()
    end)
end)

describe("Memory: daily journal", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("uses today's date by default", function()
        store:append_journal("did a thing")
        -- The file should have been created with today's date.
        local files = fs.list()
        local matched
        for _, p in ipairs(files) do
            if p:match("%d%d%d%d%-%d%d%-%d%d%.md") then matched = p end
        end
        expect(matched):not_nil()
    end)

    it("respects explicit date argument", function()
        store:append_journal("retro", "1999-12-31")
        expect(fs.exists(workspace .. "1999-12-31.md")):truthy()
    end)

    it("read_journal returns nil for missing date", function()
        local content, err = store:read_journal("1900-01-01")
        expect(content):nil_()
    end)
end)

describe("Memory: sessions", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("save then load round-trips", function()
        local ok = store:save_session("s1", { x = 1, list = { "a", "b" } })
        expect(ok):truthy()
        local data, err = store:load_session("s1")
        expect(err):nil_()
        expect(data.x):eq(1)
        expect(data.list[2]):eq("b")
    end)

    it("session file is at workspace root", function()
        store:save_session("abc", { hello = true })
        expect(fs.exists(workspace .. "abc.json")):truthy()
    end)

    it("load_session returns err for missing id", function()
        local d, err = store:load_session("ghost")
        expect(d):nil_()
        expect(err):not_nil()
    end)
end)

describe("Memory: skills", function()
    before_each(function()
        fs = helpers.make_memory_fs()
        store = Memory.new({ fs = fs, json = helpers.fake_json, workspace = workspace })
    end)

    it("read_skill empty when missing", function()
        expect(store:read_skill("git")):eq("")
    end)

    it("write_skill creates flat file", function()
        store:write_skill("git", "# git skill")
        expect(fs.exists(workspace .. "SKILL.git.md")):truthy()
        expect(store:read_skill("git")):eq("# git skill")
    end)

    it("has_skill reports true after write", function()
        expect(store:has_skill("docker")):falsy()
        store:write_skill("docker", "X")
        expect(store:has_skill("docker")):truthy()
    end)

    it("read_skills concatenates with headers", function()
        store:write_skill("a", "first body")
        store:write_skill("b", "second body")
        local out = store:read_skills({ "a", "b", "missing" })
        expect(out):contains("# Skill: a")
        expect(out):contains("first body")
        expect(out):contains("# Skill: b")
        expect(out):contains("second body")
    end)

    it("read_skills returns empty for empty list", function()
        expect(store:read_skills({})):eq("")
        expect(store:read_skills(nil)):eq("")
    end)

    it("falls back to folded layout when present", function()
        -- Manually populate the folded path; we don't create dirs here
        -- but the fake_fs accepts any path.
        fs.set(workspace .. "skills/python/SKILL.md", "py body")
        expect(store:read_skill("python")):eq("py body")
        expect(store:has_skill("python")):truthy()
    end)
end)

describe("Memory: missing fs", function()
    it("read_md returns err when fs.open absent", function()
        local s = Memory.new({ fs = {}, json = helpers.fake_json, workspace = "/x/" })
        local v, err = s:read_md("foo.md")
        expect(v):nil_()
        expect(err):not_nil()
    end)

    it("write_md returns err when fs.open absent", function()
        local s = Memory.new({ fs = {}, json = helpers.fake_json, workspace = "/x/" })
        local v, err = s:write_md("foo.md", "x")
        expect(v):nil_()
        expect(err):not_nil()
    end)
end)
