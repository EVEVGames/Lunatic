-- spec/provider_spec.lua
-- Tests for lunatic.provider adapters. We mock the http layer with a
-- function that captures the outgoing request and returns canned responses,
-- so we can verify each adapter's request/response normalisation.

local t        = require("spec.support.runner")
local helpers  = require("spec.support.helpers")
local provider = require("lunatic.provider")

local describe, it, expect = t.describe, t.it, t.expect

-- Build a mock http that records outgoing requests and replays a script.
local function make_mock_http(script)
    local idx = 0
    local recorded = {}
    return function(opts)
        idx = idx + 1
        recorded[idx] = opts
        local resp = script[idx] or '{"error":"end of script"}'
        if type(resp) == "function" then return resp(opts) end
        return resp, 200
    end, recorded
end

local function build(name, script, llm_extra)
    local http, recorded = make_mock_http(script)
    local llm = { provider = name, model = "test-model", api_key = "key-x" }
    if llm_extra then
        for k, v in pairs(llm_extra) do llm[k] = v end
    end
    local p, err = provider.build(llm)
    if not p then error("build " .. name .. " failed: " .. tostring(err)) end
    return p, http, recorded
end

local ctx = function() return { http = (function() end), json = helpers.fake_json } end

describe("provider.has", function()
    it("knows about all built-in adapter names", function()
        for _, n in ipairs({ "openai", "openrouter", "generic_openai",
                             "anthropic", "gemini", "ollama" }) do
            expect(provider.has(n)):truthy()
        end
    end)

    it("returns false for unknown name", function()
        expect(provider.has("nonexistent")):falsy()
    end)
end)

describe("provider.build: error paths", function()
    it("rejects missing config", function()
        local p, err = provider.build(nil)
        expect(p):nil_()
        expect(err):not_nil()
    end)

    it("rejects missing provider name", function()
        local p, err = provider.build({})
        expect(p):nil_()
        expect(err):contains("provider")
    end)

    it("rejects unknown provider", function()
        local p, err = provider.build({ provider = "bogus" })
        expect(p):nil_()
        expect(err):contains("unknown")
    end)
end)

describe("provider.register", function()
    it("registers a custom adapter via factory function", function()
        provider.register("ptest1", function()
            return { name = "ptest1", chat = function() return {}, nil end }
        end)
        expect(provider.has("ptest1")):truthy()
    end)

    it("registers via direct adapter table", function()
        provider.register("ptest2",
            { name = "ptest2", chat = function() return {}, nil end })
        expect(provider.has("ptest2")):truthy()
    end)

    it("rejects bad payload", function()
        expect(function() provider.register("bad", 42) end):throws()
    end)
end)

-- ============================================================
-- OpenAI
-- ============================================================
describe("provider.openai: request shape", function()
    it("posts to /chat/completions with bearer token", function()
        local p, http, recorded = build("openai",
            { '{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}' })
        p:chat({
            messages = { { role = "user", content = "hi" } },
            model = "gpt-4o",
        }, { http = http, json = helpers.fake_json })
        local req = recorded[1]
        expect(req.url):contains("/chat/completions")
        expect(req.method):eq("POST")
        expect(req.headers["Authorization"]):contains("Bearer")
        expect(req.body):contains("\"messages\"")
        expect(req.body):contains("\"model\"")
    end)

    it("includes tools when provided", function()
        local p, http, recorded = build("openai",
            { '{"choices":[{"message":{"content":"x"},"finish_reason":"stop"}]}' })
        p:chat({
            messages = { { role = "user", content = "?" } },
            tools = { { type = "function",
                        ["function"] = { name = "echo",
                            parameters = { type = "object", properties = {} } } } },
        }, { http = http, json = helpers.fake_json })
        expect(recorded[1].body):contains("\"tools\"")
        expect(recorded[1].body):contains("echo")
    end)

    it("respects custom base_url", function()
        local p, http, recorded = build("openai",
            { '{"choices":[{"message":{"content":"x"},"finish_reason":"stop"}]}' },
            { base_url = "https://example.test/v1/" })
        p:chat({ messages = {}, model = "x" }, { http = http, json = helpers.fake_json })
        expect(recorded[1].url):eq("https://example.test/v1/chat/completions")
    end)
end)

describe("provider.openai: response parsing", function()
    it("extracts plain content", function()
        local p, http = build("openai",
            { '{"choices":[{"message":{"content":"plain answer"},"finish_reason":"stop"}]}' })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.content):eq("plain answer")
        expect(resp.finish):eq("stop")
        expect(resp.tool_calls):nil_()
    end)

    it("extracts tool_calls and decodes argument JSON", function()
        local body = '{"choices":[{"message":{"content":null,' ..
            '"tool_calls":[{"id":"call_1","type":"function",' ..
            '"function":{"name":"echo","arguments":"{\\"x\\":1}"}}]},' ..
            '"finish_reason":"tool_calls"}]}'
        local p, http = build("openai", { body })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.tool_calls):not_nil()
        expect(#resp.tool_calls):eq(1)
        expect(resp.tool_calls[1].name):eq("echo")
        expect(resp.tool_calls[1].arguments.x):eq(1)
        expect(resp.finish):eq("tool_calls")
    end)

    it("flags errors gracefully", function()
        local p, http = build("openai",
            { '{"error":{"message":"rate limited"}}' })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.finish):eq("error")
        expect(resp.error):contains("rate limited")
    end)

    it("returns nil + err on non-decodable body", function()
        local p, http = build("openai", { "<html>not json</html>" })
        local resp, err = p:chat({ messages = {} },
            { http = http, json = helpers.fake_json })
        expect(resp):nil_()
        expect(err):not_nil()
    end)
