-- lunatic/loop.lua
-- AgentLoop: the core ReAct iteration.
--
-- Iteration shape:
--   1. Build context (system prompt + history) via ContextBuilder.
--   2. yield "before_llm"
--   3. Call provider.chat → response.
--   4. yield "after_llm"
--   5. If response has tool_calls:
--        for each tool call:
--          yield "before_tool"
--          dispatch via ToolRegistry (or spawn subagent if name == spawn tool)
--          append tool_result to history
--          yield "after_tool"
--      then loop back to step 1.
--      If autocompact threshold tripped, run :compact() (which yields too).
--   6. Else (final answer) → mark done, return.
--
-- The loop is run inside a coroutine by Runner / Subagent. The yield calls
-- give external code (Runner:next, etc.) a chance to interleave with other
-- agents. Inside the loop body itself (not external), we never call
-- coroutine.yield from C boundaries; we only yield from clean Lua frames.
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}
local AgentLoop = {}
AgentLoop.__index = AgentLoop

-- Message-kind tags. Stored as small integers in self.kinds[i] (parallel to
-- self.pinned) so a UI can distinguish how each history slot should render.
-- A nil entry is treated as MK_USER_TEXT or MK_ASSISTANT_TEXT depending on
-- the underlying message.role (the convention: nil == "plain text turn").
M.MK_USER_TEXT       = 1   -- a plain user message
M.MK_ASSISTANT_TEXT  = 2   -- a plain assistant text answer
M.MK_TOOL_CALL       = 3   -- assistant message that issued tool_calls
M.MK_TOOL_RESULT     = 4   -- tool message holding a tool result
M.MK_SYSTEM          = 5   -- ad-hoc system message
M.MK_COMPACT_SUMMARY = 6   -- system message produced by autocompact
M.MK_SUBAGENT_CALL   = 7   -- assistant tool_call that invokes spawn_subagent
M.MK_SUBAGENT_RESULT = 8   -- tool message holding a subagent's final answer
M.MK_PINNED_NOTE     = 9   -- arbitrary pinned annotation set by the host

-- Reverse map for :messages() output (string is friendlier for UI clients).
local KIND_NAME = {
    [M.MK_USER_TEXT]       = "user_text",
    [M.MK_ASSISTANT_TEXT]  = "assistant_text",
    [M.MK_TOOL_CALL]       = "tool_call",
    [M.MK_TOOL_RESULT]     = "tool_result",
    [M.MK_SYSTEM]          = "system",
    [M.MK_COMPACT_SUMMARY] = "compact_summary",
    [M.MK_SUBAGENT_CALL]   = "subagent_call",
    [M.MK_SUBAGENT_RESULT] = "subagent_result",
    [M.MK_PINNED_NOTE]     = "pinned_note",
}
M.KIND_NAME = KIND_NAME

-- Default autocompact configuration.
local DEFAULT_AUTOCOMPACT = {
    enabled       = true,
    max_tokens    = 8000,    -- estimated; triggers when history exceeds this
    max_messages  = 100,     -- alternative trigger by count
    keep_last     = 10,      -- always keep the last K messages verbatim
    persist       = true,    -- append summary to MEMORY.md
    summary_model = nil,     -- optional override for compaction call
}

-- Constructor.
-- opts = {
--   agent_id, log, hooks,
--   memory, context, tools, provider,
--   json, http, fs,
--   max_iterations,
--   autocompact = { ... },
--   subagent_manager,           -- SubagentManager instance (optional)
--   on_yield,                   -- internal: function(stage, data) called before coroutine.yield
-- }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, AgentLoop)
    self.agent_id = opts.agent_id or "main"
    self.log = opts.log or function() end
    self.hooks = opts.hooks or {}
    self.memory = opts.memory
    self.context = opts.context
    self.tools = opts.tools
    self.provider = opts.provider
    self.json = opts.json
    self.http = opts.http
    self.fs = opts.fs
    self.max_iterations = opts.max_iterations or 20
    self.autocompact = util.deep_merge(DEFAULT_AUTOCOMPACT, opts.autocompact or {})
    self.subagent_manager = opts.subagent_manager

    -- Runtime state
    self.history = {}        -- ordered list of message tables (excluding system)
    self.pinned = {}         -- set of indexes that should never be compacted
    self.kinds = {}           -- index -> integer MK_* tag (UI hint, persisted)
    self.compact_cursor = 0  -- last index covered by a compaction summary
    self.iteration = 0
    self.status = "idle"     -- idle | running | awaiting_tool | compacting | done | error
    self.last_error = nil
    self.final_message = nil

    -- Whether we're inside a coroutine (set by Runner before resuming).
    self._inside_coroutine = false

    return self
