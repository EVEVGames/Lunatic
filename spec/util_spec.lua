-- spec/util_spec.lua
-- Tests for lunatic.util helpers.

local t       = require("spec.support.runner")
local helpers = require("spec.support.helpers")
local util    = require("lunatic.util")

local describe, it, expect = t.describe, t.it, t.expect

describe("util.unpack", function()
    it("is callable like the standard unpack", function()
        local a, b, c = util.unpack({ 1, 2, 3 })
        expect(a):eq(1); expect(b):eq(2); expect(c):eq(3)
    end)

    it("handles empty tables", function()
        expect(util.unpack({})):nil_()
    end)
end)

describe("util.safe_encode", function()
    it("encodes a simple table", function()
        local s, err = util.safe_encode(helpers.fake_json, { x = 1 })
        expect(err):nil_()
        expect(s):is_a("string")
    end)

    it("returns error for missing json lib", function()
        local s, err = util.safe_encode(nil, {})
        expect(s):nil_()
        expect(err):matches("missing")
    end)

    it("returns error for nil encoder", function()
        local s, err = util.safe_encode({}, {})
        expect(s):nil_()
        expect(err):matches("missing")
    end)

    it("never throws on bad encoder", function()
        local bad = { encode = function() error("boom") end }
        local s, err = util.safe_encode(bad, {})
        expect(s):nil_()
        expect(err):not_nil()
    end)
end)

describe("util.safe_decode", function()
    it("decodes valid input", function()
        local v, err = util.safe_decode(helpers.fake_json, '{"x":1}')
        expect(err):nil_()
        expect(v.x):eq(1)
    end)

    it("rejects empty input", function()
        local v, err = util.safe_decode(helpers.fake_json, "")
        expect(v):nil_()
        expect(err):matches("empty")
    end)

    it("rejects nil input", function()
        local v, err = util.safe_decode(helpers.fake_json, nil)
        expect(v):nil_()
    end)

    it("never throws on malformed input", function()
        local v, err = util.safe_decode(helpers.fake_json, "not json {")
        expect(v):nil_()
        expect(err):not_nil()
    end)
end)

describe("util.estimate_tokens", function()
    it("returns 0 for non-string", function()
        expect(util.estimate_tokens(nil)):eq(0)
        expect(util.estimate_tokens(42)):eq(0)
    end)

    it("estimates roughly chars/4 for ASCII", function()
        local s = string.rep("a", 100)
        local toks = util.estimate_tokens(s)
        expect(toks):gte(20)
        expect(toks):lte(30)
    end)

    it("returns at least 1 for empty string", function()
        expect(util.estimate_tokens("")):eq(1)
    end)
end)

describe("util.estimate_messages_tokens", function()
    it("counts text content across messages", function()
        local msgs = {
            { role = "user", content = string.rep("a", 80) },
            { role = "assistant", content = string.rep("b", 80) },
        }
        expect(util.estimate_messages_tokens(msgs)):gte(40)
    end)

    it("returns 0 for non-table input", function()
        expect(util.estimate_messages_tokens("nope")):eq(0)
    end)

    it("handles structured content arrays", function()
        local msgs = {
            { role = "user", content = {
                { type = "text", text = string.rep("x", 40) },
                { type = "text", text = string.rep("y", 40) },
            } },
        }
        expect(util.estimate_messages_tokens(msgs)):gte(15)
    end)

    it("counts tool_call argument strings", function()
        local msgs = {
            { role = "assistant", tool_calls = {
                { ["function"] = { arguments = string.rep("z", 40) } },
            } },
        }
        expect(util.estimate_messages_tokens(msgs)):gte(8)
    end)
end)

describe("util.shallow_copy", function()
    it("copies top-level keys", function()
        local src = { a = 1, b = "x" }
        local cp  = util.shallow_copy(src)
        expect(cp.a):eq(1); expect(cp.b):eq("x")
        cp.a = 99
        expect(src.a):eq(1)
    end)

    it("does not deep-copy nested tables", function()
        local nested = {}
        local src = { x = nested }
        local cp = util.shallow_copy(src)
        expect(cp.x == nested):truthy()
    end)

    it("returns non-tables as is", function()
        expect(util.shallow_copy(42)):eq(42)
        expect(util.shallow_copy("s")):eq("s")
        expect(util.shallow_copy(nil)):nil_()
    end)
end)

