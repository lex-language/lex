// std/ai/openai.lex — Provider para OpenAI
//
// Implementa a API de chat completions do OpenAI:
// https://platform.openai.com/docs/api-reference/chat
//
// Uso:
//   import { OpenAI } from "std/ai/openai"
//
//   const response: string = OpenAI.complete("Olá!")

import {
    Message, ToolCall, ToolResult, ToolSchema, ModelResponse, ModelConfig,
    TokenUsage, StopReason, StreamEvent, StreamEventType, AIError,
    userMsg, assistantMsg, systemMsg, toolResultMsg,
    messageToJSON, messagesToJSON, toolSchemasToJSON,
    strToStopReason, openaiDefaultConfig, Role, roleToStr
} from "./types"

import {
    HTTPClient, HTTPResponse, HTTPHeader,
    openaiHeaders, jsonContentType
} from "./http"

import { jParse, jGet, jStr, jNum, jArr, JObj, JArr, JStr, JNum, Json } from "../../tools/json"

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração do OpenAI
class OpenAIConfig {
    apiKey: string
    baseUrl: string
    organization: string
    model: string
    maxTokens: i64
    temperature: f64

    constructor() {
        this.apiKey = ""
        this.baseUrl = "https://api.openai.com/v1"
        this.organization = ""
        this.model = "gpt-4o"
        this.maxTokens = 4096
        this.temperature = 1.0
    }
}

// Configuração global
let openaiConfig: OpenAIConfig = new OpenAIConfig()

/// Configura o cliente OpenAI
fn configureOpenAI(apiKey: string) {
    openaiConfig.apiKey = apiKey
}

/// Configura com config completo
fn configureOpenAIFull(config: OpenAIConfig) {
    openaiConfig = config
}

// ══════════════════════════════════════════════════════════════════════════════
// PROVIDER OPENAI
// ══════════════════════════════════════════════════════════════════════════════

/// Provider principal para OpenAI
class OpenAI {
    config: OpenAIConfig
    client: HTTPClient

    constructor() {
        this.config = openaiConfig
        this.client = new HTTPClient()
    }

    /// Construtor com API key
    static withKey(apiKey: string): OpenAI {
        const c: OpenAI = new OpenAI()
        c.config.apiKey = apiKey
        return c
    }

    /// Completion simples (string -> string)
    complete(prompt: string): string! {
        let msgs: Message[] = []
        msgs.push(userMsg(prompt))
        const response: ModelResponse = try this.chat(msgs, [])
        return response.content
    }

    /// Completion com system prompt
    completeWithSystem(system: string, prompt: string): string! {
        let msgs: Message[] = []
        msgs.push(systemMsg(system))
        msgs.push(userMsg(prompt))
        const response: ModelResponse = try this.chat(msgs, [])
        return response.content
    }

    /// Chat com histórico de mensagens
    chat(messages: Message[], tools: ToolSchema[]): ModelResponse! {
        // Construir request body
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)

        if (this.config.temperature != 1.0) {
            body = concat(body, `,"temperature":${this.config.temperature}`)
        }

        // Mensagens
        body = concat(body, `,"messages":${this.messagesToOpenAIJSON(messages)}`)

        // Tools (OpenAI usa formato diferente)
        if (tools.len() > 0) {
            body = concat(body, `,"tools":${this.toolsToOpenAIJSON(tools)}`)
        }

        body = concat(body, "}")

        // Fazer request
        const url: string = concat(this.config.baseUrl, "/chat/completions")
        let headers: HTTPHeader[] = openaiHeaders(this.config.apiKey)

        if (len(this.config.organization) > 0) {
            headers.push(new HTTPHeader("OpenAI-Organization", this.config.organization))
        }

        const httpResponse: HTTPResponse = this.client.post(url, body, headers)

        if (!httpResponse.ok()) {
            fail this.parseError(httpResponse)
        }

