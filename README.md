# Lunatic

Ultra-lightweight pure-Lua AI agent loop.

Lunatic is an **agent loop library**, not a personal AI assistant. It maintains
conversations, persistent memory in markdown files, autocompacts long
histories, executes tools, spawns subagents, and lazy-loads skills — all in
around 3500 lines of plain Lua.

It is heavily inspired by the `agent/` module of
[HKUDS/nanobot](https://github.com/HKUDS/nanobot) but stripped to a small,
embeddable surface: no channels, no CLI, no skills system at the framework
level beyond a small lazy-loading hook.

## Compatibility

Tested on Lua **5.1, 5.3, 5.4, and LuaJIT 2.1**. Compatible with Lua 5.2 and
5.5 (no version-specific syntax used). Two-class total: `Lunatic` and
`Runner`. Plus eight internal modules.

## Dependencies

Only **three**, all overrideable via the constructor:

| Dep    | Default                | Override field |
|--------|------------------------|----------------|
| HTTPS  | `luasec` (`ssl.https`) | `config.http`  |
| JSON   | `require("json")`      | `config.json`  |
| Filesys| `io.open` wrapper      | `config.fs`    |

If your environment is sandboxed (LÖVE, redbean, openresty, etc.), pass your
own implementations.

## Quick start

```lua
local L = require("lunatic")

local agent = L.Lunatic.new({
    workspace = "./my-project/",
    llm = {
        provider = "openai",            -- or anthropic, gemini, openrouter, ollama, generic_openai
        model    = "gpt-4o-mini",
        api_key  = os.getenv("OPENAI_API_KEY"),
    },
})

-- Synchronous run: blocks until the agent reaches a final answer.
local final, err = agent:run("Summarise the latest entry in MEMORY.md")
print(final.content)
```

## Cooperative execution (Runner)

```lua
local runner = L.Runner.new(agent)
runner:submit("Plan a small Python project")

while not runner:is_ready() do
    runner:next()
    -- Hand control back to your event loop here (LÖVE update, openresty timer, etc.)
end

local result, err = runner:result()
```

## Workspace files

Lunatic reads and writes these files **flat** in the workspace folder
(it never creates subdirectories — pure Lua cannot do that portably):

| File              | Direction       | Purpose                                    |
|-------------------|-----------------|--------------------------------------------|
| `AGENTS.md`       | read-only       | Agent instructions                         |
| `SOUL.md`         | read-only       | Personality                                |
| `USER.md`         | read-only       | User profile                               |
| `TOOLS.md`        | read-only       | Custom tool documentation                  |
| `MEMORY.md`       | read + append   | Consolidated long-term facts               |
| `HISTORY.md`      | read + append   | High-level activity log                    |
| `YYYY-MM-DD.md`   | append          | Daily journals                             |
| `<id>.json`       | read + write    | Saved session snapshots                    |
| `SKILL.<n>.md`    | read + write    | Skill content (lazy-loaded; see below)     |

If a file is missing, the agent silently treats it as empty — it does not
crash.

## Tools

### Registration shapes

`register_tool` accepts three signatures so you can be terse when there's
nothing extra to say:

```lua
-- (1) full spec + handler
agent:register_tool({
    name = "add",
    description = "Adds two numbers",
    parameters = {
        type = "object",
        properties = { a = { type = "number" }, b = { type = "number" } },
        required = { "a", "b" },
    },
}, function(args, ctx)
    return tostring(args.a + args.b)
end)

-- (2) name as first arg overrides spec.name
agent:register_tool("add", { description = "..." }, function(args) ... end)

-- (3) name + handler shorthand (no spec table; minimal default schema)
agent:register_tool("ping", function() return "pong" end)
```

### Function handlers

A function handler receives `(args, ctx)`. `ctx` carries everything the
handler typically needs:

```
ctx.fs       -- filesystem (the injected one)
ctx.http     -- HTTPS lib (the injected one)
ctx.json     -- JSON lib
ctx.memory   -- the agent's MemoryStore
ctx.agent    -- the Lunatic instance
ctx.agent_id -- "main" / "main:sub:abc..."
ctx.log      -- the logger function
```

### Module-path handlers

Pass a string and Lunatic will lazy-load that module on each call:

```lua
agent:register_tool({ name = "webbrowser", ... }, "tools.webbrowser")
```

The module file unpacks `args` and `ctx` from the varargs at the top of
the file. The chunk's top-level `return` is the tool result:

```lua
-- tools/webbrowser.lua
local args, ctx = ...

if type(args) ~= "table" or not args.url then
    return nil, "url required"
end

local body = ctx.http(args.url)   -- use the injected http
return { body = body, length = #body }   -- top-level return = tool result
```

You can return `value`, `(value, err)`, or `(nil, err)`. The convention is
the same for both function and module handlers.

### Built-in tools (default on)

`read_file`, `write_file`, `edit_file`, `list_dir`, `http_fetch`,
`save_memory`, `recall_memory`, `load_skill`, `spawn_subagent`.

Disable all with `builtin_tools = false`. Disable just `load_skill` with
`enable_load_skill = false`. Remove individually via
`agent:unregister_tool(name)`.

### Tool management API

```
agent:register_tool(spec, handler)         -- or (name, spec, handler) / (name, handler)
agent:unregister_tool(name)
agent:has_tool(name)        -> bool
agent:get_tool(name)        -> { spec, handler, enabled, source }
agent:list_tools()          -> array of OpenAI-format specs
agent:enable_tool(name)
agent:disable_tool(name)
agent:clear_tools()
```

## Subagents

Subagents run inside their own coroutines. The main loop drives them
cooperatively, so multiple parallel subagents in one turn interleave fairly
without OS threads.

```lua
local handle = agent:spawn_subagent({
    task = "Find every TODO in src/",
    tools = { "read_file", "list_dir" },   -- whitelist
})

-- Either block...
local result, err = handle:run()

-- ...or drive cooperatively (same convention as Runner)
while not handle:is_ready() do
    handle:next()
end
```

When the LLM emits a `spawn_subagent` tool call, the agent loop intercepts
it and routes through the subagent manager directly. Multiple
`spawn_subagent` calls in a single turn run in cooperative round-robin. The
subagent's `parent_call_id` is recorded so a UI can correlate subagent
transcripts with the originating tool_call.

The subagent API mirrors Runner exactly:

```
handle:run()       -> result, err
handle:next()      -> advance one step
handle:is_ready()  -> bool
handle:result()    -> result, err
handle:status()    -> "idle" | "running" | "done" | "error"
handle:cancel()
handle:messages()  -> structured transcript (same shape as agent:messages())
```

## Skills (lazy-loaded)

Skills are markdown files describing a focused capability — "writing PRs",
"debugging Python", etc. The framework deliberately doesn't auto-load them;
instead it shows the LLM a **catalog** of available skills (just name +
description), and the LLM decides whether to pull a skill's body in via the
`load_skill` built-in tool.

### Setup

Put the skill file in your workspace as `SKILL.<name>.md`:

```
my-project/SKILL.git.md
my-project/SKILL.docker.md
```

(Lunatic also accepts the folded layout `skills/<name>/SKILL.md` if you
created the directory yourself, since pure Lua cannot create directories.)

### Tell the agent what's available

```lua
agent:set_available_skills({
    { name = "git",    description = "Git workflow tips and conventions" },
    { name = "docker", description = "How to set up and run Docker locally" },
})
```

The system prompt now contains:

```
# Available skills (use the load_skill tool to read one)

- **git**: Git workflow tips and conventions
- **docker**: How to set up and run Docker locally
```

Bodies are NOT in the prompt yet.

### LLM loads what it needs

When the model calls `load_skill({ name = "git" })`, the body is read from
disk, returned as the tool result (so the model sees it immediately), and
the skill is added to the loaded set. From the next turn onward, the body
appears under `# Loaded skills (full content)` in the system prompt.

### Skill management API

```
agent:set_available_skills(catalog)            -- replace catalog
agent:add_available_skill({ name, description }) -- add to catalog (dedupes by name)
agent:list_available_skills()                  -- the catalog

agent:add_skill(name)                          -- mark as loaded (programmatic)
agent:remove_skill(name)                       -- unload
agent:set_skills(names)                        -- replace loaded list
agent:list_loaded_skills()                     -- currently loaded names

agent:has_skill(name)                          -- exists on disk?
agent:read_skill(name)                         -- read body
agent:write_skill(name, body)                  -- write body (flat layout)
```

### Disabling lazy loading

```lua
local agent = L.Lunatic.new({
    -- ...
    enable_load_skill = false,    -- LLM cannot self-load; use agent:add_skill manually
})
```

## Structured messages for UIs

`agent:messages()` returns a UI-friendly view of the conversation. Every
entry is tagged with a **kind** (string + integer code) so a UI can render
each appropriately:

| Integer constant         | String kind        | Meaning                                  |
|--------------------------|--------------------|------------------------------------------|
| `MK_USER_TEXT` (1)       | `"user_text"`      | Plain user message                       |
| `MK_ASSISTANT_TEXT` (2)  | `"assistant_text"` | Plain assistant text answer              |
| `MK_TOOL_CALL` (3)       | `"tool_call"`      | Assistant message with tool_calls        |
| `MK_TOOL_RESULT` (4)     | `"tool_result"`    | Tool message holding a result            |
| `MK_SYSTEM` (5)          | `"system"`         | Ad-hoc system message                    |
| `MK_COMPACT_SUMMARY` (6) | `"compact_summary"`| System message produced by autocompact   |
| `MK_SUBAGENT_CALL` (7)   | `"subagent_call"`  | Tool_call invoking spawn_subagent        |
| `MK_SUBAGENT_RESULT` (8) | `"subagent_result"`| Tool result holding subagent answer      |
| `MK_PINNED_NOTE` (9)     | `"pinned_note"`    | Host-set annotation                      |

Constants live on the loop module: `require("lunatic.loop").MK_USER_TEXT`.

### Entry shape

```lua
{
    index      = 3,
    kind       = "tool_call",   -- friendly string
    kind_id    = 3,             -- integer (matches MK_* constants)
    role       = "assistant",
    agent_id   = "main",
    pinned     = false,
    content    = nil,           -- text content if present
    tool_calls = {              -- present for tool_call / subagent_call kinds
        { id = "c1", name = "ping", arguments = { ... } },
    },
    tool_call_id = "c1",        -- present for tool_result / subagent_result
    tool_name    = "ping",
    subagent     = {            -- present when this entry is a subagent_result
        id     = "sub_abc...",
        task   = "find TODOs",
        status = "done",
        transcript = { ... }    -- recursive call to subagent's :messages()
    },
}
```

### UI rendering example

```lua
for _, m in ipairs(agent:messages()) do
    if m.kind == "user_text" then
        ui:bubble("user", m.content)
    elseif m.kind == "assistant_text" then
        ui:bubble("assistant", m.content)
    elseif m.kind == "tool_call" then
        for _, tc in ipairs(m.tool_calls) do
            ui:tool_invocation(tc.name, tc.arguments)
        end
    elseif m.kind == "tool_result" then
        ui:tool_output(m.tool_name, m.content)
    elseif m.kind == "subagent_result" then
        ui:nested_chat(m.subagent.task, m.subagent.transcript)
    elseif m.kind == "compact_summary" then
        ui:divider("memory consolidated")
    end
end
```

### Filtering

```lua
agent:messages({ include_system = false })       -- drop system + compact_summary
agent:messages({ include_subagents = false })    -- skip transcript embedding
```

### Annotating

```lua
local idx = agent:add_message({ role = "system", content = "important note" },
                              L.Loop.MK_PINNED_NOTE)
agent.loop:pin(idx)
```

`save_session` / `load_session` persist `kinds` and `pinned` along with
`history`, so reloading a session restores the UI rendering exactly.

## Autocompact

When history exceeds `max_tokens` (estimated) or `max_messages`, Lunatic
makes a separate LLM call to summarise old turns into durable facts,
replaces them in-place with a single `system` summary message tagged
`MK_COMPACT_SUMMARY`, and optionally appends to `MEMORY.md`.

```lua
agent = L.Lunatic.new({
    -- ...
    autocompact = {
        enabled = true,
        max_tokens = 8000,
        max_messages = 100,
        keep_last = 10,
        persist = true,
    },
})

agent:compact()  -- manual trigger
```

## Logging and hooks

Two separate channels:

**Logger** — observability. Always exists; default formats
`[ts][agent_id][level] event ...`.

```lua
agent = L.Lunatic.new({
    log = function(level, event, data)
        my_logger:log(level, event, data)
    end,
})
```

Or pass a table to tune the default: `log = { min_level = "warn" }`.

**Hooks** — reactive callbacks at lifecycle points:

```lua
agent = L.Lunatic.new({
    hooks = {
        on_message       = function(p) end,    -- p = { message, index, kind, agent_id }
        on_iteration     = function(p) end,
        on_llm_request   = function(p) end,
        on_llm_response  = function(p) end,
        on_tool_call     = function(p) end,
        on_tool_result   = function(p) end,
        on_compact_start = function(p) end,
        on_compact_done  = function(p) end,
        on_subagent_spawn = function(p) end,
        on_subagent_done  = function(p) end,
        on_done          = function(p) end,
        on_error         = function(p) end,
    },
})
```

Subagents inherit log + hooks from the parent (with their own `agent_id`).

## Providers

Built-in: `openai`, `openrouter`, `generic_openai`, `anthropic`, `gemini`,
`ollama`.

Custom adapters can be registered globally:

```lua
L.register_provider("my_llm", function()
    return {
        name = "my_llm",
        chat = function(self, req, ctx)
            -- return { content=..., tool_calls=..., finish=..., raw=... }, nil
        end,
    }
end)
```

The internal request format passed to `provider:chat(req, ctx)`:

```lua
{
    messages = {                -- canonical message list
        { role = "system", content = "..." },
        { role = "user",   content = "..." },
        { role = "assistant", content = nil, tool_calls = {...} },
        { role = "tool", tool_call_id = "...", name = "...", content = "..." },
    },
    tools = { ... },            -- OpenAI-format function specs (optional)
    model = "gpt-4o-mini",
    stream = false,
    temperature = 0.7,
    max_tokens = 2048,
}
```

Adapters normalise these to whatever the provider's wire format requires.

## Session persistence

```lua
agent:save_session("session_42")   -- writes <workspace>/session_42.json
agent:load_session("session_42")   -- restores history + pinned + kinds + cursor
```

## Cancellation

Three symmetrical APIs:

```lua
agent:cancel()                        -- stop the AgentLoop
runner:cancel()                       -- stop a Runner
handle:cancel()                       -- stop a subagent
agent:cancel_subagent(id)             -- stop a subagent by id from the parent
```

All set status to `"error"` with `last_error == "cancelled"`. Coroutines
that have already issued a network call run to completion before being
GC'd; we cannot truly kill a Lua coroutine.

## Configuration reference

```lua
L.Lunatic.new({
    workspace      = "./.lunatic/",        -- folder where MD/JSON files live
    agent_id       = "main",               -- used in logs / subagent ids

    http           = ...,                  -- override HTTPS dep
    json           = ...,                  -- override JSON dep
    fs             = { open = io.open },   -- override filesystem dep

    llm = {
        provider   = "openai",
        model      = "gpt-4o-mini",
        api_key    = "...",
        base_url   = "...",                -- optional override
        temperature = 0.7,
        max_tokens  = 2048,
        extra_headers = { ... },
    },

    builtin_tools     = true,              -- install the built-in tool set
    enable_load_skill = true,              -- include the load_skill tool

    available_skills = {                   -- catalog shown to the LLM
        { name = "git", description = "..." },
    },
    loaded_skills = { },                   -- pre-loaded names (rare)

    max_iterations = 20,
    autocompact    = {
        enabled = true,
        max_tokens = 8000,
        max_messages = 100,
        keep_last = 10,
        persist = true,
    },

    extra_system   = "extra text appended to the system prompt",
    history_tail_lines = 30,

    log   = function(level, event, data) end,    -- or { min_level = "info" }
    hooks = { on_message = ..., on_tool_call = ..., ... },
})
```

## Testing

The repo ships two test suites:

```
tests/         -- legacy assert-based smoke + edge tests
spec/          -- describe/it/expect specs (the bulk of the suite)
```

Run all specs from the project root:

```
lua spec/run.lua
```

223 tests across 73 suites covering util, log, memory, context, tools,
provider adapters, loop, runner, subagent, skills, and full-flow
integration. All pass on Lua 5.1, 5.3, 5.4, and LuaJIT.

## License

MIT.
