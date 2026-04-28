-- lunatic/util.lua
-- General-purpose helpers used across the library.
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local M = {}

-- Lua-version-agnostic table.unpack
M.unpack = table.unpack or unpack

-- Safe JSON encode: never throws. Returns (string, nil) on success,
-- (nil, err_message) on failure.
function M.safe_encode(json_lib, value)
    if not json_lib or not json_lib.encode then
        return nil, "json library missing encode function"
    end
    local ok, result = pcall(json_lib.encode, value)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

-- Safe JSON decode: never throws. Returns (value, nil) or (nil, err_message).
function M.safe_decode(json_lib, str)
    if not json_lib or not json_lib.decode then
        return nil, "json library missing decode function"
    end
    if type(str) ~= "string" or str == "" then
        return nil, "cannot decode empty input"
    end
    local ok, result = pcall(json_lib.decode, str)
    if not ok then
        return nil, tostring(result)
    end
    if result == nil then
        return nil, "decoder returned nil"
    end
    return result, nil
end

-- Rough token estimation: chars / 4 (good enough for budget heuristics).
function M.estimate_tokens(text)
    if type(text) ~= "string" then
        return 0
    end
    return math.floor(#text / 4) + 1
end

-- Estimate tokens for a list of message tables.
function M.estimate_messages_tokens(messages)
    local total = 0
    if type(messages) ~= "table" then
        return 0
    end
    for i = 1, #messages do
        local m = messages[i]
        if type(m) == "table" then
            if type(m.content) == "string" then
                total = total + M.estimate_tokens(m.content)
            elseif type(m.content) == "table" then
                -- multi-part content (vision / tool calls)
                for j = 1, #m.content do
                    local part = m.content[j]
                    if type(part) == "table" and type(part.text) == "string" then
                        total = total + M.estimate_tokens(part.text)
                    end
                end
            end
            if type(m.tool_calls) == "table" then
                for j = 1, #m.tool_calls do
                    local tc = m.tool_calls[j]
                    if type(tc) == "table" and type(tc["function"]) == "table" then
                        local args = tc["function"].arguments
                        if type(args) == "string" then
                            total = total + M.estimate_tokens(args)
                        end
                    end
                end
            end
        end
    end
    return total
end

-- Shallow copy of a table.
function M.shallow_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

-- Deep copy (handles nested tables, ignores cycles via visited set).
function M.deep_copy(value, visited)
    if type(value) ~= "table" then
        return value
    end
    visited = visited or {}
    if visited[value] then
        return visited[value]
    end
    local out = {}
    visited[value] = out
    for k, v in pairs(value) do
        out[M.deep_copy(k, visited)] = M.deep_copy(v, visited)
    end
    return out
end

-- Deep merge: keys from override replace base; nested tables are merged.
-- Returns a new table; does not mutate inputs.
function M.deep_merge(base, override)
    local result = M.deep_copy(base or {})
    if type(override) ~= "table" then
        return result
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = M.deep_merge(result[k], v)
        else
            result[k] = M.deep_copy(v)
        end
    end
    return result
end

-- Trim leading/trailing whitespace.
function M.trim(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Seed math.random once when the module is first loaded so :gen_id() produces
-- different sequences across processes. Without seeding, Lua 5.1 / LuaJIT
-- always start from the same state and ids would collide between runs.
-- We mix in tostring({}) since the hex address of a fresh table differs per
-- process (and per Lua state inside a process), giving a cheap salt.
do
    local salt = 0
    -- {}'s hex tail varies per process / Lua state.
    local s = tostring({}):match("0x(%x+)") or "0"
    -- tonumber base-16 works on every supported version.
    salt = tonumber(s, 16) or 0
    -- math.randomseed is part of the core math library on all targeted versions.
    pcall(math.randomseed, os.time() + (salt % 0xFFFFFF))
    -- Discard a few values: some Lua versions return a poor first sample.
    for _ = 1, 3 do math.random() end
end

-- Generate a short random-ish id (no external deps, no os.urandom).
-- Combines time + counter + math.random.
local _id_counter = 0
function M.gen_id(prefix)
    _id_counter = _id_counter + 1
    local t = os.time()
    local r = math.random(0, 0xFFFFFF)
    -- Use string.format with %x — works on all versions.
    local raw = string.format("%x%x%x", t, _id_counter, r)
    if prefix then
        return prefix .. "_" .. raw
    end
    return raw
end

-- ISO-8601-ish UTC timestamp (uses os.date "!" for UTC).
function M.iso_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Local YYYY-MM-DD date (used for daily journal filenames).
function M.today_string()
    return os.date("%Y-%m-%d")
end

-- Check if a value is "callable" (function or table with __call).
function M.is_callable(v)
    if type(v) == "function" then
        return true
    end
    if type(v) == "table" then
        local mt = getmetatable(v)
        if mt and type(mt.__call) == "function" then
            return true
        end
    end
    return false
end

-- Append to an array-like table.
function M.append(arr, value)
    arr[#arr + 1] = value
    return arr
end

-- Concatenate two array-like tables into a new one.
function M.concat_arrays(a, b)
    local out = {}
    if type(a) == "table" then
        for i = 1, #a do
            out[#out + 1] = a[i]
        end
    end
    if type(b) == "table" then
        for i = 1, #b do
            out[#out + 1] = b[i]
        end
    end
    return out
end

-- Remove item by name from an array of {name=...} entries. Returns true if removed.
function M.remove_by_name(arr, name)
    if type(arr) ~= "table" then
        return false
    end
    for i = 1, #arr do
        if arr[i] and arr[i].name == name then
            table.remove(arr, i)
            return true
        end
    end
    return false
end

-- Find item by name in an array of {name=...} entries.
function M.find_by_name(arr, name)
    if type(arr) ~= "table" then
        return nil
    end
    for i = 1, #arr do
        if arr[i] and arr[i].name == name then
            return arr[i], i
        end
    end
    return nil
end

return M