        return this.parseResponse(httpResponse.body)
    }

    /// Chat com tool calling automático
    chatWithTools(
        messages: Message[],
        tools: ToolSchema[],
        executeTool: (ToolCall) => ToolResult
    ): ModelResponse! {
        let currentMessages: Message[] = messages
        let maxIterations: i64 = 10
        let iteration: i64 = 0

        while (iteration < maxIterations) {
            const response: ModelResponse = try this.chat(currentMessages, tools)

            // Se não há tool calls, retorna
            if (!response.hasToolCalls()) {
                return response
            }

            // Adiciona resposta do assistente com tool calls
            let assistantContent: string = response.content
            // TODO: adicionar tool calls ao content
            currentMessages.push(assistantMsg(assistantContent))

            // Executa cada tool call
            for (const tc of response.toolCalls) {
                const result: ToolResult = executeTool(tc)
                currentMessages.push(toolResultMsg(tc.id, tc.name, result.output))
            }

            iteration = iteration + 1
        }

        fail 1  // Max iterations exceeded
    }

    /// Structured output via JSON mode
    generateJSON(prompt: string): string! {
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)
        body = concat(body, `,"response_format":{"type":"json_object"}`)

        let msgs: Message[] = []
        msgs.push(userMsg(prompt))
        body = concat(body, `,"messages":${this.messagesToOpenAIJSON(msgs)}`)

        body = concat(body, "}")

        const url: string = concat(this.config.baseUrl, "/chat/completions")
        const headers: HTTPHeader[] = openaiHeaders(this.config.apiKey)

        const httpResponse: HTTPResponse = this.client.post(url, body, headers)

        if (!httpResponse.ok()) {
            fail this.parseError(httpResponse)
        }

        const response: ModelResponse = this.parseResponse(httpResponse.body)
        return response.content
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING
    // ══════════════════════════════════════════════════════════════════════════

    /// Stream de resposta
    stream(messages: Message[], tools: ToolSchema[], onEvent: (StreamEvent) => void): ModelResponse! {
        // Construir request body com stream: true
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)
        body = concat(body, `,"stream":true`)
        body = concat(body, `,"messages":${this.messagesToOpenAIJSON(messages)}`)

        if (tools.len() > 0) {
            body = concat(body, `,"tools":${this.toolsToOpenAIJSON(tools)}`)
        }

        body = concat(body, "}")

        const url: string = concat(this.config.baseUrl, "/chat/completions")
        const headers: HTTPHeader[] = openaiHeaders(this.config.apiKey)

        // Acumular resposta
        let finalResponse: ModelResponse = new ModelResponse()
        let currentText: string = ""

        const parseChunk = (chunk: string) => {
            const lines: string[] = split(chunk, "\n")
            for (const line of lines) {
                if (startsWith(line, "data: ")) {
                    const data: string = substring(line, 6, len(line))
                    if (!strEq(data, "[DONE]")) {
                        const event: StreamEvent = this.parseStreamEvent(data)
                        onEvent(event)

                        if (event.eventType == StreamEventType.ContentBlockDelta) {
                            currentText = concat(currentText, event.text)
                        }
                    }
                }
            }
        }

        this.client.postStream(url, body, headers, parseChunk)

        finalResponse.content = currentText
        return finalResponse
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PARSING
    // ══════════════════════════════════════════════════════════════════════════

    /// Converte mensagens para formato OpenAI
    private messagesToOpenAIJSON(messages: Message[]): string {
        let json: string = "["
        let first: bool = true

        for (const m of messages) {
            if (!first) { json = concat(json, ","); }
            first = false

            json = concat(json, `{"role":"${roleToStr(m.role)}","content":"${jEscape(m.content)}"`)

            if (m.role == Role.Tool && len(m.toolCallId) > 0) {
                json = concat(json, `,"tool_call_id":"${jEscape(m.toolCallId)}"`)
            }

            json = concat(json, "}")
        }

        return concat(json, "]")
    }

    /// Converte tools para formato OpenAI
    private toolsToOpenAIJSON(tools: ToolSchema[]): string {
        let json: string = "["
        let first: bool = true

        for (const t of tools) {
            if (!first) { json = concat(json, ","); }
            first = false

            json = concat(json, `{"type":"function","function":${t.toJSON()}}`)
        }

        return concat(json, "]")
    }

    /// Parseia resposta da API
    private parseResponse(body: string): ModelResponse {
        const response: ModelResponse = new ModelResponse()
        const json: Json = jParse(body)

        // ID
        response.id = jStr(jGet(json, "id"))

        // Model
        response.model = jStr(jGet(json, "model"))

        // Usage
        const usage: Json = jGet(json, "usage")
        response.usage.inputTokens = jNum(jGet(usage, "prompt_tokens"))
        response.usage.outputTokens = jNum(jGet(usage, "completion_tokens"))

        // Choices
        const choices: Json[] = jArr(jGet(json, "choices"))
        if (choices.len() > 0) {
            const choice: Json = choices[0]

            // Finish reason
            const finishReason: string = jStr(jGet(choice, "finish_reason"))
            if (strEq(finishReason, "stop")) {
                response.stopReason = StopReason.EndTurn
            } else if (strEq(finishReason, "tool_calls")) {
                response.stopReason = StopReason.ToolUse
            } else if (strEq(finishReason, "length")) {
                response.stopReason = StopReason.MaxTokens
            }

            // Message
            const message: Json = jGet(choice, "message")
            response.content = jStr(jGet(message, "content"))

            // Tool calls
            const toolCalls: Json[] = jArr(jGet(message, "tool_calls"))
            for (const tc of toolCalls) {
                const fn: Json = jGet(tc, "function")
                const toolCall: ToolCall = new ToolCall(
                    jStr(jGet(tc, "id")),
                    jStr(jGet(fn, "name")),
                    jStr(jGet(fn, "arguments"))
                )
                response.toolCalls.push(toolCall)
            }
        }

        return response
    }

    /// Parseia evento de streaming
    private parseStreamEvent(data: string): StreamEvent {
        const json: Json = jParse(data)
        let event: StreamEvent = new StreamEvent(StreamEventType.ContentBlockDelta)

        const choices: Json[] = jArr(jGet(json, "choices"))
        if (choices.len() > 0) {
            const choice: Json = choices[0]
            const delta: Json = jGet(choice, "delta")

            const content: string = jStr(jGet(delta, "content"))
            if (len(content) > 0) {
                event.text = content
            }

            // Tool calls in delta
            const toolCalls: Json[] = jArr(jGet(delta, "tool_calls"))
            if (toolCalls.len() > 0) {
                event.eventType = StreamEventType.ContentBlockStart
                const tc: Json = toolCalls[0]
                const fn: Json = jGet(tc, "function")
                event.toolCall = new ToolCall(
                    jStr(jGet(tc, "id")),
                    jStr(jGet(fn, "name")),
                    jStr(jGet(fn, "arguments"))
                )
            }

            // Finish reason
            const finishReason: string = jStr(jGet(choice, "finish_reason"))
            if (len(finishReason) > 0) {
                event.eventType = StreamEventType.MessageStop
            }
        }

        return event
    }

    /// Parseia erro da API
    private parseError(response: HTTPResponse): i64 {
        Terminal.error(`OpenAI API error (${response.statusCode}): ${response.body}`)
        return response.statusCode
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// FUNÇÕES DE CONVENIÊNCIA
// ══════════════════════════════════════════════════════════════════════════════

/// Completion rápida com OpenAI
fn openaiComplete(prompt: string): string! {
    const openai: OpenAI = new OpenAI()
    return try openai.complete(prompt)
}

/// Completion com API key específica
fn openaiCompleteWithKey(apiKey: string, prompt: string): string! {
    const openai: OpenAI = OpenAI.withKey(apiKey)
    return try openai.complete(prompt)
}

// ══════════════════════════════════════════════════════════════════════════════
// DECLARAÇÕES EXTERNAS
// ══════════════════════════════════════════════════════════════════════════════

declare function jEscape(s: string): string;
declare function startsWith(s: string, prefix: string): bool;
