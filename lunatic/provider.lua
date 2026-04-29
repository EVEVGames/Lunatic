-- lunatic/provider.lua
-- LLM provider abstraction. Each adapter normalises requests and responses
-- to a single internal format used by the agent loop.
--
-- Internal response format:
--   {
--     content    = "text string or nil",
--     tool_calls = { { id=..., name=..., arguments=table }, ... } or nil,
--     finish     = "stop" | "tool_calls" | "length" | "error",
--     raw        = <original provider response, for hooks/logging>,
--   }
--
-- Internal request format passed to provider:chat(req):
--   {
--     messages = { { role=..., content=..., tool_calls=..., tool_call_id=..., name=... }, ... },
--     tools    = { { type="function", ["function"]={ name, description, parameters } }, ... } or nil,
--     model    = "model-name",
--     stream   = false,
--     temperature, max_tokens, ...
--   }
--
-- Compatible with Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT.

local util = require("lunatic.util")

local M = {}

-- Registry of named adapters.
local adapters = {}

-- ============================================================
-- HTTP helper: invokes the injected http function uniformly.
-- The injected http is expected to expose a function-like interface
-- compatible with luasec / LuaSocket "request" patterns. We accept
-- two shapes for flexibility:
--   1. http.request{ url=..., method=..., headers=..., source=..., sink=... }
--      (LuaSocket / luasec compound style)
--   2. http({ url=..., method=..., headers=..., body=... }) -> body, status
--      (simpler user-supplied wrapper)
-- ============================================================

