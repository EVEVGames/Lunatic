-- lunatic/tools/read_file.lua
-- Tool: read_file
--
-- This file is loaded as a fresh chunk on every invocation. Lunatic injects
-- two globals into the chunk's environment:
--
--   args    -- decoded JSON arguments table from the LLM tool_call
--   ctx     -- runtime context: { fs, json, http, memory, agent, agent_id, log }
--
-- The chunk's top-level return value becomes the tool result. Returning
-- (nil, "msg") signals an error to the agent.

if type(args) ~= "table" or type(args.path) ~= "string" then
    return nil, "path (string) is required"
end

local fs = (ctx and ctx.fs) or { open = io.open }
if type(fs.open) ~= "function" then
    return nil, "filesystem unavailable"
end

local fh, oerr = fs.open(args.path, "rb")
if not fh then
    return nil, "open failed: " .. tostring(oerr)
end

local ok, content = pcall(function()
    local c = fh:read("*a")
    fh:close()
    return c
end)

if not ok then
    pcall(function() fh:close() end)
    return nil, "read failed"
end

return content