end)

-- ============================================================
-- Anthropic
-- ============================================================
describe("provider.anthropic", function()
    it("posts to /v1/messages and uses x-api-key", function()
        local body = '{"content":[{"type":"text","text":"hello"}],' ..
            '"stop_reason":"end_turn"}'
        local p, http, recorded = build("anthropic", { body })
        p:chat({
            messages = {
                { role = "system", content = "be brief" },
                { role = "user", content = "hi" },
            },
            model = "claude-3-5-sonnet",
        }, { http = http, json = helpers.fake_json })
        local req = recorded[1]
        expect(req.url):contains("/v1/messages")
        expect(req.headers["x-api-key"]):eq("key-x")
        expect(req.headers["anthropic-version"]):not_nil()
        -- system is split out into its own field, not a message
        expect(req.body):contains("\"system\"")
        expect(req.body):contains("be brief")
    end)

    it("converts tool_use blocks back to tool_calls in response", function()
        local body = '{"content":[' ..
            '{"type":"text","text":"thinking..."},' ..
            '{"type":"tool_use","id":"tu_1","name":"echo",' ..
                '"input":{"x":"y"}}' ..
            '],"stop_reason":"tool_use"}'
        local p, http = build("anthropic", { body })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.tool_calls):not_nil()
        expect(resp.tool_calls[1].name):eq("echo")
        expect(resp.tool_calls[1].arguments.x):eq("y")
        expect(resp.finish):eq("tool_calls")
    end)

    it("converts tool result messages to tool_result blocks", function()
        local body = '{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}'
        local p, http, recorded = build("anthropic", { body })
        p:chat({
            messages = {
                { role = "user", content = "x" },
                { role = "tool", tool_call_id = "tu_1",
                  name = "echo", content = "result here" },
            },
            model = "claude-3-5-sonnet",
        }, { http = http, json = helpers.fake_json })
        local sent = recorded[1].body
        expect(sent):contains("tool_result")
        expect(sent):contains("result here")
    end)
end)

-- ============================================================
-- Gemini
-- ============================================================
describe("provider.gemini", function()
    it("uses key= query param and v1beta path", function()
        local body = '{"candidates":[{"content":{"parts":[{"text":"hi"}]},' ..
            '"finishReason":"STOP"}]}'
        local p, http, recorded = build("gemini", { body }, { api_key = "g-key" })
        p:chat({
            messages = { { role = "user", content = "hi" } },
            model = "gemini-1.5-flash",
        }, { http = http, json = helpers.fake_json })
        local req = recorded[1]
        expect(req.url):contains("/v1beta/models/gemini-1.5-flash:generateContent")
        expect(req.url):contains("key=g-key")
    end)

    it("converts assistant role to model and system to systemInstruction", function()
        local body = '{"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"STOP"}]}'
        local p, http, recorded = build("gemini", { body })
        p:chat({
            messages = {
                { role = "system", content = "be brief" },
                { role = "user", content = "q" },
                { role = "assistant", content = "a" },
            },
        }, { http = http, json = helpers.fake_json })
        local sent = recorded[1].body
        expect(sent):contains("systemInstruction")
        expect(sent):contains("be brief")
        expect(sent):contains("\"role\":\"model\"")
    end)

    it("extracts functionCall blocks as tool_calls", function()
        local body = '{"candidates":[{"content":{"parts":[' ..
            '{"functionCall":{"name":"f","args":{"a":1}}}' ..
            ']},"finishReason":"STOP"}]}'
        local p, http = build("gemini", { body })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.tool_calls):not_nil()
        expect(resp.tool_calls[1].name):eq("f")
        expect(resp.tool_calls[1].arguments.a):eq(1)
        expect(resp.finish):eq("tool_calls")
    end)
end)

-- ============================================================
-- Ollama
-- ============================================================
describe("provider.ollama", function()
    it("posts to /api/chat with no auth header by default", function()
        local body = '{"message":{"role":"assistant","content":"hi"},"done_reason":"stop"}'
        local p, http, recorded = build("ollama", { body }, { api_key = nil })
        p:chat({
            messages = { { role = "user", content = "hi" } },
            model = "llama3.2",
        }, { http = http, json = helpers.fake_json })
        expect(recorded[1].url):contains("/api/chat")
        expect(recorded[1].headers["Authorization"]):nil_()
    end)

    it("extracts simple text response", function()
        local body = '{"message":{"role":"assistant","content":"yo"},"done_reason":"stop"}'
        local p, http = build("ollama", { body })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.content):eq("yo")
    end)

    it("extracts tool_calls when present", function()
        local body = '{"message":{"role":"assistant","content":"",' ..
            '"tool_calls":[{"function":{"name":"echo","arguments":{"x":1}}}]},' ..
            '"done_reason":"stop"}'
        local p, http = build("ollama", { body })
        local resp = p:chat({ messages = {} }, { http = http, json = helpers.fake_json })
        expect(resp.tool_calls):not_nil()
        expect(resp.tool_calls[1].name):eq("echo")
        expect(resp.finish):eq("tool_calls")
    end)
end)
