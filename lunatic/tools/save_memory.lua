-- lunatic/tools/save_memory.lua
-- Tool: save_memory. Unpacks varargs explicitly.
-- Uses ctx.memory (the agent's MemoryStore) so it respects the workspace.

local args, ctx = ...

if type(args) ~= "table" or type(args.fact) ~= "string" or args.fact == "" then
    return nil, "fact (non-empty string) is required"
end

local memory = ctx and ctx.memory
if not memory then
    return nil, "memory store unavailable in ctx"
end

local ok, err = memory:append_fact(args.fact)
if not ok then return nil, err end

return "saved fact"
