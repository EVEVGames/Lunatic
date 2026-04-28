-- lunatic/init.lua
-- Lunatic: ultra-lightweight pure-Lua AI agent loop.
--
-- Inspired by HKUDS/nanobot's agent module but stripped to a small,
-- embeddable library: no channels, no CLI, no MCP, no skills system.
-- Only the loop, memory, tools, autocompact, and subagents.
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util       = require("lunatic.util")
local log_lib    = require("lunatic.log")
local provider_m = require("lunatic.provider")
local Memory     = require("lunatic.memory")
local Context    = require("lunatic.context")
local Tools      = require("lunatic.tools")
local Loop       = require("lunatic.loop")
local Subagent   = require("lunatic.subagent")
local Runner     = require("lunatic.runner")

local M = {}
M.version = "0.1.0"

local Lunatic = {}
Lunatic.__index = Lunatic
M.Lunatic = Lunatic
M.Runner = Runner

-- Expose provider registry so users can register custom adapters.
function M.register_provider(name, factory_or_adapter)
    return provider_m.register(name, factory_or_adapter)
end

-- Default HTTP / JSON loaders. We try to require sensible defaults; failures
-- here are not fatal — the user can pass their own implementation in config.
local function default_http()
    local ok, https = pcall(require, "ssl.https")
    if ok and type(https) == "table" then
        return https
    end
    return nil
end

local function default_json()
    local ok, j = pcall(require, "json")
    if ok and type(j) == "table" then
        return j
    end
    -- Some distributions expose dkjson under "dkjson".
    local ok2, j2 = pcall(require, "dkjson")
    if ok2 and type(j2) == "table" then
        return j2
    end
    return nil
end

local function default_fs()
    -- Wrap io.open into a small fs object so tests can swap it out.
    return {
        open = function(path, mode)
            return io.open(path, mode)
        end,
    }
end

