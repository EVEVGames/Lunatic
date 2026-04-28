-- lunatic/subagent.lua
-- Spawns child Lunatic agents inside coroutines.
--
-- Two primary entry points:
--   :spawn(opts)        -> returns a handle with :run/:next/:is_ready/:result/:status
--   :run_tool(args, parent_loop)
--                       -> called by the spawn_subagent built-in tool. Creates
--                          the subagent and drives it cooperatively to completion.
--                          If multiple subagents are pending in the same parent
--                          turn, callers can use :run_pool() instead.
--
-- A subagent is a freshly constructed Lunatic instance reusing the parent's
-- deps (http/json/fs/provider/log/hooks). It has its own AgentLoop, its own
-- workspace memory pointer, and its own tool registry (whitelisted from
-- parent). The result returned to the parent is the assistant final message
-- text (or an error string).
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}
local SubagentManager = {}
SubagentManager.__index = SubagentManager

local Subagent = {}
Subagent.__index = Subagent

-- ============================================================
-- Subagent handle
-- ============================================================

local function build_subagent_loop(parent, opts)
    -- Lazily require Lunatic to avoid circular dependency at load time.
    local Lunatic = require("lunatic.init").Lunatic

    -- Inherit configuration from the parent, then layer overrides.
    local sub_config = {
        workspace      = opts.workspace or parent._config.workspace,
        http           = parent._config.http,
        json           = parent._config.json,
        fs             = parent._config.fs,
        llm            = util.deep_merge(parent._config.llm, opts.llm or {}),
        builtin_tools  = (opts.builtin_tools ~= nil) and opts.builtin_tools or false,
        autocompact    = util.deep_merge(parent._config.autocompact or {}, opts.autocompact or {}),
        log            = parent._config.log,
        hooks          = util.deep_merge(parent._config.hooks or {}, opts.hooks or {}),
        max_iterations = opts.max_iterations or parent._config.max_iterations,
        agent_id       = opts.agent_id,
    }
    local sub = Lunatic.new(sub_config)

    -- If parent passed a tool whitelist, copy those tools from parent registry.
    if type(opts.tools) == "table" then
        for i = 1, #opts.tools do
            local name = opts.tools[i]
            local entry = parent.tools:get(name)
            if entry then
                sub.tools:register(entry.spec, entry.handler)
            end
        end
    elseif opts.inherit_tools then
        local names = parent.tools:names()
        for i = 1, #names do
            local entry = parent.tools:get(names[i])
            if entry and names[i] ~= "spawn_subagent" then
                -- Don't grant nested spawning by default.
                sub.tools:register(entry.spec, entry.handler)
            end
        end
    end

    return sub
end

local function new_handle(parent, opts)
    local self = setmetatable({}, Subagent)
    opts = opts or {}
    self.id = opts.id or util.gen_id("sub")
    self.parent = parent
    self.task = opts.task or ""
    self.opts = opts
    self.status_value = "idle"
    self.result_text = nil
    self.error_text = nil
    self.lunatic = nil       -- created lazily on first next()
    self.co = nil            -- coroutine for the agent run
    self.last_yield = nil
    -- Tool call id from the parent's tool_call that spawned us, if any.
    -- Set by SubagentManager:run_tool() so a UI can later correlate a
    -- subagent transcript with the parent's tool_call entry.
    self.parent_call_id = opts.parent_call_id
    return self
end

function Subagent:_init_if_needed()
    if self.lunatic then return end
    self.lunatic = build_subagent_loop(self.parent, self.opts)
    -- Tag agent_id of the underlying loop with our id for nicer logs.
    self.lunatic.loop.agent_id = self.parent.agent_id .. ":sub:" .. self.id
    self.lunatic.context.agent_id = self.lunatic.loop.agent_id
    -- Build the coroutine that runs the loop.
    local task = self.task
    self.co = coroutine.create(function()
        self.lunatic.loop._inside_coroutine = true
        local final, err = self.lunatic.loop:run(task)
        self.lunatic.loop._inside_coroutine = false
        if err then
            return "error", err
        end
        local text = (type(final) == "table" and final.content) or ""
        return "ok", text
    end)
    self.status_value = "running"
