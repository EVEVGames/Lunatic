-- lunatic/tools/write_file.lua
local args, ctx = ...

if type(args) ~= "table" or type(args.path) ~= "string"
    or type(args.content) ~= "string" then
    return nil, "path and content (strings) are required"
end

local fs = (ctx and ctx.fs) or { open = io.open }
if type(fs.open) ~= "function" then
    return nil, "filesystem unavailable"
end

local fh, oerr = fs.open(args.path, "wb")
if not fh then
    return nil, "open failed: " .. tostring(oerr)
end

local ok = pcall(function() fh:write(args.content); fh:close() end)
if not ok then
    pcall(function() fh:close() end)
    return nil, "write failed"
end

return "wrote " .. tostring(#args.content) .. " bytes to " .. args.path
