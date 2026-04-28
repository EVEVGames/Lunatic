-- lunatic/tools/recall_memory.lua
-- Tool: recall_memory. Unpacks varargs explicitly.

local args, ctx = ...

local memory = ctx and ctx.memory
if not memory then
    return nil, "memory store unavailable in ctx"
end

return memory:read_facts() or ""