end

-- Advance the subagent by one yield-step. Returns false if still working,
-- true if finished. Sets self.result_text / self.error_text on completion.
-- Naming mirrors Runner:next() so callers can use a uniform convention
-- across main agents and subagents.
function Subagent:next()
    if self.status_value == "done" or self.status_value == "error" then
        return true
    end
    self:_init_if_needed()

    if not self.co then return true end
    if coroutine.status(self.co) == "dead" then
        self.status_value = self.error_text and "error" or "done"
        return true
    end

    local resumed = { coroutine.resume(self.co) }
    local ok = resumed[1]
    if not ok then
        self.error_text = "subagent crashed: " .. tostring(resumed[2])
        self.status_value = "error"
        return true
    end

    if coroutine.status(self.co) == "dead" then
        -- Coroutine finished. Returns are at indices 2..n.
        local kind = resumed[2]
        local payload = resumed[3]
        if kind == "ok" then
            self.result_text = payload or ""
            self.status_value = "done"
        elseif kind == "error" then
            self.error_text = payload or "subagent error"
            self.status_value = "error"
        else
            -- Coroutine returned without our convention; treat as ok with concat.
            self.result_text = tostring(kind or "")
            self.status_value = "done"
        end
        return true
    end

    -- Still alive; resumed[2..] is the yield payload (stage, data).
    self.last_yield = { stage = resumed[2], data = resumed[3] }
    return false
end

function Subagent:is_ready()
    return self.status_value == "done" or self.status_value == "error"
end

function Subagent:result()
    if self.status_value == "error" then
        return nil, self.error_text
    end
    return self.result_text, nil
end

-- The subagent's own status string. Mirrors Runner:status().
function Subagent:status()
    return self.status_value
end

function Subagent:run()
    while not self:is_ready() do
        self:next()
    end
    return self:result()
end

-- Cancel the subagent. Cannot truly kill a coroutine in standard Lua, but we
-- mark it so the manager stops scheduling and is_ready returns true.
-- Symmetric with Runner:cancel().
function Subagent:cancel()
    if self.status_value ~= "done" and self.status_value ~= "error" then
        self.error_text = "cancelled"
        self.status_value = "error"
    end
    return true
end

-- Expose the underlying loop's structured messages so a UI can render the
-- subagent's transcript. Returns the same shape as Lunatic:messages().
function Subagent:messages(opts)
    if self.lunatic and self.lunatic.loop then
        return self.lunatic.loop:messages(opts)
    end
    return {}
end

-- ============================================================
-- SubagentManager
-- ============================================================

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, SubagentManager)
    self.parent = opts.parent       -- the Lunatic instance that owns us
    self.log = opts.log or function() end
    self._handles = {}              -- id -> Subagent
    return self
end

-- Create a new handle (does not start running; first :next() boots the coroutine).
function SubagentManager:spawn(opts)
    opts = opts or {}
    local handle = new_handle(self.parent, opts)
    self._handles[handle.id] = handle
    self.log("info", "subagent_spawn", {
        agent_id = self.parent.agent_id, sub_id = handle.id, task = handle.task,
    })
    if type(self.parent.hooks) == "table" and self.parent.hooks.on_subagent_spawn then
        local ok, err = pcall(self.parent.hooks.on_subagent_spawn, {
            id = handle.id, task = handle.task, agent_id = self.parent.agent_id,
        })
        if not ok then
            self.log("warn", "hook_error", { hook = "on_subagent_spawn", err = tostring(err) })
        end
    end
    return handle
end

function SubagentManager:list()
    local out = {}
    for id, h in pairs(self._handles) do
        out[#out + 1] = {
            id = id,
            status = h.status_value,
            task = h.task,
            parent_call_id = h.parent_call_id,
        }
    end
    return out
end

function SubagentManager:get(id)
    return self._handles[id]
end

-- Find the subagent that was spawned by a particular parent tool_call id.
-- Used by AgentLoop:messages() to embed the subagent transcript next to the
-- parent's tool_call entry so a UI can render them together.
function SubagentManager:find_by_call_id(call_id)
    if not call_id then return nil end
    for _, h in pairs(self._handles) do
        if h.parent_call_id == call_id then return h end
    end
    return nil
