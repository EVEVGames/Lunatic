-- lunatic/memory.lua
-- Persistent memory store backed by markdown / json files in the workspace.
-- All paths live FLAT in the workspace root (no subdirectory creation, since
-- pure Lua cannot create directories without OS-specific tooling).
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}
local MemoryStore = {}
MemoryStore.__index = MemoryStore

-- Bootstrap files that are loaded into the system prompt (read-only by default).
M.BOOTSTRAP_FILES = { "AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md" }

-- Files that store mutable state.
M.MEMORY_FILE  = "MEMORY.md"
M.HISTORY_FILE = "HISTORY.md"

-- Build a path by joining workspace + filename. We intentionally do not normalise
-- the path beyond appending a separator if missing.
local function join_path(workspace, name)
    if not workspace or workspace == "" then
        return name
    end
    local sep = "/"
    -- Detect Windows-style workspace and use backslash.
    if workspace:find("\\", 1, true) and not workspace:find("/", 1, true) then
        sep = "\\"
    end
    -- Strip trailing separator if present.
    local last = workspace:sub(-1)
    if last == "/" or last == "\\" then
        return workspace .. name
    end
    return workspace .. sep .. name
end
M.join_path = join_path

-- Read a whole file via the injected fs. Returns (content, err).
-- Treats missing files as (nil, "not found") rather than raising.
local function read_file(fs, path)
    if not fs or type(fs.open) ~= "function" then
        return nil, "fs.open not available"
    end
    local ok, fh = pcall(fs.open, path, "rb")
    if not ok or not fh then
        return nil, "not found"
    end
    local content
    local ok2, err = pcall(function()
        content = fh:read("*a")
        fh:close()
    end)
    if not ok2 then
        pcall(function() fh:close() end)
        return nil, tostring(err)
    end
    return content, nil
end

-- Write whole file. Returns (true, nil) or (nil, err).
local function write_file(fs, path, content)
    if not fs or type(fs.open) ~= "function" then
        return nil, "fs.open not available"
    end
    local ok, fh, oerr = pcall(fs.open, path, "wb")
    if not ok or not fh then
        return nil, "open failed: " .. tostring(oerr or fh)
    end
    local ok2, werr = pcall(function()
        fh:write(content or "")
        fh:close()
    end)
    if not ok2 then
        pcall(function() fh:close() end)
        return nil, tostring(werr)
    end
    return true, nil
end

-- Append content. Returns (true, nil) or (nil, err).
local function append_file(fs, path, content)
    if not fs or type(fs.open) ~= "function" then
        return nil, "fs.open not available"
    end
    local ok, fh, oerr = pcall(fs.open, path, "ab")
    if not ok or not fh then
        return nil, "open failed: " .. tostring(oerr or fh)
    end
    local ok2, werr = pcall(function()
        fh:write(content or "")
        fh:close()
    end)
    if not ok2 then
        pcall(function() fh:close() end)
        return nil, tostring(werr)
    end
    return true, nil
end

-- Constructor.
-- opts = { fs = ..., json = ..., workspace = "...", log = function(...) end }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, MemoryStore)
    self.fs = opts.fs
    self.json = opts.json
    self.workspace = opts.workspace or "./.lunatic/"
    self.log = opts.log or function() end
    return self
end

-- Resolve an arbitrary file name to its full path.
function MemoryStore:path(name)
    return join_path(self.workspace, name)
end

-- Generic markdown read.
function MemoryStore:read_md(name)
    local content, err = read_file(self.fs, self:path(name))
    return content, err
end

-- Generic markdown write.
function MemoryStore:write_md(name, content)
    return write_file(self.fs, self:path(name), content)
end

