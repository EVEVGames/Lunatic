-- spec/support/runner.lua
-- A minimalist test framework for Lunatic specs. No external deps.
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.
--
-- Usage:
--   local t = require("spec.support.runner")
--   local describe, it, expect = t.describe, t.it, t.expect
--   describe("Module X", function()
--       it("does Y", function()
--           expect(1 + 1):eq(2)
--       end)
--   end)
--   t.run()        -- prints results, exits with code 1 on failure

local M = {}

local _suites = {}
local _current_suite = nil
local _stats = { suites = 0, tests = 0, failed = 0, errors = 0, skipped = 0 }
local _failures = {}

-- describe(name, fn) groups a set of related `it` blocks.
function M.describe(name, fn)
    _stats.suites = _stats.suites + 1
    local suite = { name = name, tests = {}, before_each = nil, after_each = nil }
    table.insert(_suites, suite)
    _current_suite = suite
    fn()
    _current_suite = nil
end

-- it(name, fn) registers a single test inside the current suite.
function M.it(name, fn)
    if not _current_suite then
        error("`it` called outside `describe`: " .. tostring(name))
    end
    table.insert(_current_suite.tests, { name = name, fn = fn, skip = false })
end

-- pending(name) registers a placeholder (skipped) test.
function M.pending(name)
    if not _current_suite then return end
    table.insert(_current_suite.tests, { name = name, fn = nil, skip = true })
end

-- before_each(fn) and after_each(fn) attach setup/teardown to the current suite.
function M.before_each(fn) _current_suite.before_each = fn end
function M.after_each(fn)  _current_suite.after_each  = fn end

-- expect(value) returns a matcher object.
local Matcher = {}
Matcher.__index = Matcher

local function fail(msg)
    error({ __lunatic_test_failure = true, msg = msg }, 2)
end

