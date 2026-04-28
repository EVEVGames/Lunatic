-- lunatic/tools/list_dir.lua
-- Tool: list_dir. Globals `args` and `ctx` injected by Lunatic.

local a = args
if type(a) ~= "table" then a = {} end

local path = a.path or "."

if not io.popen then
    return nil, "io.popen unavailable; cannot list directory"
end

local sep = "/"
if package and package.config then
    sep = package.config:sub(1, 1)
end

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