-- Read all bootstrap files concatenated. Missing files are silently skipped.
-- Returns a single string (possibly empty).
function MemoryStore:read_bootstrap()
    local parts = {}
    for i = 1, #M.BOOTSTRAP_FILES do
        local name = M.BOOTSTRAP_FILES[i]
        local content = read_file(self.fs, self:path(name))
        if content and content ~= "" then
            parts[#parts + 1] = "# " .. name .. "\n\n" .. content
        end
    end
    return table.concat(parts, "\n\n")
end

-- Read consolidated facts from MEMORY.md.
function MemoryStore:read_facts()
    local content = read_file(self.fs, self:path(M.MEMORY_FILE))
    return content or ""
end

-- Replace MEMORY.md content entirely.
function MemoryStore:write_facts(content)
    return write_file(self.fs, self:path(M.MEMORY_FILE), content or "")
end

-- Append a fact entry to MEMORY.md (with ISO timestamp prefix).
function MemoryStore:append_fact(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty fact"
    end
    local entry = string.format("\n- [%s] %s\n", util.iso_timestamp(), text)
    return append_file(self.fs, self:path(M.MEMORY_FILE), entry)
end

-- Read HISTORY.md.
function MemoryStore:read_history()
    local content = read_file(self.fs, self:path(M.HISTORY_FILE))
    return content or ""
end

-- Append a single line to HISTORY.md.
function MemoryStore:append_history(line)
    if type(line) ~= "string" or line == "" then
        return nil, "empty line"
    end
    local entry = string.format("[%s] %s\n", util.iso_timestamp(), line)
    return append_file(self.fs, self:path(M.HISTORY_FILE), entry)
end

-- Daily journal: YYYY-MM-DD.md at workspace root.
local function journal_filename(date_str)
    return (date_str or util.today_string()) .. ".md"
end

function MemoryStore:read_journal(date_str)
    return read_file(self.fs, self:path(journal_filename(date_str)))
end

function MemoryStore:append_journal(text, date_str)
    if type(text) ~= "string" or text == "" then
        return nil, "empty entry"
    end
    local entry = string.format("\n- [%s] %s\n", util.iso_timestamp(), text)
    return append_file(self.fs, self:path(journal_filename(date_str)), entry)
end

-- Session snapshot: <id>.json at workspace root.
local function session_filename(id)
    return tostring(id) .. ".json"
end

function MemoryStore:save_session(id, data)
    if not self.json then
        return nil, "json library not configured"
    end
    local payload, eerr = util.safe_encode(self.json, data)
    if not payload then
        return nil, "encode failed: " .. tostring(eerr)
    end
    return write_file(self.fs, self:path(session_filename(id)), payload)
end

function MemoryStore:load_session(id)
    if not self.json then
        return nil, "json library not configured"
    end
    local raw, rerr = read_file(self.fs, self:path(session_filename(id)))
    if not raw then return nil, rerr end
    local data, derr = util.safe_decode(self.json, raw)
    if not data then return nil, "decode failed: " .. tostring(derr) end
    return data, nil
end

-- ============================================================
-- Skills
-- ============================================================
-- A "skill" is a markdown file describing a focused capability the agent
-- should be aware of (e.g. "writing PRs", "debugging Python"). When loaded,
-- its content is appended to the system prompt under a "# Skill: <name>"
-- header so the model picks it up.
--
-- Resolution order for a skill named "<name>":
--   1. <workspace>/SKILL.<name>.md      (flat layout, default)
--   2. <workspace>/skills/<name>/SKILL.md  (folder layout, if user pre-created)
--
-- We do not create skill files automatically — pure Lua cannot create
-- directories portably. Users put the files there themselves.

-- Read the content of a single named skill. Returns "" when missing.
function MemoryStore:read_skill(name)
    if type(name) ~= "string" or name == "" then
        return ""
    end
    -- Try flat layout first.
    local flat = self:path("SKILL." .. name .. ".md")
    local content = read_file(self.fs, flat)
    if content and content ~= "" then return content end
    -- Try folder layout.
    local folded = self:path("skills/" .. name .. "/SKILL.md")
    content = read_file(self.fs, folded)
    return content or ""
end

-- Check whether a skill exists in either layout.
function MemoryStore:has_skill(name)
    if type(name) ~= "string" or name == "" then return false end
    local flat = self:path("SKILL." .. name .. ".md")
    if read_file(self.fs, flat) then return true end
    local folded = self:path("skills/" .. name .. "/SKILL.md")
    if read_file(self.fs, folded) then return true end
    return false
end

-- Create or overwrite a skill file. Always uses flat layout
-- (since we can't create the folded layout's directory).
function MemoryStore:write_skill(name, content)
    if type(name) ~= "string" or name == "" then
        return nil, "skill name required"
    end
    return write_file(self.fs, self:path("SKILL." .. name .. ".md"), content or "")
end

-- Read multiple named skills at once. Returns concatenated string ready to
-- splice into the system prompt. Skills missing from disk are silently skipped.
function MemoryStore:read_skills(names)
    if type(names) ~= "table" or #names == 0 then return "" end
    local parts = {}
    for i = 1, #names do
        local name = names[i]
        local content = self:read_skill(name)
        if content ~= "" then
            parts[#parts + 1] = "# Skill: " .. name .. "\n\n" .. content
        end
    end
    return table.concat(parts, "\n\n")
end

return M
