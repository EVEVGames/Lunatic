-- lunatic/tools.lua
-- Tool registry: stores tool specs + handlers, validates input, dispatches calls.
--
-- A handler can be:
--   * a Lua function: called directly as handler(args, ctx).
--   * a string: treated as a module path passed to require() lazily on first call.
--     The required module file is expected to be a top-level script that:
--       local args, ctx = ...
--       -- (do work)
--       return <result>
--     i.e. it accepts args and ctx via varargs and returns the result
--     as the chunk's return value. We invoke it as a fresh chunk each call so
--     state does not leak between invocations (use loadfile semantics).
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}
local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

-- Constructor. opts = { log = function(...) end }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, ToolRegistry)
    self._tools = {}            -- name -> { spec, handler, enabled, source }
    self._order = {}            -- ordered list of names (for stable list_tools)
    self.log = opts.log or function() end
    return self
end

-- Validate a spec table. Required: name (string), description (string).
-- parameters defaults to a permissive empty object schema.
local function normalise_spec(spec)
    if type(spec) ~= "table" then
        return nil, "spec must be a table"
    end
    if type(spec.name) ~= "string" or spec.name == "" then
        return nil, "spec.name is required"
    end
    local out = {
        name = spec.name,
        description = spec.description or "",
        parameters = spec.parameters or { type = "object", properties = {} },
    }
    return out, nil
end