end

-- Fire a hook safely. `name` is the hook key; payload table is passed through.
function AgentLoop:fire(name, payload)
    local hook = self.hooks[name]
    if type(hook) ~= "function" then return end
    payload = payload or {}
    payload.agent_id = payload.agent_id or self.agent_id
    local ok, err = pcall(hook, payload)
    if not ok then
        self.log("warn", "hook_error", { hook = name, err = tostring(err), agent_id = self.agent_id })
    end
end

-- Yield helper.
--
-- Lua 5.1 / LuaJIT cannot yield across a C boundary, which means
-- pcall(coroutine.yield, ...) errors out instead of yielding. We can't rely
-- on pcall here. Instead we use the self._inside_coroutine flag (set by
-- Runner / Subagent before resuming) plus, on 5.2+, coroutine.isyieldable()
-- as belt-and-braces. When neither indicates safe yielding, we just return.
function AgentLoop:_yield(stage, data)
    if not self._inside_coroutine then return end
    -- 5.2+ has coroutine.isyieldable; if it's available and says no, bail.
    if coroutine.isyieldable and not coroutine.isyieldable() then
        return
    end
    coroutine.yield(stage, data)
end

-- Infer a default kind from a message's role/shape. Used when add_message is
-- called without an explicit kind argument.
local function infer_kind(message)
    local role = message.role
    if role == "user" then return M.MK_USER_TEXT
    elseif role == "assistant" then
        if type(message.tool_calls) == "table" and #message.tool_calls > 0 then
            -- Detect spawn_subagent call to use the more specific kind.
            for i = 1, #message.tool_calls do
                local tc = message.tool_calls[i]
                local fn = tc and tc["function"] or {}
                if fn.name == "spawn_subagent" or tc.name == "spawn_subagent" then
                    return M.MK_SUBAGENT_CALL
                end
            end
            return M.MK_TOOL_CALL
        end
        return M.MK_ASSISTANT_TEXT
    elseif role == "tool" then
        if message.name == "spawn_subagent" then
            return M.MK_SUBAGENT_RESULT
        end
        return M.MK_TOOL_RESULT
    elseif role == "system" then
        return M.MK_SYSTEM
    end
    return nil
end

