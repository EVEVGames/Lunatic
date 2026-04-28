-- spec/log_spec.lua
-- Tests for lunatic.log default logger.

local t       = require("spec.support.runner")
local log_lib = require("lunatic.log")

local describe, it, expect = t.describe, t.it, t.expect

describe("log.build_default", function()
    it("returns a callable", function()
        local logger = log_lib.build_default()
        expect(type(logger)):eq("function")
    end)

    it("calls the writer with formatted line", function()
        local got
        local logger = log_lib.build_default({ writer = function(s) got = s end })
        logger("info", "test_event", { agent_id = "main", x = 1 })
        expect(got):not_nil()
        expect(got):contains("test_event")
        expect(got):contains("[info]")
        expect(got):contains("[main]")
    end)

    it("respects min_level filter", function()
        local count = 0
        local logger = log_lib.build_default({
            min_level = "warn",
            writer = function() count = count + 1 end,
        })
        logger("debug", "skip_me", {})
        logger("info", "skip_me_too", {})
        logger("warn", "should_appear", {})
        logger("error", "should_appear", {})
        expect(count):eq(2)
    end)

    it("handles non-table data argument", function()
        local got
        local logger = log_lib.build_default({ writer = function(s) got = s end })
        logger("info", "evt", "just a string")
        expect(got):contains("evt")
    end)

    it("does not crash on writer that throws", function()
        local logger = log_lib.build_default({
            writer = function() error("bang") end,
        })
        expect(function() logger("info", "x", {}) end):does_not_throw()
    end)

    it("truncates long string values in payload", function()
        local got
        local logger = log_lib.build_default({ writer = function(s) got = s end })
        logger("info", "big", { agent_id = "a", text = string.rep("x", 500) })
        expect(#got):lt(700) -- formatter truncates
    end)
end)

describe("log.noop", function()
    it("returns a function that does nothing", function()
        local n = log_lib.noop()
        expect(type(n)):eq("function")
        expect(function() n("info", "evt", {}) end):does_not_throw()
    end)
end)
