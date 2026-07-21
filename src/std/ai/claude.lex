// std/ai/claude.lex — Provider para Claude (Anthropic)
//
// Implementa a API de mensagens do Claude:
// https://docs.anthropic.com/en/api/messages
//
// Uso:
//   import { Claude } from "std/ai/claude"
//
//   const response: string = Claude.complete("Olá!")
//   const structured: MyType = Claude.generate<MyType>(prompt)
//
// Features:
//   - Completions simples e com tools
//   - Streaming
//   - Structured output via tool_choice
//   - Retry automático com backoff

import {
    Message, ToolCall, ToolResult, ToolSchema, ModelResponse, ModelConfig,
    TokenUsage, StopReason, StreamEvent, StreamEventType, AIError,
    userMsg, assistantMsg, systemMsg, toolResultMsg,
    messageToJSON, messagesToJSON, toolSchemasToJSON,
    strToStopReason, claudeDefaultConfig
} from "./types"

import {
    HTTPClient, HTTPResponse, HTTPHeader,
    anthropicHeaders, jsonContentType
} from "./http"

import { jParse, jGet, jStr, jNum, jArr, JObj, JArr, JStr, JNum, Json } from "../../tools/json"

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração do Claude
class ClaudeConfig {
    apiKey: string
    baseUrl: string
    version: string
    model: string
    maxTokens: i64
    temperature: f64

    constructor() {
        this.apiKey = ""
        this.baseUrl = "https://api.anthropic.com/v1"
        this.version = "2023-06-01"
        this.model = "claude-sonnet-4-20250514"
        this.maxTokens = 4096
        this.temperature = 1.0
    }
}

// Configuração global
let claudeConfig: ClaudeConfig = new ClaudeConfig()

/// Configura o cliente Claude
fn configureClaude(apiKey: string) {
    claudeConfig.apiKey = apiKey
}

/// Configura com config completo
fn configureClaudeFull(config: ClaudeConfig) {
    claudeConfig = config
}

// ══════════════════════════════════════════════════════════════════════════════
// PROVIDER CLAUDE
// ══════════════════════════════════════════════════════════════════════════════

/// Provider principal para Claude
class Claude {
    config: ClaudeConfig
    client: HTTPClient

    constructor() {
        this.config = claudeConfig
        this.client = new HTTPClient()
    }

    /// Construtor com API key
    static withKey(apiKey: string): Claude {
        const c: Claude = new Claude()
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
        msgs.push(userMsg(prompt))
        const response: ModelResponse = try this.chatWithSystem(system, msgs, [])
        return response.content
    }

    /// Chat com histórico de mensagens
    chat(messages: Message[], tools: ToolSchema[]): ModelResponse! {
        return try this.chatWithSystem("", messages, tools)
    }

    /// Chat com system prompt
    chatWithSystem(system: string, messages: Message[], tools: ToolSchema[]): ModelResponse! {
        // Construir request body
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)

        if (this.config.temperature != 1.0) {
            body = concat(body, `,"temperature":${this.config.temperature}`)
        }

        if (len(system) > 0) {
            body = concat(body, `,"system":"${jEscape(system)}"`)
        }

        // Mensagens
        body = concat(body, `,"messages":${this.messagesToClaudeJSON(messages)}`)

        // Tools
        if (tools.len() > 0) {
            body = concat(body, `,"tools":${toolSchemasToJSON(tools)}`)
        }

        body = concat(body, "}")

        // Fazer request
        const url: string = concat(this.config.baseUrl, "/messages")
        const headers: HTTPHeader[] = anthropicHeaders(this.config.apiKey, this.config.version)

        const httpResponse: HTTPResponse = this.client.post(url, body, headers)

        if (!httpResponse.ok()) {
            fail this.parseError(httpResponse)
        }