local function do_request(http_lib, opts)
    if not http_lib then
        return nil, "no http library configured"
    end

    -- Plain function: shape #2
    if type(http_lib) == "function" then
        local ok, body, status = pcall(http_lib, opts)
        if not ok then
            return nil, "http call failed: " .. tostring(body)
        end
        if not body then
            return nil, "http returned no body (status=" .. tostring(status) .. ")"
        end
        return body, status
    end

    -- Table with .request: shape #1 (luasec / LuaSocket)
    if type(http_lib) == "table" and type(http_lib.request) == "function" then
        local response_body = {}
        local source = nil
        if opts.body and #opts.body > 0 then
            -- ltn12-style source from a string
            local sent = false
            source = function()
                if sent then return nil end
                sent = true
                return opts.body
            end
        end
        local headers = util.shallow_copy(opts.headers or {})
        if opts.body and not headers["content-length"] and not headers["Content-Length"] then
            headers["content-length"] = tostring(#opts.body)
        end

        local sink = function(chunk, err)
            if chunk then
                response_body[#response_body + 1] = chunk
            end
            return 1
        end

        local req = {
            url = opts.url,
            method = opts.method or "GET",
            headers = headers,
            source = source,
            sink = sink,
        }
        local ok, code = pcall(http_lib.request, req)
        if not ok then
            return nil, "http request failed: " .. tostring(code)
        end
        local body = table.concat(response_body)
        return body, code
    end

    return nil, "http library has unsupported shape"
end

-- ============================================================
-- OpenAI / OpenAI-compatible adapter
-- ============================================================

local function openai_build_payload(req)
    local payload = {
        model = req.model,
        messages = req.messages,
        stream = req.stream and true or false,
    }
    if req.tools and #req.tools > 0 then
        payload.tools = req.tools
        if req.tool_choice ~= nil then
            payload.tool_choice = req.tool_choice
        end
    end
    if req.temperature ~= nil then payload.temperature = req.temperature end
    if req.max_tokens ~= nil then payload.max_tokens = req.max_tokens end
    if req.top_p ~= nil then payload.top_p = req.top_p end
    if req.stop ~= nil then payload.stop = req.stop end
    return payload
end

local function openai_parse_response(decoded)
    if type(decoded) ~= "table" then
        return nil, "response was not a table"
    end
    if decoded.error then
        local msg = "unknown error"
        if type(decoded.error) == "table" then
            msg = decoded.error.message or msg
        else
            msg = tostring(decoded.error)
        end
        return { content = nil, tool_calls = nil, finish = "error", raw = decoded, error = msg }, nil
    end
    local choices = decoded.choices
    if type(choices) ~= "table" or #choices == 0 then
        return nil, "no choices in response"
    end
    local choice = choices[1]
    local msg = choice.message or {}
    local out = {
        content = msg.content,
        tool_calls = nil,
        finish = choice.finish_reason or "stop",
        raw = decoded,
    }
    if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        out.tool_calls = {}
        for i = 1, #msg.tool_calls do
            local tc = msg.tool_calls[i]
            local fn = tc["function"] or {}
            out.tool_calls[i] = {
                id = tc.id,
                name = fn.name,
                arguments_raw = fn.arguments, -- string from API
            }
        end
    end
    return out, nil
end

local function openai_make_adapter(default_base_url)
    return {
        name = "openai-compatible",
        chat = function(self, req, ctx)
            local base_url = self.base_url or default_base_url
            local url = base_url:gsub("/$", "") .. "/chat/completions"
            local payload = openai_build_payload(req)
            local body, err = util.safe_encode(ctx.json, payload)
            if not body then
                return nil, "failed to encode request: " .. tostring(err)
            end
            local headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
            }
            if self.api_key and self.api_key ~= "" then
                headers["Authorization"] = "Bearer " .. self.api_key
            end
            if self.extra_headers then
                for k, v in pairs(self.extra_headers) do headers[k] = v end
            end
            local resp_body, status = do_request(ctx.http, {
                url = url, method = "POST", headers = headers, body = body,
            })
            if not resp_body then
                return nil, "http error: " .. tostring(status)
            end
            local decoded, derr = util.safe_decode(ctx.json, resp_body)
            if not decoded then
                return nil, "failed to decode response: " .. tostring(derr) ..
                    " (status=" .. tostring(status) .. ", body=" ..
                    tostring(resp_body):sub(1, 200) .. ")"
            end
            -- Decode tool-call argument JSON strings into tables.
            local parsed, perr = openai_parse_response(decoded)
            if not parsed then return nil, perr end
            if parsed.tool_calls then
                for i = 1, #parsed.tool_calls do
                    local tc = parsed.tool_calls[i]
                    if tc.arguments_raw and tc.arguments_raw ~= "" then
                        local args, aerr = util.safe_decode(ctx.json, tc.arguments_raw)
                        if args then
                            tc.arguments = args
                        else
                            tc.arguments = {}
                            tc.arguments_error = aerr
                        end
                    else
                        tc.arguments = {}
                    end
                end
            end
            return parsed, nil
        end,
    }
end

-- ============================================================
-- Anthropic adapter
-- ============================================================

local function anthropic_split_messages(messages)
    -- Anthropic uses a separate system field; collapse leading system msgs.
    local system_parts = {}
    local conv = {}
    for i = 1, #messages do
        local m = messages[i]
        if m.role == "system" then
            if type(m.content) == "string" then
                system_parts[#system_parts + 1] = m.content
            end
        else
            conv[#conv + 1] = m
        end
    end
    return table.concat(system_parts, "\n\n"), conv
end

local function anthropic_convert_message(m)
    -- Anthropic content blocks: text / tool_use / tool_result.
    local role = m.role
    if role == "tool" then
        -- Tool result back to model: must be user message with tool_result block
        return {
            role = "user",
            content = {
                {
                    type = "tool_result",
                    tool_use_id = m.tool_call_id,
                    content = (type(m.content) == "string") and m.content or "",
                },
            },
        }
    end

    if role == "assistant" and type(m.tool_calls) == "table" and #m.tool_calls > 0 then
        local blocks = {}
        if type(m.content) == "string" and m.content ~= "" then
            blocks[#blocks + 1] = { type = "text", text = m.content }
        end
        for i = 1, #m.tool_calls do
            local tc = m.tool_calls[i]
            local fn = tc["function"] or { name = tc.name }
            local args = fn.arguments
            if type(args) == "string" then
                -- already JSON string; we'll let the model see it as object
                -- (anthropic expects 'input' as object). Caller passes raw.
            end
            blocks[#blocks + 1] = {
                type = "tool_use",
                id = tc.id,
                name = fn.name or tc.name,
                input = (type(args) == "table") and args or {},
            }
        end
        return { role = "assistant", content = blocks }
    end

    -- Simple text message.
    return {
        role = role,
        content = (type(m.content) == "string") and m.content or "",
    }
end

local function anthropic_convert_tools(tools)
    if not tools or #tools == 0 then return nil end
    local out = {}
    for i = 1, #tools do
        local t = tools[i]
        local fn = t["function"] or t
        out[i] = {
            name = fn.name,
            description = fn.description,
            input_schema = fn.parameters or { type = "object", properties = {} },
        }
    end
    return out
end

local function anthropic_parse_response(decoded)
    if type(decoded) ~= "table" then
        return nil, "response was not a table"
    end
    if decoded.error then
        local msg = "unknown error"
        if type(decoded.error) == "table" then
            msg = decoded.error.message or msg
        else
            msg = tostring(decoded.error)
        end
        return { content = nil, tool_calls = nil, finish = "error", raw = decoded, error = msg }, nil
    end
    local content_blocks = decoded.content or {}
    local text_parts = {}
    local tool_calls = nil
    for i = 1, #content_blocks do
        local block = content_blocks[i]
        if block.type == "text" then
            text_parts[#text_parts + 1] = block.text or ""
        elseif block.type == "tool_use" then
            tool_calls = tool_calls or {}
            tool_calls[#tool_calls + 1] = {
                id = block.id,
                name = block.name,
                arguments = block.input or {},
            }
        end
    end
    local finish = decoded.stop_reason or "stop"
    if finish == "tool_use" then finish = "tool_calls" end
    if finish == "end_turn" then finish = "stop" end
    if finish == "max_tokens" then finish = "length" end
    return {
        content = (#text_parts > 0) and table.concat(text_parts) or nil,
        tool_calls = tool_calls,
        finish = finish,
        raw = decoded,
    }, nil
end

local function anthropic_make_adapter()
    return {
        name = "anthropic",
        chat = function(self, req, ctx)
            local base_url = self.base_url or "https://api.anthropic.com"
            local url = base_url:gsub("/$", "") .. "/v1/messages"
            local system_text, conv = anthropic_split_messages(req.messages)
            local converted = {}
            for i = 1, #conv do
                converted[i] = anthropic_convert_message(conv[i])
            end
            local payload = {
                model = req.model,
                messages = converted,
                max_tokens = req.max_tokens or 4096,
            }
            if system_text and system_text ~= "" then
                payload.system = system_text
            end
            local atools = anthropic_convert_tools(req.tools)
            if atools then payload.tools = atools end
            if req.temperature ~= nil then payload.temperature = req.temperature end
            if req.top_p ~= nil then payload.top_p = req.top_p end

            local body, err = util.safe_encode(ctx.json, payload)
            if not body then return nil, "failed to encode request: " .. tostring(err) end

            local headers = {
                ["Content-Type"] = "application/json",
                ["anthropic-version"] = self.anthropic_version or "2023-06-01",
            }
            if self.api_key and self.api_key ~= "" then
                headers["x-api-key"] = self.api_key
            end
            if self.extra_headers then
                for k, v in pairs(self.extra_headers) do headers[k] = v end
            end

            local resp_body, status = do_request(ctx.http, {
                url = url, method = "POST", headers = headers, body = body,
            })
            if not resp_body then
                return nil, "http error: " .. tostring(status)
            end
            local decoded, derr = util.safe_decode(ctx.json, resp_body)
            if not decoded then
                return nil, "failed to decode response: " .. tostring(derr)
            end
            return anthropic_parse_response(decoded)
        end,
    }
end

-- ============================================================
-- Gemini adapter (Google AI)
-- ============================================================

local GEMINI_ROLE_MAP = { user = "user", assistant = "model", system = "user", tool = "user" }

local function gemini_convert_messages(messages)
    -- Gemini takes systemInstruction separately and contents[] for the rest.
    local system_parts = {}
    local contents = {}
    for i = 1, #messages do
        local m = messages[i]
        if m.role == "system" then
            if type(m.content) == "string" then
                system_parts[#system_parts + 1] = m.content
            end
        elseif m.role == "tool" then
            contents[#contents + 1] = {
                role = "user",
                parts = {
                    {
                        functionResponse = {
                            name = m.name or "tool",
                            response = { content = (type(m.content) == "string") and m.content or "" },
                        },
                    },
                },
            }
        elseif m.role == "assistant" and type(m.tool_calls) == "table" and #m.tool_calls > 0 then
            local parts = {}
            if type(m.content) == "string" and m.content ~= "" then
                parts[#parts + 1] = { text = m.content }
            end
            for j = 1, #m.tool_calls do
                local tc = m.tool_calls[j]
                local fn = tc["function"] or { name = tc.name, arguments = tc.arguments }
                local fc_part = {
                    functionCall = {
                        name = fn.name or tc.name,
                        args = (type(fn.arguments) == "table") and fn.arguments or {},
                    },
                    thoughtSignature = tc.thought_signature or "skip_thought_signature_validator"
                }
                parts[#parts + 1] = fc_part
            end
            contents[#contents + 1] = { role = "model", parts = parts }
        else
            contents[#contents + 1] = {
                role = GEMINI_ROLE_MAP[m.role] or "user",
                parts = { { text = (type(m.content) == "string") and m.content or "" } },
            }
        end
    end
    local system_instr = nil
    if #system_parts > 0 then
        system_instr = { parts = { { text = table.concat(system_parts, "\n\n") } } }
    end
    return system_instr, contents
end

local function gemini_convert_tools(tools)
    if not tools or #tools == 0 then return nil end
    local declarations = {}
    for i = 1, #tools do
        local t = tools[i]
        local fn = t["function"] or t
        declarations[i] = {
            name = fn.name,
            description = fn.description,
            parameters = fn.parameters or { type = "object", properties = {} },
        }
    end
    return { { functionDeclarations = declarations } }
end

local function gemini_parse_response(decoded)
    if type(decoded) ~= "table" then
        return nil, "response was not a table"
    end
    if decoded.error then
        local msg = "unknown error"
        if type(decoded.error) == "table" then
            msg = decoded.error.message or msg
        else
            msg = tostring(decoded.error)
        end
        return { content = nil, tool_calls = nil, finish = "error", raw = decoded, error = msg }, nil
    end
    local candidates = decoded.candidates
    if type(candidates) ~= "table" or #candidates == 0 then
        return nil, "no candidates in response"
    end
    local cand = candidates[1]
    local content = cand.content or {}
    local parts = content.parts or {}
    local text_parts = {}
    local tool_calls = nil
    for i = 1, #parts do
        local p = parts[i]
        if p.text then
            text_parts[#text_parts + 1] = p.text
        elseif p.functionCall then
            tool_calls = tool_calls or {}
            tool_calls[#tool_calls + 1] = {
                id = "gemini_call_" .. tostring(#tool_calls + 1),
                name = p.functionCall.name,
                arguments = p.functionCall.args or {},
                thought_signature = p.thoughtSignature or p.thought_signature,
            }
        end
    end
    local finish = cand.finishReason or "STOP"
    if tool_calls then
        -- Tool-call presence wins over text finish reasons.
        finish = "tool_calls"
    elseif finish == "STOP" then finish = "stop"
    elseif finish == "MAX_TOKENS" then finish = "length"
    end
    return {
        content = (#text_parts > 0) and table.concat(text_parts) or nil,
        tool_calls = tool_calls,
        finish = finish,
        raw = decoded,
    }, nil
end

local function gemini_make_adapter()
    return {
        name = "gemini",
        chat = function(self, req, ctx)
            local base_url = self.base_url or "https://generativelanguage.googleapis.com"
            local model = req.model or "gemini-1.5-flash"
            local key = self.api_key or ""
            local url = string.format("%s/v1beta/models/%s:generateContent?key=%s",
                base_url:gsub("/$", ""), model, key)
            local system_instr, contents = gemini_convert_messages(req.messages)
            local payload = { contents = contents }
            if system_instr then payload.systemInstruction = system_instr end
            local gtools = gemini_convert_tools(req.tools)
            if gtools then payload.tools = gtools end
            local genconf = {}
            if req.temperature ~= nil then genconf.temperature = req.temperature end
            if req.max_tokens ~= nil then genconf.maxOutputTokens = req.max_tokens end
            if req.top_p ~= nil then genconf.topP = req.top_p end
            if next(genconf) then payload.generationConfig = genconf end

            local body, err = util.safe_encode(ctx.json, payload)
            if not body then return nil, "failed to encode request: " .. tostring(err) end
            body = string.gsub(body, '"args":%[%]', '"args":{}')
            body = string.gsub(body, '"properties":%[%]', '"properties":{}')
            local headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
            }
            if self.extra_headers then
                for k, v in pairs(self.extra_headers) do headers[k] = v end
            end
            local resp_body, status = do_request(ctx.http, {
                url = url, method = "POST", headers = headers, body = body,
            })
            if not resp_body then
                return nil, "http error: " .. tostring(status)
            end
            local decoded, derr = util.safe_decode(ctx.json, resp_body)
            if not decoded then
                return nil, "failed to decode response: " .. tostring(derr)
            end
            return gemini_parse_response(decoded)
        end,
    }
end

-- ============================================================
-- Ollama adapter (local server, /api/chat)
-- ============================================================

local function ollama_make_adapter()
    return {
        name = "ollama",
        chat = function(self, req, ctx)
            local base_url = self.base_url or "http://localhost:11434"
            local url = base_url:gsub("/$", "") .. "/api/chat"
            -- Ollama supports OpenAI-style messages and (in recent versions) tools.
            local payload = {
                model = req.model,
                messages = req.messages,
                stream = false,
            }
            if req.tools and #req.tools > 0 then
                payload.tools = req.tools
            end
            local options = {}
            if req.temperature ~= nil then options.temperature = req.temperature end
            if req.max_tokens ~= nil then options.num_predict = req.max_tokens end
            if next(options) then payload.options = options end

            local body, err = util.safe_encode(ctx.json, payload)
            if not body then return nil, "failed to encode request: " .. tostring(err) end

            local headers = { ["Content-Type"] = "application/json" }
            if self.extra_headers then
                for k, v in pairs(self.extra_headers) do headers[k] = v end
            end

            local resp_body, status = do_request(ctx.http, {
                url = url, method = "POST", headers = headers, body = body,
            })
            if not resp_body then
                return nil, "http error: " .. tostring(status)
            end
            local decoded, derr = util.safe_decode(ctx.json, resp_body)
            if not decoded then
                return nil, "failed to decode response: " .. tostring(derr)
            end
            if decoded.error then
                return { content = nil, tool_calls = nil, finish = "error",
                    raw = decoded, error = tostring(decoded.error) }, nil
            end
            local msg = decoded.message or {}
            local out = {
                content = msg.content,
                tool_calls = nil,
                finish = decoded.done_reason or "stop",
                raw = decoded,
            }
            if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
                out.tool_calls = {}
                for i = 1, #msg.tool_calls do
                    local tc = msg.tool_calls[i]
                    local fn = tc["function"] or {}
                    out.tool_calls[i] = {
                        id = tc.id or ("ollama_call_" .. tostring(i)),
                        name = fn.name,
                        arguments = (type(fn.arguments) == "table") and fn.arguments or {},
                    }
                end
                out.finish = "tool_calls"
            end
            return out, nil
        end,
    }
end

-- ============================================================
-- Adapter registry / factory
-- ============================================================

-- Pre-register built-in providers.
adapters.openai          = function() return openai_make_adapter("https://api.openai.com/v1") end
adapters.openrouter      = function() return openai_make_adapter("https://openrouter.ai/api/v1") end
adapters.generic_openai  = function() return openai_make_adapter("http://localhost:8000/v1") end
adapters.anthropic       = anthropic_make_adapter
adapters.gemini          = gemini_make_adapter
adapters.ollama          = ollama_make_adapter

-- Register a custom provider factory or adapter table.
function M.register(name, factory_or_adapter)
    if type(factory_or_adapter) == "function" then
        adapters[name] = factory_or_adapter
    elseif type(factory_or_adapter) == "table" then
        adapters[name] = function() return factory_or_adapter end
    else
        error("provider must be a function or table")
    end
end

function M.has(name)
    return adapters[name] ~= nil
end

-- Build a provider instance from an llm config block.
-- llm_config = { provider="openai", model=..., api_key=..., base_url=..., extra_headers=..., ... }
function M.build(llm_config)
    if type(llm_config) ~= "table" then
        return nil, "llm config must be a table"
    end
    local name = llm_config.provider
    if type(name) ~= "string" or name == "" then
        return nil, "llm.provider not set"
    end
    local factory = adapters[name]
    if not factory then
        return nil, "unknown provider: " .. name
    end
    local adapter = factory()
    if type(adapter) ~= "table" or type(adapter.chat) ~= "function" then
        return nil, "provider factory returned invalid adapter"
    end
    -- Copy llm_config fields onto the adapter instance so it can read api_key etc.
    for k, v in pairs(llm_config) do
        if k ~= "provider" then
            adapter[k] = v
        end
    end
    return adapter, nil
end

return M
