// std/ai/types.lex — Tipos fundamentais para o sistema de AI
//
// Define as estruturas de dados usadas em toda a stack de AI:
// mensagens, tool calls, respostas, configurações, etc.

// ══════════════════════════════════════════════════════════════════════════════
// MENSAGENS
// ══════════════════════════════════════════════════════════════════════════════

/// Papel de uma mensagem na conversa
enum Role {
    User,
    Assistant,
    System,
    Tool
}

/// Converte Role para string (para JSON)
fn roleToStr(r: Role): string {
    match (r) {
        Role.User => "user",
        Role.Assistant => "assistant",
        Role.System => "system",
        Role.Tool => "tool"
    }
}

/// Converte string para Role
fn strToRole(s: string): Role {
    if (strEq(s, "user")) { return Role.User; }
    if (strEq(s, "assistant")) { return Role.Assistant; }
    if (strEq(s, "system")) { return Role.System; }
    if (strEq(s, "tool")) { return Role.Tool; }
    return Role.User;
}

/// Uma mensagem na conversa
class Message {
    role: Role
    content: string
    name: string           // Opcional: nome do tool para role=Tool
    toolCallId: string     // Opcional: ID do tool call para role=Tool

    constructor(role: Role, content: string) {
        this.role = role
        this.content = content
        this.name = ""
        this.toolCallId = ""
    }
}

/// Cria mensagem de usuário
fn userMsg(content: string): Message {
    return new Message(Role.User, content)
}

/// Cria mensagem de assistente
fn assistantMsg(content: string): Message {
    return new Message(Role.Assistant, content)
}

/// Cria mensagem de sistema
fn systemMsg(content: string): Message {
    return new Message(Role.System, content)
}

/// Cria mensagem de resultado de tool
fn toolResultMsg(toolCallId: string, name: string, content: string): Message {
    const m: Message = new Message(Role.Tool, content)
    m.toolCallId = toolCallId
    m.name = name
    return m
}

// ══════════════════════════════════════════════════════════════════════════════
// TOOL CALLS
// ══════════════════════════════════════════════════════════════════════════════

/// Uma chamada de tool feita pelo modelo
class ToolCall {
    id: string             // ID único da chamada
    name: string           // Nome da tool
    input: string          // JSON string dos argumentos

    constructor(id: string, name: string, input: string) {
        this.id = id
        this.name = name
        this.input = input
    }
}

/// Resultado de uma execução de tool
class ToolResult {
    toolCallId: string
    name: string
    output: string         // JSON string do resultado
    isError: bool

    constructor(toolCallId: string, name: string, output: string) {
        this.toolCallId = toolCallId
        this.name = name
        this.output = output
        this.isError = false
    }
}

/// Cria resultado de erro
fn toolError(toolCallId: string, name: string, error: string): ToolResult {
    const r: ToolResult = new ToolResult(toolCallId, name, error)
    r.isError = true
    return r
}

// ══════════════════════════════════════════════════════════════════════════════
// TOOL SCHEMA (JSON Schema para tools)
// ══════════════════════════════════════════════════════════════════════════════

/// Tipo de um parâmetro de tool
enum ParamType {
    String,
    Integer,
    Number,
    Boolean,
    Array,
    Object
}

fn paramTypeToStr(t: ParamType): string {
    match (t) {
        ParamType.String => "string",
        ParamType.Integer => "integer",
        ParamType.Number => "number",
        ParamType.Boolean => "boolean",
        ParamType.Array => "array",
        ParamType.Object => "object"
    }
}

/// Um parâmetro de uma tool
class ToolParam {
    name: string
    paramType: ParamType
    description: string
    required: bool
    defaultValue: string   // JSON string do valor default (vazio = sem default)
    enumValues: string[]   // Valores permitidos (vazio = qualquer)

    constructor(name: string, paramType: ParamType, description: string) {
        this.name = name
        this.paramType = paramType
        this.description = description
        this.required = true
        this.defaultValue = ""
        this.enumValues = []
    }
}