        return this.parseResponse(httpResponse.body)
    }

    /// Chat com tool calling automático
    chatWithTools(
        system: string,
        messages: Message[],
        tools: ToolSchema[],
        executeTool: (ToolCall) => ToolResult
    ): ModelResponse! {
        let currentMessages: Message[] = messages
        let maxIterations: i64 = 10
        let iteration: i64 = 0

        while (iteration < maxIterations) {
            const response: ModelResponse = try this.chatWithSystem(system, currentMessages, tools)

            // Se não há tool calls, retorna
            if (!response.hasToolCalls()) {
                return response
            }

            // Adiciona resposta do assistente
            currentMessages.push(assistantMsg(response.content))

            // Executa cada tool call
            for (const tc of response.toolCalls) {
                const result: ToolResult = executeTool(tc)
                currentMessages.push(toolResultMsg(tc.id, tc.name, result.output))
            }

            iteration = iteration + 1
        }

        fail 1  // Max iterations exceeded
    }

    /// Structured output via tool use
    generateJSON(prompt: string, schema: ToolSchema): string! {
        let tools: ToolSchema[] = []
        tools.push(schema)

        let msgs: Message[] = []
        msgs.push(userMsg(prompt))

        // Forçar uso da tool
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)
        body = concat(body, `,"messages":${this.messagesToClaudeJSON(msgs)}`)
        body = concat(body, `,"tools":${toolSchemasToJSON(tools)}`)
        body = concat(body, `,"tool_choice":{"type":"tool","name":"${schema.name}"}`)
        body = concat(body, "}")

        const url: string = concat(this.config.baseUrl, "/messages")
        const headers: HTTPHeader[] = anthropicHeaders(this.config.apiKey, this.config.version)

        const httpResponse: HTTPResponse = this.client.post(url, body, headers)

        if (!httpResponse.ok()) {
            fail this.parseError(httpResponse)
        }

        const response: ModelResponse = this.parseResponse(httpResponse.body)

        // Extrair o input da tool call
        if (response.toolCalls.len() > 0) {
            return response.toolCalls[0].input
        }

        fail 2  // No tool call in response
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING
    // ══════════════════════════════════════════════════════════════════════════

    /// Stream de resposta
    stream(messages: Message[], tools: ToolSchema[], onEvent: (StreamEvent) => void): ModelResponse! {
        return try this.streamWithSystem("", messages, tools, onEvent)
    }

    /// Stream com system prompt
    streamWithSystem(
        system: string,
        messages: Message[],
        tools: ToolSchema[],
        onEvent: (StreamEvent) => void
    ): ModelResponse! {
        // Construir request body (igual ao chat, mas com stream: true)
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)
        body = concat(body, `,"max_tokens":${this.config.maxTokens}`)
        body = concat(body, `,"stream":true`)

        if (len(system) > 0) {
            body = concat(body, `,"system":"${jEscape(system)}"`)
        }

        body = concat(body, `,"messages":${this.messagesToClaudeJSON(messages)}`)

        if (tools.len() > 0) {
            body = concat(body, `,"tools":${toolSchemasToJSON(tools)}`)
        }

        body = concat(body, "}")

        // Fazer request com streaming
        const url: string = concat(this.config.baseUrl, "/messages")
        const headers: HTTPHeader[] = anthropicHeaders(this.config.apiKey, this.config.version)

        // Acumular resposta
        let finalResponse: ModelResponse = new ModelResponse()
        let currentText: string = ""
        let currentToolCalls: ToolCall[] = []

        // Parser de SSE
        const parseChunk = (chunk: string) => {
            const lines: string[] = split(chunk, "\n")
            for (const line of lines) {
                if (startsWith(line, "data: ")) {
                    const data: string = substring(line, 6, len(line))
                    if (!strEq(data, "[DONE]")) {
                        const event: StreamEvent = this.parseStreamEvent(data)
                        onEvent(event)

                        // Acumular texto
                        if (event.eventType == StreamEventType.ContentBlockDelta) {
                            currentText = concat(currentText, event.text)
                        }

                        // Acumular tool calls
                        if (event.eventType == StreamEventType.ContentBlockStart) {
                            if (len(event.toolCall.id) > 0) {
                                currentToolCalls.push(event.toolCall)
                            }
                        }

                        // Capturar stop reason e usage
                        if (event.eventType == StreamEventType.MessageDelta) {
                            finalResponse.stopReason = event.stopReason
                            finalResponse.usage = event.usage
                        }
                    }
                }
            }
        }

        this.client.postStream(url, body, headers, parseChunk)

        finalResponse.content = currentText
        finalResponse.toolCalls = currentToolCalls

        return finalResponse
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PARSING
    // ══════════════════════════════════════════════════════════════════════════

    /// Converte mensagens para formato Claude
    private messagesToClaudeJSON(messages: Message[]): string {
        let json: string = "["
        let first: bool = true

        for (const m of messages) {
            if (!first) { json = concat(json, ","); }
            first = false

            // Claude usa formato diferente para tool results
            if (m.role == Role.Tool) {
                json = concat(json, `{"role":"user","content":[{"type":"tool_result","tool_use_id":"${jEscape(m.toolCallId)}","content":"${jEscape(m.content)}"}]}`)
            } else {
                json = concat(json, `{"role":"${roleToStr(m.role)}","content":"${jEscape(m.content)}"}`)
            }
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

        // Stop reason
        response.stopReason = strToStopReason(jStr(jGet(json, "stop_reason")))

        // Usage
        const usage: Json = jGet(json, "usage")
        response.usage.inputTokens = jNum(jGet(usage, "input_tokens"))
        response.usage.outputTokens = jNum(jGet(usage, "output_tokens"))

        // Content (array de blocos)
        const content: Json[] = jArr(jGet(json, "content"))
        for (const block of content) {
            const blockType: string = jStr(jGet(block, "type"))

            if (strEq(blockType, "text")) {
                response.content = concat(response.content, jStr(jGet(block, "text")))
            } else if (strEq(blockType, "tool_use")) {
                const tc: ToolCall = new ToolCall(
                    jStr(jGet(block, "id")),
                    jStr(jGet(block, "name")),
                    jsonStringify(jGet(block, "input"))
                )
                response.toolCalls.push(tc)
            }
        }

        return response
    }

    /// Parseia evento de streaming
    private parseStreamEvent(data: string): StreamEvent {
        const json: Json = jParse(data)
        const eventType: string = jStr(jGet(json, "type"))

        let event: StreamEvent = new StreamEvent(StreamEventType.MessageStart)

        if (strEq(eventType, "message_start")) {
            event.eventType = StreamEventType.MessageStart
        } else if (strEq(eventType, "content_block_start")) {
            event.eventType = StreamEventType.ContentBlockStart
            event.index = jNum(jGet(json, "index"))

            const contentBlock: Json = jGet(json, "content_block")
            const blockType: string = jStr(jGet(contentBlock, "type"))

            if (strEq(blockType, "tool_use")) {
                event.toolCall = new ToolCall(
                    jStr(jGet(contentBlock, "id")),
                    jStr(jGet(contentBlock, "name")),
                    ""
                )
            }
        } else if (strEq(eventType, "content_block_delta")) {
            event.eventType = StreamEventType.ContentBlockDelta
            event.index = jNum(jGet(json, "index"))

            const delta: Json = jGet(json, "delta")
            const deltaType: string = jStr(jGet(delta, "type"))

            if (strEq(deltaType, "text_delta")) {
                event.text = jStr(jGet(delta, "text"))
            } else if (strEq(deltaType, "input_json_delta")) {
                event.text = jStr(jGet(delta, "partial_json"))
            }
        } else if (strEq(eventType, "content_block_stop")) {
            event.eventType = StreamEventType.ContentBlockStop
            event.index = jNum(jGet(json, "index"))
        } else if (strEq(eventType, "message_delta")) {
            event.eventType = StreamEventType.MessageDelta

            const delta: Json = jGet(json, "delta")
            event.stopReason = strToStopReason(jStr(jGet(delta, "stop_reason")))

            const usage: Json = jGet(json, "usage")
            event.usage.outputTokens = jNum(jGet(usage, "output_tokens"))
        } else if (strEq(eventType, "message_stop")) {
            event.eventType = StreamEventType.MessageStop
        } else if (strEq(eventType, "error")) {
            event.eventType = StreamEventType.Error
            event.error = jStr(jGet(jGet(json, "error"), "message"))
        }

        return event
    }

    /// Parseia erro da API
    private parseError(response: HTTPResponse): i64 {
        // TODO: retornar AIError estruturado
        Terminal.error(`Claude API error (${response.statusCode}): ${response.body}`)
        return response.statusCode
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// FUNÇÕES DE CONVENIÊNCIA
// ══════════════════════════════════════════════════════════════════════════════

/// Completion rápida com Claude
fn claudeComplete(prompt: string): string! {
    const claude: Claude = new Claude()
    return try claude.complete(prompt)
}

/// Completion com API key específica
fn claudeCompleteWithKey(apiKey: string, prompt: string): string! {
    const claude: Claude = Claude.withKey(apiKey)
    return try claude.complete(prompt)
}

/// Chat rápido
fn claudeChat(messages: Message[]): ModelResponse! {
    const claude: Claude = new Claude()
    return try claude.chat(messages, [])
}

// ══════════════════════════════════════════════════════════════════════════════
// DECLARAÇÕES EXTERNAS
// ══════════════════════════════════════════════════════════════════════════════

declare function jEscape(s: string): string;
declare function jsonStringify(j: Json): string;
declare function startsWith(s: string, prefix: string): bool;

// Importar Role de types (necessário para referência)
import { Role, roleToStr } from "./types"