-- Register a tool. Two call shapes:
--   :register(spec, handler)               -- name comes from spec.name
--   :register(name, spec, handler)         -- explicit name overrides spec.name
-- handler may be a function or a module path string.
-- Returns (true, nil) or (nil, err).
function ToolRegistry:register(a, b, c)
    local explicit_name, spec, handler
    if type(a) == "string" then
        explicit_name, spec, handler = a, b, c
    else
        spec, handler = a, b
    end

    -- If only an explicit name was given without spec, allow shorthand
    -- :register("name", handler) by synthesising a minimal spec.
    if explicit_name and (type(spec) == "function" or type(spec) == "string")
        and handler == nil then
        handler = spec
        spec = { name = explicit_name }
    end

    if type(spec) ~= "table" then
        return nil, "spec must be a table"
    end
    if explicit_name then
        spec = util.shallow_copy(spec)
        spec.name = explicit_name
    end

    local norm, err = normalise_spec(spec)
    if not norm then return nil, err end

    if type(handler) ~= "function" and type(handler) ~= "string" then
        return nil, "handler must be a function or a module path string"
    end

    local source = (type(handler) == "string") and handler or "function"
    self._tools[norm.name] = {
        spec = norm,
        handler = handler,
        enabled = true,
        source = source,
    }
    -- Maintain ordered name list (replace position if re-registering).
    local found_idx = nil
    for i = 1, #self._order do
        if self._order[i] == norm.name then
            found_idx = i; break
        end
    end
    if not found_idx then
        self._order[#self._order + 1] = norm.name
    end

    self.log("debug", "tool_registered", { tool = norm.name, source = source })
    return true, nil
end

-- Unregister a tool. Returns true if removed.
function ToolRegistry:unregister(name)
    if not self._tools[name] then
        return false
    end
    self._tools[name] = nil
    for i = 1, #self._order do
        if self._order[i] == name then
            table.remove(self._order, i)
            break
        end
    end
    self.log("debug", "tool_unregistered", { tool = name })
    return true
end

function ToolRegistry:has(name)
    return self._tools[name] ~= nil
end

function ToolRegistry:get(name)
    local entry = self._tools[name]
    if not entry then return nil end
    return { spec = entry.spec, handler = entry.handler,
        enabled = entry.enabled, source = entry.source }
end

function ToolRegistry:enable(name)
    local entry = self._tools[name]
    if not entry then return false end
    entry.enabled = true
    return true
end

function ToolRegistry:disable(name)
    local entry = self._tools[name]
    if not entry then return false end
    entry.enabled = false
    return true
end

-- Remove all tools.
function ToolRegistry:clear()
    self._tools = {}
    self._order = {}
    self.log("debug", "tools_cleared", {})
end

-- Return list of OpenAI-style tool specs (only enabled ones).
function ToolRegistry:list()
    local out = {}
    for i = 1, #self._order do
        local name = self._order[i]
        local entry = self._tools[name]
        if entry and entry.enabled then
            out[#out + 1] = {
                type = "function",
                ["function"] = {
                    name = entry.spec.name,
                    description = entry.spec.description,
                    parameters = entry.spec.parameters,
                },
            }
        end
    end
    return out
end

-- Return list of names (all, regardless of enabled state).
function ToolRegistry:names()
    local out = {}
    for i = 1, #self._order do
        out[i] = self._order[i]
    end
    return out
end

-- Cache for resolved file paths. Keyed by module path string. We do NOT cache
-- the chunk itself: we re-load each invocation so fresh args/ctx are provided
-- via varargs on each call.
local _module_path_cache = {}

-- Resolve a module path (e.g. "tools.webbrowser") to an on-disk file path.
local function resolve_module_path(module_path)
    if _module_path_cache[module_path] then
        return _module_path_cache[module_path], nil
    end

    local file_path
    if package and package.searchpath then
        file_path = package.searchpath(module_path, package.path)
    else
        -- Lua 5.1 fallback.
        local rel = module_path:gsub("%.", "/")
        for chunk_path in (package.path or ""):gmatch("([^;]+)") do
            local candidate = chunk_path:gsub("%?", rel)
            local fh = io.open(candidate, "rb")
            if fh then fh:close(); file_path = candidate; break end
        end
    end

    if not file_path then
        return nil, "module not found in package.path: " .. module_path
    end

    _module_path_cache[module_path] = file_path
    return file_path, nil
end

-- Build a callable that loads the tool file fresh each call and runs it
-- with `args` and `ctx` injected as varargs.
local function make_module_handler(module_path)
    return function(args, ctx)
        local file_path, err = resolve_module_path(module_path)
        if not file_path then return nil, err end

        local chunk, lerr
        if loadfile then
            chunk, lerr = loadfile(file_path)
        end
        if not chunk then
            return nil, "loadfile failed: " .. tostring(lerr)
        end

        -- Module-style tools receive args and ctx via varargs.
        -- Invoke as: local args, ctx = ...
        local pcall_ret = { pcall(chunk, args, ctx) }
        local ok = pcall_ret[1]
        if not ok then
            return nil, "tool chunk error: " .. tostring(pcall_ret[2])
        end
        -- Convention: return value, or (value, err), or (nil, err).
        return pcall_ret[2], pcall_ret[3]
    end
end

-- Stringify a tool result for inclusion in the conversation as tool message content.
local function stringify_result(result, json_lib)
    if result == nil then
        return ""
    end
    if type(result) == "string" then
        return result
    end
    if type(result) == "number" or type(result) == "boolean" then
        return tostring(result)
    end
    if type(result) == "table" then
        if json_lib then
            local s, err = util.safe_encode(json_lib, result)
            if s then return s end
        end
        return tostring(result)
    end
    return tostring(result)
end

-- Dispatch: execute a tool by name with decoded args.
-- Returns (result_string, nil) on success or (nil, err_string) on failure.
-- ctx is passed to function handlers as their 2nd argument (carries json, fs, http,
-- agent reference, etc.).
function ToolRegistry:dispatch(name, args, ctx)
    local entry = self._tools[name]
    if not entry then
        return nil, "tool not registered: " .. tostring(name)
    end
    if not entry.enabled then
        return nil, "tool disabled: " .. tostring(name)
    end

    local handler = entry.handler
    local fn

    if type(handler) == "function" then
        fn = handler
    elseif type(handler) == "string" then
        fn = make_module_handler(handler)
    else
        return nil, "tool has invalid handler type"
    end

    -- We always go through pcall and capture both return values from
    -- handlers (so the convention `return value, err` or `return nil, err`
    -- works uniformly for function and module handlers).
    local pcall_ret = { pcall(fn, args, ctx) }
    local ok = pcall_ret[1]
    if not ok then
        return nil, "tool error: " .. tostring(pcall_ret[2])
    end
    local result = pcall_ret[2]
    local err    = pcall_ret[3]

    if err and result == nil then
        return nil, err
    end

    return stringify_result(result, ctx and ctx.json or nil), nil
end

return M
