-- lunatic/tools/http_fetch.lua
-- Tool: http_fetch. Unpacks varargs explicitly.
-- Uses ctx.http (the agent's injected HTTPS lib) instead of requiring
-- ssl.https directly — so the same instance honours sandboxed environments.

local args, ctx = ...

if type(args) ~= "table" or type(args.url) ~= "string" then
    return nil, "url (string) is required"
end

local http = ctx and ctx.http
if not http then
    return nil, "http library unavailable in ctx"
end

local method = args.method or "GET"
local headers = args.headers or {}
local body_in = args.body

-- Function-shape http: ctx.http(opts) -> body, status
if type(http) == "function" then
    local ok, body, status = pcall(http,
        { url = args.url, method = method, headers = headers, body = body_in })
    if not ok then return nil, "http error: " .. tostring(body) end
    return body or ""
end

-- Table-shape http with .request (luasec / LuaSocket).
if type(http) == "table" and type(http.request) == "function" then
    local response = {}
    local source
    if body_in and #body_in > 0 then
        local sent = false
        source = function()
            if sent then return nil end
            sent = true; return body_in
        end
        if not headers["content-length"] and not headers["Content-Length"] then
            headers["content-length"] = tostring(#body_in)
        end
    end
    local ok, code = pcall(http.request, {
        url = args.url, method = method, headers = headers, source = source,
        sink = function(chunk) if chunk then response[#response + 1] = chunk end; return 1 end,
    })
    if not ok then return nil, "http error: " .. tostring(code) end
    return table.concat(response)
end

return nil, "http library has unsupported shape"