-- Add a message to history. Optional `kind` overrides automatic inference.
-- Returns the index it was inserted at.
function AgentLoop:add_message(message, kind)
    if type(message) ~= "table" then
        return nil, "message must be a table"
    end
    if type(message.role) ~= "string" then
        return nil, "message.role required"
    end
    self.history[#self.history + 1] = message
    local idx = #self.history
    self.kinds[idx] = kind or infer_kind(message)
    self:fire("on_message", { message = message, index = idx, kind = self.kinds[idx] })
    return idx
end

-- Pin a message index so autocompact never collapses it.
function AgentLoop:pin(index)
    if type(index) == "number" and self.history[index] then
        self.pinned[index] = true
        return true
    end
    return false
end

-- Build provider request from current history.
local function build_request(self)
    local messages = self.context:build_messages(self.history)
    local req = {
        messages = messages,
        tools = (self.tools and #self.tools:list() > 0) and self.tools:list() or nil,
        model = self.provider.model,
        temperature = self.provider.temperature,
        max_tokens = self.provider.max_tokens,
        top_p = self.provider.top_p,
        stream = false,
    }
    return req
end

-- Convert a provider response back into a message table to append to history.
-- For OpenAI-shape: assistant message with optional tool_calls list.
local function response_to_message(resp)
    local msg = { role = "assistant", content = resp.content }
    if resp.tool_calls and #resp.tool_calls > 0 then
        local tcs = {}
        for i = 1, #resp.tool_calls do
            local tc = resp.tool_calls[i]
            tcs[i] = {
                id = tc.id,
                type = "function",
                ["function"] = {
                    name = tc.name,
                    -- Preserve raw string if present so providers can replay.
                    arguments = tc.arguments_raw or tc.arguments or "",
                },
            }
        end
        msg.tool_calls = tcs
    end
    return msg
end

-- Check if autocompact should trip.
local function should_compact(self)
    local ac = self.autocompact
    if not ac.enabled then return false end
    if #self.history > (ac.max_messages or 0) and ac.max_messages > 0 then
        return true
    end
    local toks = util.estimate_messages_tokens(self.history)
    if ac.max_tokens > 0 and toks >= ac.max_tokens then
        return true
    end
    return false
end

-- Run autocompact: summarise old history into a single system message.
function AgentLoop:compact()
    self.status = "compacting"
    self:fire("on_compact_start", {
        history_size = #self.history,
        estimated_tokens = util.estimate_messages_tokens(self.history),
    })
    self.log("info", "compact_start", {
        agent_id = self.agent_id,
        history_size = #self.history,
        cursor = self.compact_cursor,
    })

    self:_yield("before_compact", {})

    local ac = self.autocompact
    local keep = ac.keep_last or 10

    -- Decide cut point: everything before (#history - keep) is candidate.
    local cut = #self.history - keep
    if cut <= self.compact_cursor then
        -- Nothing new to compact.
        self.status = "running"
        return true, nil
    end

    -- Collect candidate slice (skipping pinned indices).
    local to_summarise = {}
    for i = self.compact_cursor + 1, cut do
        if not self.pinned[i] then
            to_summarise[#to_summarise + 1] = self.history[i]
        end
    end

    if #to_summarise == 0 then
        self.status = "running"
        return true, nil
    end

    -- Build a compact request to the LLM.
    local sys = "You are a memory consolidation assistant. Summarise the " ..
        "following conversation slice into durable, factual notes. " ..
        "Output a concise markdown bullet list of facts the assistant should " ..
        "remember in future turns. Do not include greetings or chatter."
    local raw_dump = {}
    for i = 1, #to_summarise do
        local m = to_summarise[i]
        raw_dump[#raw_dump + 1] = string.format(
            "[%s] %s",
            m.role,
            (type(m.content) == "string") and m.content or "(structured content)"
        )
    end
    local req = {
        messages = {
            { role = "system", content = sys },
            { role = "user", content = table.concat(raw_dump, "\n") },
        },
        model = ac.summary_model or self.provider.model,
        temperature = 0.2,
        max_tokens = 800,
        stream = false,
    }
    local ctx = { http = self.http, json = self.json, fs = self.fs }

    self:_yield("before_compact_llm", {})
    local resp, err = self.provider:chat(req, ctx)
    self:_yield("after_compact_llm", {})

    if not resp or resp.finish == "error" then
        local emsg = (resp and resp.error) or err or "unknown compact error"
        self:fire("on_compact_error", { err = emsg })
        self.log("warn", "compact_error", { agent_id = self.agent_id, err = emsg })
        self.status = "running"
        return nil, emsg
    end

    local summary = resp.content or ""

    -- Replace the slice in-place with a single system summary marker.
    -- We do this by reconstructing history: [pre-cursor] [summary msg] [post-cut]
    local new_history = {}
    local new_kinds   = {}
    -- Keep everything up to compact_cursor (already-consolidated stuff stays as is).
    for i = 1, self.compact_cursor do
        new_history[#new_history + 1] = self.history[i]
        new_kinds[#new_history]       = self.kinds[i]
    end
    -- Insert summary as a system message.
    new_history[#new_history + 1] = {
        role = "system",
        content = "[memory:consolidated " .. util.iso_timestamp() .. "]\n" .. summary,
    }
    local summary_index = #new_history
    new_kinds[summary_index] = M.MK_COMPACT_SUMMARY
    -- Carry over pinned messages from the slice that we skipped.
    for i = self.compact_cursor + 1, cut do
        if self.pinned[i] then
            new_history[#new_history + 1] = self.history[i]
            new_kinds[#new_history]       = self.kinds[i]
        end
    end
    -- Tail: everything after the cut.
    for i = cut + 1, #self.history do
        new_history[#new_history + 1] = self.history[i]
        new_kinds[#new_history]       = self.kinds[i]
    end

    -- Rebuild pinned set with new indices: we drop old ones since indices changed.
    -- Pin the new summary entry so it survives further compactions.
    self.history = new_history
    self.kinds = new_kinds
    self.pinned = { [summary_index] = true }
    self.compact_cursor = summary_index

    -- Persist to MEMORY.md if configured.
    if ac.persist and self.memory then
        local _, perr = self.memory:append_fact(summary)
        if perr then
            self.log("warn", "compact_persist_error", { err = perr })
        end
    end

    self:fire("on_compact_done", { summary = summary, new_size = #self.history })
    self.log("info", "compact_done", { agent_id = self.agent_id, new_size = #self.history })
    self.status = "running"
    return true, nil
end

-- Execute a single tool call and produce a tool result message.
-- Special-cases the spawn_subagent built-in when subagent_manager is set.
local function dispatch_tool_call(self, tc)
    self:fire("on_tool_call", { name = tc.name, args = tc.arguments, id = tc.id })
    self.log("info", "tool_call", {
        agent_id = self.agent_id, tool = tc.name, id = tc.id,
    })

    self:_yield("before_tool", { name = tc.name, args = tc.arguments })

    local result_str, err

    if tc.name == "spawn_subagent" and self.subagent_manager then
        -- Delegate to subagent manager. The manager may yield internally to
        -- multiplex with other subagents, so this respects coroutine semantics.
        local out, serr = self.subagent_manager:run_tool(tc.arguments or {}, self, tc.id)
        if not out then
            err = serr or "subagent failed"
        else
            result_str = out
        end
    else
        local ctx = {
            http = self.http,
            json = self.json,
            fs = self.fs,
            agent = self,
            agent_id = self.agent_id,
            log = self.log,
            memory = self.memory,
        }
        result_str, err = self.tools:dispatch(tc.name, tc.arguments or {}, ctx)
    end

    if err then
        result_str = "error: " .. tostring(err)
    end

    local tool_msg = {
        role = "tool",
        tool_call_id = tc.id,
        name = tc.name,
        content = result_str or "",
    }
    self:add_message(tool_msg)

    self:fire("on_tool_result", {
        name = tc.name, id = tc.id, result = result_str, err = err,
    })
    self.log("info", "tool_result", {
        agent_id = self.agent_id, tool = tc.name, id = tc.id,
        ok = err == nil,
    })

    self:_yield("after_tool", { name = tc.name })
    return true
end

-- Run a single iteration step: one LLM call + (if any) tool dispatches.
-- Returns "tool_calls_pending" | "final_answer" | "error".
function AgentLoop:step()
    if self.status == "done" or self.status == "error" then
        return self.status
    end
    self.status = "running"
    self.iteration = self.iteration + 1
    self:fire("on_iteration", { n = self.iteration })

    -- Autocompact before the LLM call so we don't blow the context window.
    if should_compact(self) then
        local _, cerr = self:compact()
        if cerr then
            self.log("warn", "compact_failed_continuing", { err = cerr })
        end
    end

    local req = build_request(self)
    self:fire("on_llm_request", { model = req.model, message_count = #req.messages })

    self:_yield("before_llm", { iteration = self.iteration })

    local ctx = { http = self.http, json = self.json, fs = self.fs }
    local resp, err = self.provider:chat(req, ctx)

    self:_yield("after_llm", { iteration = self.iteration })

    if not resp then
        self.last_error = err or "provider returned nil"
        self.status = "error"
        self:fire("on_error", { err = self.last_error })
        self.log("error", "llm_error", { agent_id = self.agent_id, err = self.last_error })
        return "error"
    end

    self:fire("on_llm_response", {
        finish = resp.finish, has_tool_calls = resp.tool_calls ~= nil,
    })

    if resp.finish == "error" then
        self.last_error = resp.error or "provider error"
        self.status = "error"
        self:fire("on_error", { err = self.last_error })
        return "error"
    end

    -- Append assistant message to history.
    local assistant_msg = response_to_message(resp)
    self:add_message(assistant_msg)

    if resp.tool_calls and #resp.tool_calls > 0 then
        self.status = "awaiting_tool"

        -- First pass: identify spawn_subagent calls. If there are 2+ of them,
        -- we want them to progress in cooperative round-robin within this
        -- single turn (so the LLM doesn't block on the first one to finish).
        -- We dispatch other tool calls inline as before.
        local sub_calls = {}
        if self.subagent_manager then
            for i = 1, #resp.tool_calls do
                if resp.tool_calls[i].name == "spawn_subagent" then
                    sub_calls[#sub_calls + 1] = resp.tool_calls[i]
                end
            end
        end

        if #sub_calls >= 2 then
            -- Spawn all subagents up front, drive them via run_pool, then
            -- emit one tool_result per subagent in original order.
            local handles_by_id = {}
            for i = 1, #sub_calls do
                local tc = sub_calls[i]
                self:fire("on_tool_call",
                    { name = tc.name, args = tc.arguments, id = tc.id })
                self.log("info", "tool_call",
                    { agent_id = self.agent_id, tool = tc.name, id = tc.id })
                self:_yield("before_tool",
                    { name = tc.name, args = tc.arguments })

                local args = tc.arguments or {}
                if type(args) ~= "table" or type(args.task) ~= "string"
                    or args.task == "" then
                    handles_by_id[tc.id] = {
                        error_text = "spawn_subagent requires args.task (string)" }
                else
                    local handle = self.subagent_manager:spawn({
                        task = args.task,
                        tools = args.tools,
                        inherit_tools = args.inherit_tools,
                        builtin_tools = (args.builtin_tools ~= nil)
                            and args.builtin_tools or false,
                        llm = args.model and { model = args.model } or nil,
                        max_iterations = args.max_iterations,
                        parent_call_id = tc.id,
                    })
                    handles_by_id[tc.id] = handle
                end
            end

            -- Collect actual handles (skip the failed-arg sentinels).
            local handles = {}
            for i = 1, #sub_calls do
                local tc = sub_calls[i]
                local h = handles_by_id[tc.id]
                if h and not h.error_text then
                    handles[#handles + 1] = h
                end
            end
            if #handles > 0 then
                self.subagent_manager:run_pool(handles)
            end

            -- Now process EVERY tool_call in original order, emitting tool
            -- results. Subagent calls use the run_pool results; other calls
            -- go through dispatch_tool_call as normal.
            for i = 1, #resp.tool_calls do
                local tc = resp.tool_calls[i]
                if tc.name == "spawn_subagent" then
                    local h = handles_by_id[tc.id]
                    local result_str
                    if h and h.error_text and not h.id then
                        -- arg-validation sentinel
                        result_str = "[subagent failed]: " .. h.error_text
                    elseif h.status_value == "error" then
                        result_str = "[subagent " .. h.id .. " failed]: " ..
                            tostring(h.error_text)
                    else
                        result_str = "[subagent " .. h.id .. " result]:\n" ..
                            tostring(h.result_text or "")
                    end

                    local tool_msg = {
                        role = "tool",
                        tool_call_id = tc.id,
                        name = tc.name,
                        content = result_str,
                    }
                    self:add_message(tool_msg)
                    self:fire("on_tool_result",
                        { name = tc.name, id = tc.id, result = result_str,
                          err = (h and h.error_text) or nil })
                    self.log("info", "tool_result",
                        { agent_id = self.agent_id, tool = tc.name, id = tc.id,
                          ok = not (h and h.error_text) })
                    self:_yield("after_tool", { name = tc.name })
                else
                    dispatch_tool_call(self, tc)
                end
            end
        else
            -- Single tool call (or no subagent calls): inline dispatch.
            for i = 1, #resp.tool_calls do
                dispatch_tool_call(self, resp.tool_calls[i])
            end
        end

        self.status = "running"
        return "tool_calls_pending"
    end

    -- Final answer.
    self.final_message = assistant_msg
    self.status = "done"
    self:fire("on_done", { final = assistant_msg })
    self.log("info", "done", { agent_id = self.agent_id, iterations = self.iteration })
    return "final_answer"
end

-- Push a user message and run iterations until done or max reached.
-- This is the synchronous entry point. When called from inside a coroutine
-- (via Runner), the yields will give scheduling opportunities; otherwise it
-- blocks until completion.
function AgentLoop:run(user_message)
    if user_message ~= nil then
        if type(user_message) == "string" then
            self:add_message({ role = "user", content = user_message })
        elseif type(user_message) == "table" then
            self:add_message(user_message)
        else
            return nil, "user_message must be string or table"
        end
    end

    self.iteration = 0
    self.status = "running"
    self.last_error = nil
    self.final_message = nil

    while self.iteration < self.max_iterations do
        local outcome = self:step()
        if outcome == "final_answer" then
            return self.final_message, nil
        elseif outcome == "error" then
            return nil, self.last_error
        end
    end

    self.status = "error"
    self.last_error = "max_iterations reached"
    self:fire("on_error", { err = self.last_error })
    return nil, self.last_error
end

-- Reset state for a fresh task while keeping registered tools / memory.
function AgentLoop:reset()
    self.history = {}
    self.pinned = {}
    self.kinds = {}
    self.compact_cursor = 0
    self.iteration = 0
    self.status = "idle"
    self.last_error = nil
    self.final_message = nil
end

-- Build a structured view of the conversation, suitable for a UI.
-- Returns an array of entries:
--   {
--     index      = 1-based history index
--     kind       = string ("user_text" | "assistant_text" | "tool_call" |
--                  "tool_result" | "system" | "compact_summary" |
--                  "subagent_call" | "subagent_result" | "pinned_note")
--     kind_id    = the integer MK_* code (handy if the UI wants to switch by id)
--     role       = "user" | "assistant" | "tool" | "system"
--     agent_id   = the agent that produced this entry
--     content    = string text (for plain messages and tool results)
--     tool_calls = array of { id, name, arguments } when kind == "tool_call"/"subagent_call"
--     tool_call_id = id of the call this result answers (for tool_result/subagent_result)
--     tool_name  = name of the tool (for tool_result/subagent_result)
--     pinned     = boolean
--     subagent   = { id, transcript = { ...nested entries... } } when present
--   }
--
-- opts:
--   include_subagents = true (default) -> embed each subagent's :messages() under its call entry
--   include_system    = true (default) -> include system / compact_summary entries
function AgentLoop:messages(opts)
    opts = opts or {}
    local include_sub = opts.include_subagents
    if include_sub == nil then include_sub = true end
    local include_sys = opts.include_system
    if include_sys == nil then include_sys = true end

    local out = {}
    for i = 1, #self.history do
        local m = self.history[i]
        local kind_id = self.kinds[i] or infer_kind(m)
        if include_sys or (kind_id ~= M.MK_SYSTEM and kind_id ~= M.MK_COMPACT_SUMMARY) then
            local entry = {
                index    = i,
                kind_id  = kind_id,
                kind     = KIND_NAME[kind_id] or "unknown",
                role     = m.role,
                agent_id = self.agent_id,
                pinned   = self.pinned[i] and true or false,
            }

            if type(m.content) == "string" then
                entry.content = m.content
            elseif type(m.content) == "table" then
                -- Multi-part content (vision / structured): expose raw.
                entry.content = m.content
            end

            if type(m.tool_calls) == "table" and #m.tool_calls > 0 then
                local calls = {}
                for j = 1, #m.tool_calls do
                    local tc = m.tool_calls[j]
                    local fn = tc and tc["function"] or {}
                    calls[j] = {
                        id = tc.id,
                        name = fn.name or tc.name,
                        arguments = fn.arguments or tc.arguments,
                    }
                end
                entry.tool_calls = calls
            end

            if m.role == "tool" then
                entry.tool_call_id = m.tool_call_id
                entry.tool_name    = m.name
            end

            -- Embed subagent transcripts when this entry references a tool
            -- call that spawned a subagent we still have a handle for.
            if include_sub and self.subagent_manager and entry.tool_call_id then
                local sub = self.subagent_manager:find_by_call_id(entry.tool_call_id)
                if sub and sub.lunatic and sub.lunatic.loop then
                    entry.subagent = {
                        id = sub.id,
                        task = sub.task,
                        status = sub:status(),
                        transcript = sub.lunatic.loop:messages(opts),
                    }
                end
            end

            out[#out + 1] = entry
        end
    end
    return out
end

-- Pin/unpin shortcut as a host-level annotation so a UI can mark important
-- entries that should survive compaction.
function AgentLoop:annotate(index, kind_id)
    if type(index) == "number" and self.history[index] then
        self.kinds[index] = kind_id
        return true
    end
    return false
end

-- Cancel the current run cooperatively. Mirror Runner:cancel for symmetry.
-- Sets status; the next yield-driven step will short-circuit. The currently
-- running iteration completes naturally (we cannot kill a coroutine).
function AgentLoop:cancel()
    if self.status ~= "done" and self.status ~= "error" then
        self.status = "error"
        self.last_error = "cancelled"
    end
    return true
end

return M