local function fmt(v, depth)
    depth = depth or 0
    if depth > 3 then return "<...>" end
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        local parts = {}
        local count = 0
        for k, val in pairs(v) do
            count = count + 1
            if count > 6 then parts[#parts + 1] = "..."; break end
            local key = (type(k) == "string") and k or ("[" .. tostring(k) .. "]")
            parts[#parts + 1] = key .. "=" .. fmt(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

function Matcher:eq(other)
    if self.value ~= other then
        fail("expected " .. fmt(other) .. " but got " .. fmt(self.value))
    end
end

function Matcher:neq(other)
    if self.value == other then
        fail("expected NOT " .. fmt(other) .. " but got equal")
    end
end

function Matcher:truthy()
    if not self.value then
        fail("expected truthy but got " .. fmt(self.value))
    end
end

function Matcher:falsy()
    if self.value then
        fail("expected falsy but got " .. fmt(self.value))
    end
end

function Matcher:nil_()
    if self.value ~= nil then
        fail("expected nil but got " .. fmt(self.value))
    end
end

function Matcher:not_nil()
    if self.value == nil then
        fail("expected non-nil")
    end
end

function Matcher:is_a(typename)
    if type(self.value) ~= typename then
        fail("expected type " .. typename .. " but got " .. type(self.value))
    end
end

function Matcher:matches(pattern)
    if type(self.value) ~= "string" then
        fail("expected string for :matches but got " .. type(self.value))
    end
    if not self.value:find(pattern) then
        fail("expected string to match " .. fmt(pattern) ..
             " but got " .. fmt(self.value))
    end
end

function Matcher:contains(needle)
    if type(self.value) == "string" then
        if not self.value:find(needle, 1, true) then
            fail("expected string to contain " .. fmt(needle) ..
                 " but got " .. fmt(self.value))
        end
    elseif type(self.value) == "table" then
        for _, v in pairs(self.value) do
            if v == needle then return end
        end
        fail("expected table to contain " .. fmt(needle))
    else
        fail(":contains requires string or table, got " .. type(self.value))
    end
end

function Matcher:has_key(key)
    if type(self.value) ~= "table" then
        fail(":has_key requires table, got " .. type(self.value))
    end
    if self.value[key] == nil then
        fail("expected table to have key " .. fmt(key))
    end
end

function Matcher:length(n)
    if type(self.value) ~= "table" and type(self.value) ~= "string" then
        fail(":length requires table or string")
    end
    if #self.value ~= n then
        fail("expected length " .. tostring(n) .. " but got " .. tostring(#self.value))
    end
end

function Matcher:gt(n)
    if not (self.value > n) then
        fail("expected > " .. tostring(n) .. " but got " .. tostring(self.value))
    end
end

function Matcher:gte(n)
    if not (self.value >= n) then
        fail("expected >= " .. tostring(n) .. " but got " .. tostring(self.value))
    end
end

function Matcher:lt(n)
    if not (self.value < n) then
        fail("expected < " .. tostring(n) .. " but got " .. tostring(self.value))
    end
end

function Matcher:lte(n)
    if not (self.value <= n) then
        fail("expected <= " .. tostring(n) .. " but got " .. tostring(self.value))
    end
end

function Matcher:throws(pattern)
    if type(self.value) ~= "function" then
        fail(":throws requires a function")
    end
    local ok, err = pcall(self.value)
    if ok then
        fail("expected function to throw")
    end
    if pattern and not tostring(err):find(pattern) then
        fail("expected error to match " .. fmt(pattern) .. " but got " .. tostring(err))
    end
end

function Matcher:does_not_throw()
    if type(self.value) ~= "function" then
        fail(":does_not_throw requires a function")
    end
    local ok, err = pcall(self.value)
    if not ok then
        fail("expected no throw, but got: " .. tostring(err))
    end
end

-- Deep equality for tables.
local function deep_eq(a, b, seen)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    seen = seen or {}
    if seen[a] then return seen[a] == b end
    seen[a] = b
    for k, v in pairs(a) do
        if not deep_eq(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function Matcher:deep_eq(other)
    if not deep_eq(self.value, other) then
        fail("deep_eq failed: expected " .. fmt(other) .. " got " .. fmt(self.value))
    end
end

function M.expect(value)
    return setmetatable({ value = value }, Matcher)
end

-- Run all registered suites.
function M.run(opts)
    opts = opts or {}
    local verbose = opts.verbose
    local start_time = os.clock()

    for _, suite in ipairs(_suites) do
        print("\n* " .. suite.name)
        for _, test in ipairs(suite.tests) do
            _stats.tests = _stats.tests + 1
            if test.skip then
                _stats.skipped = _stats.skipped + 1
                print("  - " .. test.name .. " (pending)")
            else
                if suite.before_each then
                    local ok, err = pcall(suite.before_each)
                    if not ok then
                        print("  ! before_each crashed: " .. tostring(err))
                    end
                end

                local ok, err = pcall(test.fn)

                if suite.after_each then
                    pcall(suite.after_each)
                end

                if ok then
                    if verbose then print("  + " .. test.name) end
                else
                    if type(err) == "table" and err.__lunatic_test_failure then
                        _stats.failed = _stats.failed + 1
                        print("  X " .. test.name)
                        print("      " .. err.msg)
                        table.insert(_failures, suite.name .. " > " .. test.name .. ": " .. err.msg)
                    else
                        _stats.errors = _stats.errors + 1
                        print("  E " .. test.name)
                        print("      crashed: " .. tostring(err))
                        table.insert(_failures, suite.name .. " > " .. test.name .. ": CRASH " .. tostring(err))
                    end
                end
            end
        end
    end

    local elapsed = os.clock() - start_time
    print("")
    print(string.format(
        "%d suites, %d tests: %d passed, %d failed, %d errored, %d skipped (%.2fs)",
        _stats.suites,
        _stats.tests,
        _stats.tests - _stats.failed - _stats.errors - _stats.skipped,
        _stats.failed, _stats.errors, _stats.skipped, elapsed
    ))

    if _stats.failed > 0 or _stats.errors > 0 then
        print("\nFAILURES:")
        for _, f in ipairs(_failures) do
            print("  " .. f)
        end
        os.exit(1)
    end

    return _stats
end

-- Reset all state (useful between full re-runs in the same process).
function M.reset()
    _suites = {}
    _current_suite = nil
    _stats = { suites = 0, tests = 0, failed = 0, errors = 0, skipped = 0 }
    _failures = {}
end

return M
