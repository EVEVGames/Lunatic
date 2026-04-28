-- spec/tools_spec.lua
-- Tests for lunatic.tools ToolRegistry.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local Tools   = require("lunatic.tools")

local describe, it, expect = t.describe, t.it, t.expect
local before_each = t.before_each

local reg
describe("ToolRegistry: construction", function()
    it("creates an empty registry", function()
        local r = Tools.new()
        expect(#r:list()):eq(0)
        expect(#r:names()):eq(0)
    end)
end)

describe("ToolRegistry: register signatures", function()
    before_each(function() reg = Tools.new() end)

    it("registers via (spec, handler)", function()
        local ok = reg:register({ name = "foo" }, function() return "x" end)
        expect(ok):truthy()
        expect(reg:has("foo")):truthy()
    end)

    it("registers via (name, spec, handler) overriding spec.name", function()
        local ok = reg:register("renamed", { name = "ignored" }, function() return "x" end)
        expect(ok):truthy()
        expect(reg:has("renamed")):truthy()
        expect(reg:has("ignored")):falsy()
    end)

    it("registers via (name, handler) shorthand without spec", function()
        local ok = reg:register("quick", function() return "y" end)
        expect(ok):truthy()
        expect(reg:has("quick")):truthy()
    end)

    it("rejects missing name", function()
        local ok, err = reg:register({}, function() end)
        expect(ok):nil_()
        expect(err):contains("name")
    end)

    it("rejects bad handler type", function()
        local ok, err = reg:register({ name = "x" }, 42)
        expect(ok):nil_()
        expect(err):contains("function")
    end)

    it("re-registering replaces handler in place", function()
        reg:register({ name = "x" }, function() return "first" end)
        reg:register({ name = "x" }, function() return "second" end)
        local res = reg:dispatch("x", {}, {})
        expect(res):eq("second")
    end)
end)

describe("ToolRegistry: management", function()
    before_each(function()
        reg = Tools.new()
        reg:register({ name = "a" }, function() return "A" end)
        reg:register({ name = "b" }, function() return "B" end)
    end)

    it("unregister removes an entry", function()
        expect(reg:unregister("a")):truthy()
        expect(reg:has("a")):falsy()
    end)

    it("unregister returns false for missing", function()
        expect(reg:unregister("ghost")):falsy()
    end)

    it("get returns a copy of the entry", function()
        local entry = reg:get("a")
        expect(entry.spec.name):eq("a")
        expect(type(entry.handler)):eq("function")
        expect(entry.enabled):truthy()
    end)

    it("disable hides tool from list", function()
        reg:disable("a")
        local listed = reg:list()
        local names = {}
        for _, e in ipairs(listed) do names[e["function"].name] = true end
        expect(names["a"]):falsy()
        expect(names["b"]):truthy()
    end)

    it("enable restores", function()
        reg:disable("a")
        reg:enable("a")
        local listed = reg:list()
        local names = {}
        for _, e in ipairs(listed) do names[e["function"].name] = true end
        expect(names["a"]):truthy()
    end)

    it("clear removes everything", function()
        reg:clear()
        expect(#reg:list()):eq(0)
        expect(#reg:names()):eq(0)
    end)

    it("list returns OpenAI-shaped specs", function()
        local listed = reg:list()
        expect(#listed):eq(2)
        expect(listed[1].type):eq("function")
        expect(listed[1]["function"].name):eq("a")
    end)

    it("preserves registration order", function()
        local listed = reg:list()
        expect(listed[1]["function"].name):eq("a")
        expect(listed[2]["function"].name):eq("b")
    end)
end)

describe("ToolRegistry: dispatch (function handler)", function()
    before_each(function() reg = Tools.new() end)

    it("returns string result", function()
        reg:register({ name = "echo" }, function(args) return "got " .. args.x end)
        local r = reg:dispatch("echo", { x = "hi" }, {})
        expect(r):eq("got hi")
    end)

    it("encodes table results to JSON when ctx.json available", function()
        reg:register({ name = "obj" }, function() return { a = 1 } end)
        local r = reg:dispatch("obj", {}, { json = helpers.fake_json })
        expect(r):contains("\"a\"")
    end)

    it("propagates (nil, err) convention", function()
        reg:register({ name = "broken" }, function() return nil, "boom" end)
        local r, err = reg:dispatch("broken", {}, {})
        expect(r):nil_()
        expect(err):eq("boom")
    end)

    it("catches handler crashes via pcall", function()
        reg:register({ name = "crash" }, function() error("yikes") end)
        local r, err = reg:dispatch("crash", {}, {})
        expect(r):nil_()
        expect(err):contains("yikes")
    end)

    it("rejects unregistered tool name", function()
        local r, err = reg:dispatch("ghost", {}, {})
        expect(r):nil_()
        expect(err):contains("not registered")
    end)

    it("rejects disabled tool", function()
        reg:register({ name = "x" }, function() return "ok" end)
        reg:disable("x")
        local r, err = reg:dispatch("x", {}, {})
        expect(r):nil_()
        expect(err):contains("disabled")
    end)

    it("passes ctx as second handler argument", function()
        local seen
        reg:register({ name = "introspect" }, function(_, ctx)
            seen = ctx
            return "ok"
        end)
        local marker = { hello = "world" }
        reg:dispatch("introspect", {}, marker)
        expect(seen.hello):eq("world")
    end)
end)

describe("ToolRegistry: dispatch (module-path handler)", function()
    -- Files are recreated per test so the directory survives until the
    -- entire spec run completes (no premature rm -rf).
    local mod_dir
    before_each(function()
        mod_dir = "/tmp/lunatic_tools_spec_" .. tostring(os.time()) ..
                  "_" .. tostring(math.random(1, 1e9)) .. "/"
        os.execute('mkdir -p "' .. mod_dir .. '"')
        package.path = mod_dir .. "?.lua;" .. package.path

        local mfile = io.open(mod_dir .. "envtool.lua", "wb")
        mfile:write(
            "if not args or not ctx then return nil, 'missing globals' end\n" ..
            "return 'envtool got: ' .. tostring(args.x) .. ' / fs=' .. tostring(ctx.fs ~= nil)\n"
        )
        mfile:close()

        local mfile2 = io.open(mod_dir .. "errtool.lua", "wb")
        mfile2:write("return nil, 'module-level error'\n")
        mfile2:close()

        local mfile3 = io.open(mod_dir .. "boomtool.lua", "wb")
        mfile3:write("error('KABOOM')\n")
        mfile3:close()

        -- Drop any cached path resolutions across tests so the new mod_dir wins.
        for k in pairs(package.loaded) do
            if k == "lunatic.tools" then package.loaded[k] = nil end
        end
        Tools = require("lunatic.tools")
    end)

    it("invokes the file with args/ctx as env globals", function()
        local r = Tools.new()
        r:register({ name = "envtool" }, "envtool")
        local res = r:dispatch("envtool", { x = "hi" }, { fs = {} })
        expect(res):contains("envtool got: hi")
        expect(res):contains("fs=true")
    end)

    it("propagates module errors", function()
        local r = Tools.new()
        r:register({ name = "errtool" }, "errtool")
        local res, err = r:dispatch("errtool", {}, {})
        expect(res):nil_()
        expect(err):contains("module-level error")
    end)

    it("catches throws inside module", function()
        local r = Tools.new()
        r:register({ name = "boomtool" }, "boomtool")
        local res, err = r:dispatch("boomtool", {}, {})
        expect(res):nil_()
        expect(err):contains("KABOOM")
    end)

    it("missing module yields a friendly error", function()
        local r = Tools.new()
        r:register({ name = "ghost" }, "no.such.module")
        local res, err = r:dispatch("ghost", {}, {})
        expect(res):nil_()
        expect(err):contains("not found")
    end)
end)
