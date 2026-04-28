-- lunatic/tools/edit_file.lua
local args, ctx = ...

if type(args) ~= "table" or type(args.path) ~= "string"
    or type(args.search) ~= "string" or type(args.replace) ~= "string" then
    return nil, "path, search, replace (all strings) are required"
end

local fs = (ctx and ctx.fs) or { open = io.open }
if type(fs.open) ~= "function" then
    return nil, "filesystem unavailable"
end

-- Escape Lua pattern magic so the search is treated literally.
local function pat_escape(s)
    return (s:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"))
end

local fh, oerr = fs.open(args.path, "rb")
if not fh then
    return nil, "open failed: " .. tostring(oerr)
end

local content
local ok = pcall(function() content = fh:read("*a"); fh:close() end)
if not ok or not content then
    pcall(function() fh:close() end)
    return nil, "read failed"
end

if not content:find(args.search, 1, true) then
    return nil, "search string not found in file"
end

local new_content = content:gsub(pat_escape(args.search),
    args.replace:gsub("%%", "%%%%"))

local fh2, oerr2 = fs.open(args.path, "wb")
if not fh2 then return nil, "reopen failed: " .. tostring(oerr2) end
local ok2 = pcall(function() fh2:write(new_content); fh2:close() end)
if not ok2 then
    pcall(function() fh2:close() end)
    return nil, "write failed"
end

return "edited " .. args.path
