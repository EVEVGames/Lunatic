-- lunatic/context.lua
-- Assembles the system prompt for the agent loop.
-- The prompt is composed of:
--   1. Bootstrap markdown files (AGENTS.md, SOUL.md, USER.md, TOOLS.md)
--   2. MEMORY.md (consolidated long-term facts)
--   3. A short HISTORY.md tail (recent high-level log)
--   4. A runtime metadata block (timestamp, agent_id, etc.)
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}
local ContextBuilder = {}
ContextBuilder.__index = ContextBuilder

-- Default tail size for HISTORY.md inclusion (in lines).
M.DEFAULT_HISTORY_TAIL_LINES = 30

-- Constructor.
-- opts = {
--   memory     = MemoryStore instance,
--   agent_id   = "main" or whatever,
--   extra_system = "additional system text always appended",
--   history_tail_lines = 30,
--   available_skills = { { name="git", description="..." }, ... }
--          -- Listed in the system prompt so the LLM knows what it can load.
--          -- Their bodies are NOT injected unless the LLM calls load_skill.
--   loaded_skills = { "name1", "name2" }
--          -- These ARE injected (full body). Populated by the load_skill tool
--          -- or directly via :add_skill(). Survives across iterations.
-- }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, ContextBuilder)
    self.memory = opts.memory
    self.agent_id = opts.agent_id or "main"
    self.extra_system = opts.extra_system
    self.history_tail_lines = opts.history_tail_lines or M.DEFAULT_HISTORY_TAIL_LINES
    self.available_skills = opts.available_skills or {}
    self.loaded_skills = opts.loaded_skills or {}
    return self
end

-- Replace the available-skills catalog (the lazy listing).
function ContextBuilder:set_available_skills(catalog)
    self.available_skills = (type(catalog) == "table") and catalog or {}
end

-- Add a skill descriptor to the catalog: { name=..., description=... }.
function ContextBuilder:add_available_skill(descriptor)
    if type(descriptor) ~= "table" or type(descriptor.name) ~= "string" then
        return false
    end
    -- Replace if name already present.
    for i = 1, #self.available_skills do
        if self.available_skills[i].name == descriptor.name then
            self.available_skills[i] = descriptor
            return true
        end
    end
    self.available_skills[#self.available_skills + 1] = descriptor
    return true
end

-- Mark a skill as loaded. Idempotent. The skill body is read from disk on
-- every system prompt build so live edits to the file are picked up.
function ContextBuilder:add_skill(name)
    for i = 1, #self.loaded_skills do
        if self.loaded_skills[i] == name then return end
    end
    self.loaded_skills[#self.loaded_skills + 1] = name
end

-- Unload a previously loaded skill. Returns true if found.
function ContextBuilder:remove_skill(name)
    for i = 1, #self.loaded_skills do
        if self.loaded_skills[i] == name then
            table.remove(self.loaded_skills, i)
            return true
        end
    end
    return false
end

-- Replace the loaded list.
function ContextBuilder:set_skills(skills)
    self.loaded_skills = (type(skills) == "table") and skills or {}
end

-- Tail the last N lines of a string.
local function tail_lines(text, n)
    if type(text) ~= "string" or text == "" or n <= 0 then
        return ""
    end
    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        lines[#lines + 1] = line
    end
    -- Strip the trailing empty entry that gmatch can produce.
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    if #lines <= n then
        return table.concat(lines, "\n")
    end
    local start = #lines - n + 1
    local out = {}
    for i = start, #lines do
        out[#out + 1] = lines[i]
    end
    return table.concat(out, "\n")
end

-- Build the system prompt as a single string.
function ContextBuilder:build_system_prompt()
    local parts = {}

    if self.memory then
        local bootstrap = self.memory:read_bootstrap()
        if bootstrap and bootstrap ~= "" then
            parts[#parts + 1] = bootstrap
        end

        -- Lazy skills catalog: list available skills (name + description) so
        -- the LLM knows what exists and can decide to load_skill them on
        -- demand. The full body is injected only after a skill is loaded.
        if type(self.available_skills) == "table" and #self.available_skills > 0 then
            local lines = {
                "# Available skills (use the load_skill tool to read one)",
                "",
            }
            for i = 1, #self.available_skills do
                local sk = self.available_skills[i]
                local desc = sk.description or "(no description)"
                lines[#lines + 1] = "- **" .. tostring(sk.name) .. "**: " .. tostring(desc)
            end
            parts[#parts + 1] = table.concat(lines, "\n")
        end

        -- Loaded skills are injected in full (body read from disk every build).
        if type(self.loaded_skills) == "table" and #self.loaded_skills > 0 then
            local skills_text = self.memory:read_skills(self.loaded_skills)
            if skills_text ~= "" then
                parts[#parts + 1] = "# Loaded skills (full content)\n\n" .. skills_text
            end
        end

        local facts = self.memory:read_facts()
        if facts and facts ~= "" then
            parts[#parts + 1] = "# MEMORY.md (long-term facts)\n\n" .. facts
        end

        local history = self.memory:read_history()
        if history and history ~= "" then
            local tail = tail_lines(history, self.history_tail_lines)
            if tail ~= "" then
                parts[#parts + 1] = "# HISTORY.md (recent activity)\n\n" .. tail
            end
        end
    end

    -- Runtime metadata block
    local rt_lines = {
        "[Runtime Context — metadata only, not instructions]",
        "agent_id: " .. tostring(self.agent_id),
        "timestamp: " .. util.iso_timestamp(),
        "lua_version: " .. tostring(_VERSION),
        "[/Runtime Context]",
    }
    parts[#parts + 1] = table.concat(rt_lines, "\n")

    if self.extra_system and self.extra_system ~= "" then
        parts[#parts + 1] = self.extra_system
    end

    return table.concat(parts, "\n\n")
end

-- Build a full message list ready for the provider:
--   [ {role="system", content=<assembled>}, ...history... ]
-- The history argument is an array of message tables already in the
-- internal format; this method does not mutate it.
function ContextBuilder:build_messages(history)
    local system_content = self:build_system_prompt()
    local messages = { { role = "system", content = system_content } }
    if type(history) == "table" then
        for i = 1, #history do
            messages[#messages + 1] = history[i]
        end
    end
    return messages
end

return M