describe("util.deep_copy", function()
    it("recursively copies nested tables", function()
        local src = { a = { b = { c = 1 } } }
        local cp = util.deep_copy(src)
        cp.a.b.c = 99
        expect(src.a.b.c):eq(1)
    end)

    it("handles cycles without infinite recursion", function()
        local a = {}
        a.self = a
        local cp = util.deep_copy(a)
        expect(cp.self == cp):truthy()
    end)
end)

describe("util.deep_merge", function()
    it("merges nested tables", function()
        local base = { a = 1, nest = { x = 10, y = 20 } }
        local over = { b = 2, nest = { y = 99, z = 33 } }
        local out = util.deep_merge(base, over)
        expect(out.a):eq(1)
        expect(out.b):eq(2)
        expect(out.nest.x):eq(10)
        expect(out.nest.y):eq(99)
        expect(out.nest.z):eq(33)
    end)

    it("does not mutate inputs", function()
        local base = { x = { y = 1 } }
        local over = { x = { y = 2 } }
        util.deep_merge(base, over)
        expect(base.x.y):eq(1)
        expect(over.x.y):eq(2)
    end)

    it("treats nil override as identity", function()
        local out = util.deep_merge({ a = 1 }, nil)
        expect(out.a):eq(1)
    end)

    it("treats nil base as empty", function()
        local out = util.deep_merge(nil, { a = 1 })
        expect(out.a):eq(1)
    end)
end)

describe("util.trim", function()
    it("strips whitespace from both ends", function()
        expect(util.trim("  hello  ")):eq("hello")
    end)
    it("leaves clean strings alone", function()
        expect(util.trim("hi")):eq("hi")
    end)
    it("returns non-strings unchanged", function()
        expect(util.trim(42)):eq(42)
    end)
    it("handles tabs and newlines", function()
        expect(util.trim("\n\thello\t\n")):eq("hello")
    end)
end)

describe("util.gen_id", function()
    it("returns a string", function()
        expect(util.gen_id()):is_a("string")
    end)
    it("two calls produce different ids", function()
        local a = util.gen_id()
        local b = util.gen_id()
        expect(a ~= b):truthy()
    end)
    it("respects prefix when given", function()
        expect(util.gen_id("foo")):matches("^foo_")
    end)
end)

describe("util.iso_timestamp", function()
    it("returns a string with the expected shape", function()
        local s = util.iso_timestamp()
        expect(s):matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
    end)
end)

describe("util.today_string", function()
    it("returns YYYY-MM-DD", function()
        expect(util.today_string()):matches("^%d%d%d%d%-%d%d%-%d%d$")
    end)
end)

describe("util.is_callable", function()
    it("returns true for functions", function()
        expect(util.is_callable(function() end)):truthy()
    end)
    it("returns true for tables with __call", function()
        local t1 = setmetatable({}, { __call = function() end })
        expect(util.is_callable(t1)):truthy()
    end)
    it("returns false for plain tables", function()
        expect(util.is_callable({})):falsy()
    end)
    it("returns false for primitives", function()
        expect(util.is_callable(1)):falsy()
        expect(util.is_callable("s")):falsy()
        expect(util.is_callable(nil)):falsy()
    end)
end)

describe("util.append", function()
    it("appends to an array-like table", function()
        local a = { 1, 2 }
        util.append(a, 3)
        expect(a[3]):eq(3)
        expect(#a):eq(3)
    end)
end)

describe("util.concat_arrays", function()
    it("merges two arrays", function()
        local out = util.concat_arrays({ 1, 2 }, { 3, 4 })
        expect(#out):eq(4)
        expect(out[3]):eq(3)
    end)
    it("handles nil arguments", function()
        expect(#util.concat_arrays(nil, { 1 })):eq(1)
        expect(#util.concat_arrays({ 1 }, nil)):eq(1)
    end)
end)

describe("util.find_by_name and remove_by_name", function()
    it("finds by name", function()
        local arr = { { name = "a" }, { name = "b" } }
        local found, idx = util.find_by_name(arr, "b")
        expect(found.name):eq("b")
        expect(idx):eq(2)
    end)
    it("removes by name", function()
        local arr = { { name = "a" }, { name = "b" } }
        expect(util.remove_by_name(arr, "a")):truthy()
        expect(#arr):eq(1)
        expect(arr[1].name):eq("b")
    end)
    it("returns false when name missing", function()
        expect(util.remove_by_name({}, "x")):falsy()
    end)
end)