/// Schema completo de uma tool
class ToolSchema {
    name: string
    description: string
    params: ToolParam[]

    constructor(name: string, description: string) {
        this.name = name
        this.description = description
        this.params = []
    }

    /// Adiciona um parâmetro
    addParam(p: ToolParam): ToolSchema {
        this.params.push(p)
        return this
    }

    /// Gera JSON Schema (formato Anthropic/OpenAI)
    toJSON(): string {
        let props: string = ""
        let required: string = ""
        let firstProp: bool = true
        let firstReq: bool = true

        for (const p of this.params) {
            // Property
            if (!firstProp) { props = concat(props, ","); }
            firstProp = false

            let propDef: string = `"${p.name}":{"type":"${paramTypeToStr(p.paramType)}","description":"${jEscape(p.description)}"`

            // Enum values
            if (p.enumValues.len() > 0) {
                let enumStr: string = ""
                let firstEnum: bool = true
                for (const v of p.enumValues) {
                    if (!firstEnum) { enumStr = concat(enumStr, ","); }
                    firstEnum = false
                    enumStr = concat(enumStr, `"${jEscape(v)}"`)
                }
                propDef = concat(propDef, `,"enum":[${enumStr}]`)
            }

            propDef = concat(propDef, "}")
            props = concat(props, propDef)

            // Required
            if (p.required) {
                if (!firstReq) { required = concat(required, ","); }
                firstReq = false
                required = concat(required, `"${p.name}"`)
            }
        }

        return `{"name":"${jEscape(this.name)}","description":"${jEscape(this.description)}","input_schema":{"type":"object","properties":{${props}},"required":[${required}]}}`
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// RESPOSTAS DO MODELO
// ══════════════════════════════════════════════════════════════════════════════

/// Razão de parada do modelo
enum StopReason {
    EndTurn,           // Modelo terminou naturalmente
    ToolUse,           // Modelo quer chamar tools
    MaxTokens,         // Atingiu limite de tokens
    StopSequence,      // Encontrou sequência de parada
    Error              // Erro
}

fn stopReasonToStr(r: StopReason): string {
    match (r) {
        StopReason.EndTurn => "end_turn",
        StopReason.ToolUse => "tool_use",
        StopReason.MaxTokens => "max_tokens",
        StopReason.StopSequence => "stop_sequence",
        StopReason.Error => "error"
    }
}

fn strToStopReason(s: string): StopReason {
    if (strEq(s, "end_turn")) { return StopReason.EndTurn; }
    if (strEq(s, "tool_use")) { return StopReason.ToolUse; }
    if (strEq(s, "max_tokens")) { return StopReason.MaxTokens; }
    if (strEq(s, "stop_sequence")) { return StopReason.StopSequence; }
    return StopReason.Error;
}

/// Uso de tokens
class TokenUsage {
    inputTokens: i64
    outputTokens: i64

    constructor() {
        this.inputTokens = 0
        this.outputTokens = 0
    }

    total(): i64 {
        return this.inputTokens + this.outputTokens
    }
}

/// Resposta completa do modelo
class ModelResponse {
    id: string
    content: string
    toolCalls: ToolCall[]
    stopReason: StopReason
    usage: TokenUsage
    model: string

    constructor() {
        this.id = ""
        this.content = ""
        this.toolCalls = []
        this.stopReason = StopReason.EndTurn
        this.usage = new TokenUsage()
        this.model = ""
    }

    /// Verifica se há tool calls
    hasToolCalls(): bool {
        return this.toolCalls.len() > 0
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração para chamadas de modelo
class ModelConfig {
    model: string
    maxTokens: i64
    temperature: f64
    topP: f64
    topK: i64
    stopSequences: string[]
    systemPrompt: string

    constructor() {
        this.model = ""
        this.maxTokens = 4096
        this.temperature = 1.0
        this.topP = 1.0
        this.topK = 0
        this.stopSequences = []
        this.systemPrompt = ""
    }
}

/// Configuração padrão para Claude
fn claudeDefaultConfig(): ModelConfig {
    const c: ModelConfig = new ModelConfig()
    c.model = "claude-sonnet-4-20250514"
    c.maxTokens = 4096
    c.temperature = 1.0
    return c
}

/// Configuração padrão para OpenAI
fn openaiDefaultConfig(): ModelConfig {
    const c: ModelConfig = new ModelConfig()
    c.model = "gpt-4o"
    c.maxTokens = 4096
    c.temperature = 1.0
    return c
}

// ══════════════════════════════════════════════════════════════════════════════
// STREAMING EVENTS
// ══════════════════════════════════════════════════════════════════════════════

/// Tipo de evento de streaming
enum StreamEventType {
    MessageStart,
    ContentBlockStart,
    ContentBlockDelta,
    ContentBlockStop,
    MessageDelta,
    MessageStop,
    Error
}

/// Evento de streaming
class StreamEvent {
    eventType: StreamEventType
    index: i64             // Índice do content block
    text: string           // Texto delta (para ContentBlockDelta)
    toolCall: ToolCall     // Tool call (para ContentBlockStart com type=tool_use)
    stopReason: StopReason // Razão de parada (para MessageDelta)
    usage: TokenUsage      // Uso de tokens (para MessageDelta)
    error: string          // Mensagem de erro

    constructor(eventType: StreamEventType) {
        this.eventType = eventType
        this.index = 0
        this.text = ""
        this.toolCall = new ToolCall("", "", "")
        this.stopReason = StopReason.EndTurn
        this.usage = new TokenUsage()
        this.error = ""
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// ERROS
// ══════════════════════════════════════════════════════════════════════════════

/// Tipos de erro de AI
enum AIErrorKind {
    Network,           // Erro de rede
    RateLimit,         // Rate limit atingido
    InvalidRequest,    // Request inválida
    Authentication,    // Erro de autenticação
    ServerError,       // Erro do servidor
    Timeout,           // Timeout
    Unknown            // Erro desconhecido
}

/// Erro de AI
class AIError {
    kind: AIErrorKind
    message: string
    statusCode: i64
    retryAfter: i64    // Segundos para retry (se rate limit)

    constructor(kind: AIErrorKind, message: string) {
        this.kind = kind
        this.message = message
        this.statusCode = 0
        this.retryAfter = 0
    }
}

// Helpers para criar erros
fn networkError(msg: string): AIError {
    return new AIError(AIErrorKind.Network, msg)
}

fn rateLimitError(retryAfter: i64): AIError {
    const e: AIError = new AIError(AIErrorKind.RateLimit, "Rate limit exceeded")
    e.retryAfter = retryAfter
    return e
}

fn authError(msg: string): AIError {
    const e: AIError = new AIError(AIErrorKind.Authentication, msg)
    e.statusCode = 401
    return e
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS JSON
// ══════════════════════════════════════════════════════════════════════════════

// Usa jEscape do json.lex
declare function jEscape(s: string): string;

/// Converte Message para JSON
fn messageToJSON(m: Message): string {
    let json: string = `{"role":"${roleToStr(m.role)}","content":"${jEscape(m.content)}"`

    if (len(m.toolCallId) > 0) {
        json = concat(json, `,"tool_call_id":"${jEscape(m.toolCallId)}"`)
    }
    if (len(m.name) > 0) {
        json = concat(json, `,"name":"${jEscape(m.name)}"`)
    }

    return concat(json, "}")
}

/// Converte array de Messages para JSON
fn messagesToJSON(msgs: Message[]): string {
    let json: string = "["
    let first: bool = true

    for (const m of msgs) {
        if (!first) { json = concat(json, ","); }
        first = false
        json = concat(json, messageToJSON(m))
    }

    return concat(json, "]")
}

/// Converte array de ToolSchemas para JSON
fn toolSchemasToJSON(tools: ToolSchema[]): string {
    let json: string = "["
    let first: bool = true

    for (const t of tools) {
        if (!first) { json = concat(json, ","); }
        first = false
        json = concat(json, t.toJSON())
    }

    return concat(json, "]")
}
