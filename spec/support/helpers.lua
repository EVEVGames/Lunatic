-- spec/support/helpers.lua
-- Shared fixtures used across spec files.

local M = {}

-- ============================================================
-- Fake JSON: real round-trip implementation. Handles strings, numbers,
-- booleans, nil, nested arrays and objects. Sufficient for all tests.
-- ============================================================
local function enc(v)
    local t = type(v)
    if t == "string" then
        local s = v:gsub("\\", "\\\\"):gsub('"', '\\"')
                   :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. s .. '"'
    elseif t == "number" then
        return tostring(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        local is_array = (#v > 0)
        if not is_array then
            local has_keys = false
            for _ in pairs(v) do has_keys = true; break end
            if not has_keys then return "{}" end
        end
        local parts = {}
        if is_array then
            for i = 1, #v do parts[i] = enc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function dec(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                break
            end
        end
    end
    local parse_value
    local function parse_string()
        if s:sub(pos, pos) ~= '"' then error("expected string at " .. pos) end
        pos = pos + 1
        local buf = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(buf)
            elseif c == "\\" then
                local nc = s:sub(pos + 1, pos + 1)
                if nc == "n" then buf[#buf + 1] = "\n"
                elseif nc == "r" then buf[#buf + 1] = "\r"
                elseif nc == "t" then buf[#buf + 1] = "\t"
                elseif nc == "\\" then buf[#buf + 1] = "\\"
                elseif nc == '"' then buf[#buf + 1] = '"'
                else buf[#buf + 1] = nc end
                pos = pos + 2
            else buf[#buf + 1] = c; pos = pos + 1 end
        end
        error("unterminated string")
    end
    local function parse_number()
        local start = pos
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c:match("[%-%d%.eE%+]") then pos = pos + 1 else break end
        end
        return tonumber(s:sub(start, pos - 1))
    end
    local function parse_array()
        pos = pos + 1; skip_ws()
        local arr = {}
        if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            skip_ws()
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; return arr
            else error("expected , or ] at " .. pos) end
        end
    end
    local function parse_object()
        pos = pos + 1; skip_ws()
        local obj = {}
        if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            if s:sub(pos, pos) ~= ":" then error("expected : at " .. pos) end
            pos = pos + 1; skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; return obj
            else error("expected , or } at " .. pos) end
        end
    end
    parse_value = function()
        skip_ws()
        local c = s:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == "t" then pos = pos + 4; return true
        elseif c == "f" then pos = pos + 5; return false
        elseif c == "n" then pos = pos + 4; return nil
        else return parse_number() end
    end
    return parse_value()
end

M.fake_json = { encode = enc, decode = dec }

-- ============================================================
-- Fake FS: in-memory filesystem emulating io.open semantics.
-- ============================================================
function M.make_memory_fs()
    local files = {}     -- path -> string content
    local fs = { _files = files }

    local function make_handle(path, mode)
        local handle = {}
        local buffer = ""
        local read_pos = 1

        if mode == "rb" or mode == "r" then
            if not files[path] then return nil, "ENOENT: " .. path end
            buffer = files[path]
            function handle:read(what)
                if what == "*a" or what == "a" or what == nil then
                    local out = buffer:sub(read_pos)
                    read_pos = #buffer + 1
                    return out
                elseif what == "*l" or what == "l" then
                    local nl = buffer:find("\n", read_pos, true)
                    if not nl then
                        if read_pos > #buffer then return nil end
                        local line = buffer:sub(read_pos)
                        read_pos = #buffer + 1
                        return line
                    else
                        local line = buffer:sub(read_pos, nl - 1)
                        read_pos = nl + 1
                        return line
                    end
                end
                return nil
            end
            function handle:lines()
                return function() return self:read("*l") end
            end
            function handle:close() return true end

        elseif mode == "wb" or mode == "w" then
            files[path] = ""
            function handle:write(s)
                files[path] = files[path] .. tostring(s)
                return true
            end
            function handle:close() return true end

        elseif mode == "ab" or mode == "a" then
            files[path] = files[path] or ""
            function handle:write(s)
                files[path] = files[path] .. tostring(s)
                return true
            end
            function handle:close() return true end

        else
            return nil, "unsupported mode: " .. tostring(mode)
        end

        return handle
    end

    fs.open = function(path, mode) return make_handle(path, mode) end
    fs.exists = function(path) return files[path] ~= nil end
    fs.set = function(path, content) files[path] = content end
    fs.get = function(path) return files[path] end
    fs.list = function()
        local out = {}
        for p in pairs(files) do out[#out + 1] = p end
        return out
    end
    fs.clear = function()
        for k in pairs(files) do files[k] = nil end
    end
    return fs
end

-- ============================================================
-- Real-disk FS that uses io.open. Useful for tests that exercise
-- the filesystem path code.
-- ============================================================
M.real_fs = { open = function(p, m) return io.open(p, m) end }

-- ============================================================
-- Scripted provider: returns canned responses in order.
-- ============================================================
function M.scripted_provider(script)
    local idx = 0
    return {
        name = "scripted",
        chat = function(self, req, ctx)
            idx = idx + 1
            local resp = script[idx]
            if not resp then
                return {
                    content = "[end of script]",
                    finish = "stop", raw = {},
                }, nil
            end
            if type(resp) == "function" then
                return resp(req, ctx)
            end
            return resp, nil
        end,
        get_call_count = function() return idx end,
        reset = function() idx = 0 end,
    }
end

-- ============================================================
-- A unique temp workspace path for a test. Caller is responsible
-- for cleanup if they wrote real files.
-- ============================================================
local _workspace_counter = 0
function M.temp_workspace_path()
    _workspace_counter = _workspace_counter + 1
    return "/tmp/lunatic_spec_" .. tostring(os.time()) ..
           "_" .. tostring(_workspace_counter) .. "/"
end

-- ============================================================
-- Build a Lunatic instance with sensible test defaults.
-- Caller can pass overrides; they're shallow-merged.
-- ============================================================
function M.build_agent(overrides)
    local L = require("lunatic")
    local cfg = {
        workspace = M.temp_workspace_path(),
        http = function(opts) return "{}", 200 end,
        json = M.fake_json,
        fs = M.make_memory_fs(),
        llm = { provider = "scripted", model = "test-model" },
        log = function() end,
        builtin_tools = false,
    }
    if overrides then
        for k, v in pairs(overrides) do cfg[k] = v end
    end
    -- Register scripted provider lazily once.
    local provider_m = require("lunatic.provider")
    if not provider_m.has("scripted") then
        provider_m.register("scripted", function() return M.scripted_provider({}) end)
    end
    return L.Lunatic.new(cfg), cfg
end

-- ============================================================
-- Replace an agent's provider.chat with a scripted function.
-- ============================================================
function M.script_provider(agent, script)
    local idx = 0
    agent.provider.chat = function(self, req, ctx)
        idx = idx + 1
        local resp = script[idx]
        if not resp then
            return { content = "[end]", finish = "stop", raw = {} }, nil
        end
        if type(resp) == "function" then
            return resp(req, ctx)
        end
        return resp, nil
    end
    return function() return idx end
end

return M