-- Default tools that ship with Lunatic. Each one is registered as a function
-- handler so they have access to the ctx (which carries http/json/fs/memory).
-- Users can disable them all via builtin_tools = false, or remove individually
-- via :unregister_tool(name).
local function install_builtin_tools(self)
    local function read_file_handler(args, ctx)
        if type(args) ~= "table" or type(args.path) ~= "string" then
            return nil, "path (string) is required"
        end
        if not ctx or not ctx.fs or type(ctx.fs.open) ~= "function" then
            return nil, "filesystem unavailable"
        end
        local fh, oerr = ctx.fs.open(args.path, "rb")
        if not fh then return nil, "open failed: " .. tostring(oerr) end
        local ok, content = pcall(function()
            local c = fh:read("*a"); fh:close(); return c
        end)
        if not ok then
            pcall(function() fh:close() end)
            return nil, "read failed"
        end
        return content
    end

    local function write_file_handler(args, ctx)
        if type(args) ~= "table" or type(args.path) ~= "string" or
            type(args.content) ~= "string" then
            return nil, "path and content (strings) are required"
        end
        if not ctx or not ctx.fs or type(ctx.fs.open) ~= "function" then
            return nil, "filesystem unavailable"
        end
        local fh, oerr = ctx.fs.open(args.path, "wb")
        if not fh then return nil, "open failed: " .. tostring(oerr) end
        local ok = pcall(function()
            fh:write(args.content); fh:close()
        end)
        if not ok then
            pcall(function() fh:close() end)
            return nil, "write failed"
        end
        return "wrote " .. tostring(#args.content) .. " bytes to " .. args.path
    end

    local function edit_file_handler(args, ctx)
        if type(args) ~= "table" or type(args.path) ~= "string" or
            type(args.search) ~= "string" or type(args.replace) ~= "string" then
            return nil, "path, search, replace (all strings) are required"
        end
        if not ctx or not ctx.fs or type(ctx.fs.open) ~= "function" then
            return nil, "filesystem unavailable"
        end
        local fh, oerr = ctx.fs.open(args.path, "rb")
        if not fh then return nil, "open failed: " .. tostring(oerr) end
        local content
        local ok = pcall(function() content = fh:read("*a"); fh:close() end)
        if not ok then return nil, "read failed" end
        if not content:find(args.search, 1, true) then
            return nil, "search string not found in file"
        end
        local new_content = content:gsub(args.search:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"),
            args.replace:gsub("%%", "%%%%"))
        local fh2, oerr2 = ctx.fs.open(args.path, "wb")
        if not fh2 then return nil, "reopen failed: " .. tostring(oerr2) end
        local ok2 = pcall(function() fh2:write(new_content); fh2:close() end)
        if not ok2 then return nil, "write failed" end
        return "edited " .. args.path
    end

    local function list_dir_handler(args, ctx)
        if type(args) ~= "table" then args = {} end
        local path = args.path or "."
        -- Pure Lua has no portable directory listing. We rely on io.popen if
        -- available. If not, return a clear error.
        if not io.popen then
            return nil, "io.popen unavailable; cannot list directory"
        end
        local sep = package.config:sub(1, 1)
        local cmd
        if sep == "\\" then
            cmd = string.format('dir /b "%s"', path:gsub('"', ''))
        else
            cmd = string.format('ls -1 "%s"', path:gsub('"', ''))
        end
        local pipe, perr = io.popen(cmd, "r")
        if not pipe then return nil, "popen failed: " .. tostring(perr) end
        local out = {}
        for line in pipe:lines() do
            out[#out + 1] = line
        end
        pipe:close()
        return table.concat(out, "\n")
    end

    local function http_fetch_handler(args, ctx)
        if type(args) ~= "table" or type(args.url) ~= "string" then
            return nil, "url (string) is required"
        end
        if not ctx or not ctx.http then
            return nil, "http library unavailable"
        end
        -- Reuse provider's request shape via a tiny inline call.
        local method = args.method or "GET"
        local headers = args.headers or {}
        local body_in = args.body
        -- Try function shape first.
        if type(ctx.http) == "function" then
            local ok, body, status = pcall(ctx.http,
                { url = args.url, method = method, headers = headers, body = body_in })
            if not ok then return nil, "http error: " .. tostring(body) end
            return body or ""
        end
        if type(ctx.http) == "table" and type(ctx.http.request) == "function" then
            local resp = {}
            local source
            if body_in and #body_in > 0 then
                local sent = false
                source = function()
                    if sent then return nil end
                    sent = true; return body_in
                end
                if not headers["content-length"] and not headers["Content-Length"] then
                    headers["content-length"] = tostring(#body_in)
                end
            end
            local ok, code = pcall(ctx.http.request, {
                url = args.url, method = method, headers = headers, source = source,
                sink = function(chunk) if chunk then resp[#resp + 1] = chunk end; return 1 end,
            })
            if not ok then return nil, "http error: " .. tostring(code) end
            return table.concat(resp)
        end
        return nil, "http library has unsupported shape"
    end

    local function save_memory_handler(args, ctx)
        if type(args) ~= "table" or type(args.fact) ~= "string" or args.fact == "" then
            return nil, "fact (non-empty string) is required"
        end
        if not ctx or not ctx.memory then
            return nil, "memory store unavailable"
        end
        local ok, err = ctx.memory:append_fact(args.fact)
        if not ok then return nil, err end
        return "saved fact"
    end

    local function recall_memory_handler(args, ctx)
        if not ctx or not ctx.memory then
            return nil, "memory store unavailable"
        end
        local content = ctx.memory:read_facts()
        return content or ""
    end

    -- The load_skill built-in lets the LLM lazy-load a skill it discovered in
    -- the available_skills catalog. We read the body from disk, mark the
    -- skill as loaded on the agent's context (so subsequent system prompts
    -- include the body), and return the content as the tool result so the
    -- model has it available immediately too.
    local function load_skill_handler(args, ctx)
        if type(args) ~= "table" or type(args.name) ~= "string" or args.name == "" then
            return nil, "name (string) is required"
        end
        if not ctx or not ctx.memory then
            return nil, "memory store unavailable"
        end
        if not ctx.memory:has_skill(args.name) then
            return nil, "skill not found: " .. args.name
        end
        local body = ctx.memory:read_skill(args.name)
        if body == "" then
            return nil, "skill is empty: " .. args.name
        end
        -- Mark the skill as loaded on the agent's context so future system
        -- prompts include it. We access the agent through ctx.agent.
        if ctx.agent and ctx.agent.context and ctx.agent.context.add_skill then
            ctx.agent.context:add_skill(args.name)
        end
        return body
    end

    local function spawn_subagent_handler(args, ctx)
        -- Real dispatch is handled inline by the loop (it short-circuits to
        -- self.subagent_manager:run_tool). This handler is only reached if a
        -- user constructs a Lunatic without a subagent manager attached.
        return nil, "subagent manager not initialised"
    end

    self.tools:register({
        name = "read_file",
        description = "Read the contents of a text file from the local filesystem.",
        parameters = {
            type = "object",
            properties = { path = { type = "string", description = "File path" } },
            required = { "path" },
        },
    }, read_file_handler)

    self.tools:register({
        name = "write_file",
        description = "Write content to a file (overwrites existing content).",
        parameters = {
            type = "object",
            properties = {
                path = { type = "string", description = "File path" },
                content = { type = "string", description = "Content to write" },
            },
            required = { "path", "content" },
        },
    }, write_file_handler)

    self.tools:register({
        name = "edit_file",
        description = "Search and replace inside a file (literal match).",
        parameters = {
            type = "object",
            properties = {
                path = { type = "string" },
                search = { type = "string", description = "Literal string to find" },
                replace = { type = "string", description = "Replacement" },
            },
            required = { "path", "search", "replace" },
        },
    }, edit_file_handler)

    self.tools:register({
        name = "list_dir",
        description = "List the contents of a directory.",
        parameters = {
            type = "object",
            properties = { path = { type = "string", description = "Directory path; defaults to ." } },
        },
    }, list_dir_handler)

    self.tools:register({
        name = "http_fetch",
        description = "Perform an HTTP request (GET by default).",
        parameters = {
            type = "object",
            properties = {
                url     = { type = "string" },
                method  = { type = "string" },
                headers = { type = "object" },
                body    = { type = "string" },
            },
            required = { "url" },
        },
    }, http_fetch_handler)

    self.tools:register({
        name = "save_memory",
        description = "Append a durable fact to long-term memory (MEMORY.md).",
        parameters = {
            type = "object",
            properties = { fact = { type = "string" } },
            required = { "fact" },
        },
    }, save_memory_handler)

    self.tools:register({
        name = "recall_memory",
        description = "Read all consolidated long-term facts (MEMORY.md).",
        parameters = { type = "object", properties = {} },
    }, recall_memory_handler)

    -- load_skill is gated behind config.builtin_load_skill (default true).
    -- Some hosts may want to disable lazy skill loading entirely.
    if self._enable_load_skill then
        self.tools:register({
            name = "load_skill",
            description = "Read the body of a named skill from the workspace " ..
                "and add it to the conversation's loaded-skills set so it " ..
                "stays in the system prompt for the rest of the session. " ..
                "Use this when you see a relevant entry in the 'Available " ..
                "skills' catalog and need its full instructions.",
            parameters = {
                type = "object",
                properties = {
                    name = { type = "string",
                             description = "The skill name as listed in the catalog" },
                },
                required = { "name" },
            },
        }, load_skill_handler)
    end

    self.tools:register({
        name = "spawn_subagent",
        description = "Spawn a subagent to handle a focused subtask. Returns the " ..
            "subagent's final answer when it completes. Use this to delegate " ..
            "well-scoped work without polluting the main conversation.",
        parameters = {
            type = "object",
            properties = {
                task = { type = "string", description = "What the subagent should do" },
                tools = {
                    type = "array",
                    items = { type = "string" },
                    description = "Optional whitelist of tool names to grant",
                },
                model = { type = "string", description = "Optional model override" },
                inherit_tools = {
                    type = "boolean",
                    description = "If true and `tools` not given, copy parent's tools",
                },
            },
            required = { "task" },
        },
    }, spawn_subagent_handler)
end

-- Lunatic.new(config)
-- See README in this file for the full config shape. Required: llm.provider.
function M.Lunatic.new(config)
    config = config or {}

    -- Resolve dependencies.
    local http = config.http or default_http()
    local json = config.json or default_json()
    local fs   = config.fs   or default_fs()

    if not json then
        error("Lunatic.new: no json library available; pass config.json or install 'json'")
    end

    -- Build logger.
    local user_log = config.log
    local logger
    if type(user_log) == "function" then
        logger = user_log
    elseif type(user_log) == "table" and user_log.fn then
        logger = user_log.fn
    else
        logger = log_lib.build_default(type(user_log) == "table" and user_log or {})
    end

    -- Build provider.
    local prov, perr = provider_m.build(config.llm or {})
    if not prov then
        error("Lunatic.new: provider build failed: " .. tostring(perr))
    end

    -- Build memory store (workspace path is mandatory-ish; default ./.lunatic/).
    local workspace = config.workspace or "./.lunatic/"
    local memory = Memory.new({
        fs = fs, json = json, workspace = workspace, log = logger,
    })

    -- Build context builder.
    local agent_id = config.agent_id or "main"
    local context = Context.new({
        memory = memory,
        agent_id = agent_id,
        extra_system = config.extra_system,
        history_tail_lines = config.history_tail_lines,
        -- Catalog (lazy) and pre-loaded (eager) skill lists. The LLM sees the
        -- catalog and uses load_skill to pull a body into the prompt.
        available_skills = config.available_skills or {},
        loaded_skills = config.loaded_skills or {},
    })

    -- Build tool registry.
    local tools = Tools.new({ log = logger })

    -- Build the agent loop (subagent_manager wired in below).
    local loop = Loop.new({
        agent_id = agent_id,
        log = logger,
        hooks = config.hooks or {},
        memory = memory,
        context = context,
        tools = tools,
        provider = prov,
        json = json,
        http = http,
        fs = fs,
        max_iterations = config.max_iterations or 20,
        autocompact = config.autocompact,
    })

    local self = setmetatable({
        agent_id = agent_id,
        loop = loop,
        context = context,
        memory = memory,
        tools = tools,
        provider = prov,
        log = logger,
        hooks = config.hooks or {},
        _config = {
            workspace = workspace,
            http = http, json = json, fs = fs,
            llm = config.llm,
            log = logger,
            hooks = config.hooks or {},
            autocompact = config.autocompact,
            max_iterations = config.max_iterations or 20,
        },
    }, Lunatic)

    -- Subagent manager (after self exists so handles can reference parent).
    local subagent_manager = Subagent.new({ parent = self, log = logger })
    self.subagents = subagent_manager
    loop.subagent_manager = subagent_manager

    -- Install built-in tools by default.
    local install_builtins = config.builtin_tools
    if install_builtins == nil then install_builtins = true end

    -- Whether to register the load_skill tool. Defaults to true when builtin
    -- tools are enabled. Hosts can disable to keep skills strictly opt-in
    -- via :add_skill() without exposing a tool to the model.
    local enable_load_skill = config.enable_load_skill
    if enable_load_skill == nil then enable_load_skill = install_builtins end
    self._enable_load_skill = enable_load_skill and true or false

    if install_builtins then
        install_builtin_tools(self)
    end

    return self
end

-- ============================================================
-- Lunatic instance methods
-- ============================================================

-- Run a task synchronously. Pushes the user message and iterates until done.
function Lunatic:run(user_message)
    return self.loop:run(user_message)
end

-- Run one iteration step. Returns the same outcome strings as AgentLoop:step().
function Lunatic:step()
    return self.loop:step()
end

-- Append a message to history. Optional second arg: kind id (loop.MK_*).
function Lunatic:add_message(message, kind)
    return self.loop:add_message(message, kind)
end

-- Tool management facade.
function Lunatic:register_tool(a, b, c)
    return self.tools:register(a, b, c)
end
function Lunatic:unregister_tool(name) return self.tools:unregister(name) end
function Lunatic:has_tool(name)        return self.tools:has(name) end
function Lunatic:get_tool(name)        return self.tools:get(name) end
function Lunatic:list_tools()          return self.tools:list() end
function Lunatic:enable_tool(name)     return self.tools:enable(name) end
function Lunatic:disable_tool(name)    return self.tools:disable(name) end
function Lunatic:clear_tools()         return self.tools:clear() end

-- Manual compact trigger.
function Lunatic:compact() return self.loop:compact() end

-- Cancel the current run cooperatively. Same shape as Runner:cancel().
function Lunatic:cancel() return self.loop:cancel() end

-- Structured conversation view for UIs. See AgentLoop:messages().
function Lunatic:messages(opts) return self.loop:messages(opts) end

-- Annotate a history index with a custom kind id (loop.MK_* constants).
function Lunatic:annotate_message(index, kind_id)
    return self.loop:annotate(index, kind_id)
end

-- Skills facade. Skills are markdown files in the workspace named
-- "SKILL.<n>.md" (or "skills/<n>/SKILL.md" if the user pre-created
-- the folder layout).
--
-- Two-tier model:
--   * "available_skills" is a catalog of { name, description } shown to the
--     LLM in the system prompt — listing only, NO body. The LLM decides
--     whether to load one via the load_skill tool.
--   * "loaded_skills" is the list of skill names whose full body is
--     currently injected into the system prompt. The load_skill tool adds
--     to this list; :remove_skill() removes from it.
function Lunatic:set_available_skills(catalog)
    return self.context:set_available_skills(catalog)
end
function Lunatic:add_available_skill(descriptor)
    return self.context:add_available_skill(descriptor)
end
function Lunatic:list_available_skills()
    local out = {}
    for i = 1, #self.context.available_skills do
        out[i] = self.context.available_skills[i]
    end
    return out
end
function Lunatic:add_skill(name)          return self.context:add_skill(name) end
function Lunatic:remove_skill(name)       return self.context:remove_skill(name) end
function Lunatic:set_skills(names)        return self.context:set_skills(names) end
function Lunatic:list_loaded_skills()
    local out = {}
    for i = 1, #self.context.loaded_skills do
        out[i] = self.context.loaded_skills[i]
    end
    return out
end
function Lunatic:has_skill(name)          return self.memory:has_skill(name) end
function Lunatic:read_skill(name)         return self.memory:read_skill(name) end
function Lunatic:write_skill(name, body)  return self.memory:write_skill(name, body) end

-- Session persistence.
function Lunatic:save_session(id)
    if not id then return nil, "id required" end
    local snapshot = {
        agent_id = self.agent_id,
        history = self.loop.history,
        pinned = self.loop.pinned,
        kinds = self.loop.kinds,
        compact_cursor = self.loop.compact_cursor,
        version = M.version,
    }
    return self.memory:save_session(id, snapshot)
end

function Lunatic:load_session(id)
    if not id then return nil, "id required" end
    local data, err = self.memory:load_session(id)
    if not data then return nil, err end
    self.loop.history = data.history or {}
    self.loop.pinned = data.pinned or {}
    self.loop.kinds = data.kinds or {}
    self.loop.compact_cursor = data.compact_cursor or 0
    return true
end

-- Subagent facade.
function Lunatic:spawn_subagent(opts) return self.subagents:spawn(opts) end
function Lunatic:list_subagents()     return self.subagents:list() end
function Lunatic:cancel_subagent(id)  return self.subagents:cancel(id) end
function Lunatic:get_subagent(id)     return self.subagents:get(id) end

-- Reset conversation while keeping tools / memory pointers.
function Lunatic:reset() return self.loop:reset() end

return M
