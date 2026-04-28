-- spec/run.lua
-- Discover and run all *_spec.lua files in spec/.
-- Usage: lua spec/run.lua  (run from project root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local t = require("spec.support.runner")

-- Auto-discover spec files. We rely on `ls` since pure Lua has no portable
-- directory listing.
local function list_spec_files()
    local files = {}
    if io.popen then
        local sep = package.config:sub(1, 1)
        local cmd = (sep == "\\") and 'dir /b spec\\*_spec.lua'
                                   or 'ls spec/*_spec.lua 2>/dev/null'
        local pipe = io.popen(cmd, "r")
        if pipe then
            for line in pipe:lines() do
                if line and line ~= "" then
                    -- Strip prefix and .lua suffix.
                    local mod = line:gsub("^spec[/\\]", ""):gsub("%.lua$", "")
                    files[#files + 1] = "spec." .. mod
                end
            end
            pipe:close()
        end
    end
    return files
end

local specs = list_spec_files()
if #specs == 0 then
    print("No spec files found in spec/")
    os.exit(1)
end

table.sort(specs)
for _, mod in ipairs(specs) do
    require(mod)
end

t.run({ verbose = false })