end

-- Cancel a subagent by id. Mirrors Lunatic:cancel().
function SubagentManager:cancel(id)
    local h = self._handles[id]
    if not h then return false end
    h:cancel()
    return true
end

-- Helper: yield from the calling coroutine if we are inside one. Lua 5.1
-- cannot yield across a pcall, so we never wrap yield in pcall.
local function safe_yield(stage, data)
    if coroutine.isyieldable then
        if not coroutine.isyieldable() then return end
        coroutine.yield(stage, data)
        return
    end
    -- 5.1 / LuaJIT: there is no isyieldable check. The manager is invoked
    -- from inside the main agent's coroutine in normal use, so yielding is
    -- expected to work. If a host calls run_one() outside a coroutine
    -- (rare), the caller already opted into blocking; we skip the yield
    -- by checking coroutine.running().
    if coroutine.running then
        local co = coroutine.running()
        -- In 5.1, coroutine.running() returns nil from the main thread.
        if co == nil then return end
    end
    coroutine.yield(stage, data)
end

-- Drive a single subagent to completion cooperatively. This is what the
-- spawn_subagent built-in tool calls. While waiting for the subagent's
-- coroutine to advance, we yield from the parent's coroutine too — so if the
-- parent itself has siblings being driven by a Runner, they can interleave.
function SubagentManager:run_one(handle)
    while not handle:is_ready() do
        handle:next()
        safe_yield("subagent_progress", { id = handle.id })
    end
    if type(self.parent.hooks) == "table" and self.parent.hooks.on_subagent_done then
        local payload = { id = handle.id, status = handle.status_value,
            result = handle.result_text, err = handle.error_text,
            agent_id = self.parent.agent_id }
        pcall(self.parent.hooks.on_subagent_done, payload)
    end
    self.log("info", "subagent_done", {
        agent_id = self.parent.agent_id, sub_id = handle.id, status = handle.status_value,
    })
    if handle.status_value == "error" then
        return nil, handle.error_text
    end
    return handle.result_text, nil
end

-- Drive multiple subagents in round-robin until all finish. Returns array of results.
function SubagentManager:run_pool(handles)
    local pending = {}
    for i = 1, #handles do pending[i] = handles[i] end

    while #pending > 0 do
        local still = {}
        for i = 1, #pending do
            local h = pending[i]
            h:next()
            if not h:is_ready() then
                still[#still + 1] = h
            end
        end
        pending = still
        if #pending > 0 then
            safe_yield("subagent_pool_round", { remaining = #pending })
        end
    end

    local results = {}
    for i = 1, #handles do
        local h = handles[i]
        results[i] = {
            id = h.id,
            status = h.status_value,
            result = h.result_text,
            err = h.error_text,
        }
    end
    return results
end

-- Tool entrypoint: invoked when the agent calls the spawn_subagent tool.
-- args = { task = "...", tools = {...}?, model = "..."?, inherit_tools = bool? }
-- parent_call_id is passed by AgentLoop so we can later correlate the
-- subagent transcript with its originating tool_call in a UI.
function SubagentManager:run_tool(args, parent_loop, parent_call_id)
    if type(args) ~= "table" or type(args.task) ~= "string" or args.task == "" then
        return nil, "spawn_subagent requires args.task (string)"
    end
    local spawn_opts = {
        task = args.task,
        tools = args.tools,
        inherit_tools = args.inherit_tools,
        builtin_tools = (args.builtin_tools ~= nil) and args.builtin_tools or false,
        llm = args.model and { model = args.model } or nil,
        max_iterations = args.max_iterations,
        parent_call_id = parent_call_id,
    }
    local handle = self:spawn(spawn_opts)
    local result, err = self:run_one(handle)
    if err then
        return "[subagent " .. handle.id .. " failed]: " .. tostring(err), nil
    end
    return "[subagent " .. handle.id .. " result]:\n" .. tostring(result or ""), nil
end

return M
