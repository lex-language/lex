// std/agent/agent.lex — Classe Agent base
//
// Um Agent é uma entidade autônoma que pode:
//   - Receber tarefas em linguagem natural
//   - Usar tools para realizar ações
//   - Manter memória de conversas
//   - Seguir instruções do system prompt
//
// Uso:
//   import { Agent, AgentConfig } from "std/agent"
//
//   const agent: Agent = new Agent("code-reviewer")
//   agent.setSystemPrompt("You are a code reviewer...")
//   agent.addTool(readFileTool)
//   const result: AgentResult = agent.run("Review main.lex")

import {
    Message, ToolCall, ToolResult, ToolSchema, ModelResponse,
    TokenUsage, StopReason,
    userMsg, assistantMsg, toolResultMsg
} from "../ai/types"

import { Claude } from "../ai/claude"
import { Tool, ToolRegistry } from "./tool"
import { ShortTermMemory, WorkingMemory, CompositeMemory, MemoryEntry } from "./memory"

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO DO AGENT
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração de um agent
class AgentConfig {
    name: string
    description: string
    model: string
    maxTurns: i64
    maxTokens: i64
    temperature: f64
    systemPrompt: string

    constructor() {
        this.name = "agent"
        this.description = ""
        this.model = "claude-sonnet-4-20250514"
        this.maxTurns = 10
        this.maxTokens = 4096
        this.temperature = 1.0
        this.systemPrompt = ""
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// RESULTADO DO AGENT
// ══════════════════════════════════════════════════════════════════════════════

/// Resultado de uma execução do agent
class AgentResult {
    success: bool
    content: string
    error: string
    turns: i64
    usage: TokenUsage
    toolCalls: ToolCall[]

    constructor() {
        this.success = false
        this.content = ""
        this.error = ""
        this.turns = 0
        this.usage = new TokenUsage()
        this.toolCalls = []
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// DECISÕES E AÇÕES
// ══════════════════════════════════════════════════════════════════════════════

/// Decisão sobre uma tool call
enum ToolCallDecision {
    Approve,
    Reject,
    Modify
}

/// Ação em caso de erro
enum ErrorAction {
    Fail,
    Retry,
    Skip,
    RetryAfter
}

/// Resposta de um hook de erro
class ErrorResponse {
    action: ErrorAction
    retryCount: i64
    retryAfterMs: i64

    constructor(action: ErrorAction) {
        this.action = action
        this.retryCount = 0
        this.retryAfterMs = 0
    }
}

fn failError(): ErrorResponse { return new ErrorResponse(ErrorAction.Fail) }
fn retryError(count: i64): ErrorResponse {
    const r: ErrorResponse = new ErrorResponse(ErrorAction.Retry)
    r.retryCount = count
    return r
}

// ══════════════════════════════════════════════════════════════════════════════
// AGENT
// ══════════════════════════════════════════════════════════════════════════════

/// Classe Agent principal
class Agent {
    config: AgentConfig
    tools: ToolRegistry
    memory: CompositeMemory
    provider: Claude

    // Estado interno
    private messages: Message[]
    private totalUsage: TokenUsage
    private currentTask: string

    constructor(name: string) {
        this.config = new AgentConfig()
        this.config.name = name
        this.tools = new ToolRegistry()
        this.memory = new CompositeMemory()
        this.provider = new Claude()
        this.messages = []
        this.totalUsage = new TokenUsage()
        this.currentTask = ""
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONFIGURAÇÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Define o system prompt
    setSystemPrompt(prompt: string): Agent {
        this.config.systemPrompt = prompt
        return this
    }

    /// Define a descrição
    setDescription(desc: string): Agent {
        this.config.description = desc
        return this
    }

    /// Define o modelo
    setModel(model: string): Agent {
        this.config.model = model
        return this
    }

    /// Define o máximo de turns
    setMaxTurns(turns: i64): Agent {
        this.config.maxTurns = turns
        return this
    }

    /// Adiciona uma tool
    addTool(tool: Tool): Agent {
        this.tools.register(tool)
        return this
    }

    /// Adiciona múltiplas tools
    addTools(tools: Tool[]): Agent {
        for (const t of tools) {
            this.tools.register(t)
        }
        return this
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EXECUÇÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Executa uma tarefa
    run(task: string): AgentResult! {
        return try this.runWithContext(task, "")
    }

    /// Executa com contexto adicional
    runWithContext(task: string, context: string): AgentResult! {
        this.currentTask = task
        this.messages = []

        // Chamar hook de início
        this.onStart(task)

        // Preparar mensagem inicial
        let fullTask: string = task
        if (len(context) > 0) {
            fullTask = `${context}\n\nTask: ${task}`
        }

        // Adicionar contexto da memória
        const relevantMemory: MemoryEntry[] = this.memory.longTerm.search(task, 3)
        if (relevantMemory.len() > 0) {
            let memoryContext: string = "Relevant information from memory:\n"
            for (const entry of relevantMemory) {
                memoryContext = concat(memoryContext, `- ${entry.content}\n`)
            }
            fullTask = concat(memoryContext, `\n${fullTask}`)
        }

        this.messages.push(userMsg(fullTask))

        // Loop de execução
        let result: AgentResult = new AgentResult()
        let turn: i64 = 0

        while (turn < this.config.maxTurns) {
            // Chamar modelo
            const response: ModelResponse = try this.callModel()

            // Atualizar usage
            this.totalUsage.inputTokens = this.totalUsage.inputTokens + response.usage.inputTokens
            this.totalUsage.outputTokens = this.totalUsage.outputTokens + response.usage.outputTokens

            // Chamar hook de resposta
            this.onModelResponse(response)

            // Processar resposta
            if (!response.hasToolCalls()) {
                // Sem tool calls = resposta final
                result.success = true
                result.content = response.content
                result.turns = turn + 1
                result.usage = this.totalUsage

                // Salvar na memória
                this.memory.addMessage("assistant", response.content)

                // Chamar hook de conclusão
                this.onComplete(result)

                return result
            }

            // Processar tool calls
            this.messages.push(assistantMsg(response.content))

            for (const call of response.toolCalls) {
                result.toolCalls.push(call)

                // Chamar hook de tool call
                const decision: ToolCallDecision = this.onToolCall(call.name, call.input)

                if (decision == ToolCallDecision.Reject) {
                    // Rejeitado - enviar erro para o modelo
                    this.messages.push(toolResultMsg(call.id, call.name, `{"error": "Tool call rejected"}`))
                    continue
                }

                // Executar tool
                const startTime: i64 = now()
                const toolResult: ToolResult = this.tools.executeCall(call)
                const duration: i64 = now() - startTime

                // Chamar hook de resultado
                this.onToolResult(call.name, toolResult, duration)

                // Adicionar resultado às mensagens
                this.messages.push(toolResultMsg(call.id, call.name, toolResult.output))
            }

            turn = turn + 1
        }

        // Max turns atingido
        result.success = false
        result.error = "Maximum turns exceeded"
        result.turns = turn
        result.usage = this.totalUsage

        return result
    }

    /// Chama o modelo
    private callModel(): ModelResponse! {
        return try this.provider.chatWithSystem(
            this.config.systemPrompt,
            this.messages,
            this.tools.getSchemas()
        )
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CHAT INTERATIVO
    // ══════════════════════════════════════════════════════════════════════════

    /// Inicia uma sessão de chat
    chat(message: string): string! {
        // Adicionar mensagem do usuário
        this.messages.push(userMsg(message))
        this.memory.addMessage("user", message)

        // Executar um turno
        let turn: i64 = 0
        while (turn < this.config.maxTurns) {
            const response: ModelResponse = try this.callModel()

            if (!response.hasToolCalls()) {
                // Resposta final
                this.messages.push(assistantMsg(response.content))
                this.memory.addMessage("assistant", response.content)
                return response.content
            }

            // Processar tool calls
            this.messages.push(assistantMsg(response.content))

            for (const call of response.toolCalls) {
                const toolResult: ToolResult = this.tools.executeCall(call)
                this.messages.push(toolResultMsg(call.id, call.name, toolResult.output))
            }

            turn = turn + 1
        }

        fail 1  // Max turns
    }

    /// Reseta o histórico de chat
    resetChat() {
        this.messages = []
    }

    /// Obtém o histórico de mensagens
    getHistory(): Message[] {
        return this.messages
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HOOKS (sobrescrever em subclasses)
    // ══════════════════════════════════════════════════════════════════════════

    /// Chamado no início de uma execução
    onStart(task: string) {
        // Override em subclasses
    }

    /// Chamado antes de cada tool call
    onToolCall(name: string, input: string): ToolCallDecision {
        // Override em subclasses
        return ToolCallDecision.Approve
    }

    /// Chamado após cada tool call
    onToolResult(name: string, result: ToolResult, durationMs: i64) {
        // Override em subclasses
    }

    /// Chamado após cada resposta do modelo
    onModelResponse(response: ModelResponse) {
        // Override em subclasses
    }

    /// Chamado em caso de erro
    onError(error: string): ErrorResponse {
        // Override em subclasses
        return failError()
    }

    /// Chamado ao completar uma execução
    onComplete(result: AgentResult) {
        // Override em subclasses
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// AGENT BUILDER
// ══════════════════════════════════════════════════════════════════════════════

/// Builder para criar agents de forma fluente
class AgentBuilder {
    private agent: Agent

    constructor(name: string) {
        this.agent = new Agent(name)
    }

    /// Define descrição
    describe(desc: string): AgentBuilder {
        this.agent.setDescription(desc)
        return this
    }

    /// Define system prompt
    system(prompt: string): AgentBuilder {
        this.agent.setSystemPrompt(prompt)
        return this
    }

    /// Define modelo
    model(model: string): AgentBuilder {
        this.agent.setModel(model)
        return this
    }

    /// Define max turns
    maxTurns(turns: i64): AgentBuilder {
        this.agent.setMaxTurns(turns)
        return this
    }

    /// Adiciona tool
    tool(t: Tool): AgentBuilder {
        this.agent.addTool(t)
        return this
    }

    /// Adiciona múltiplas tools
    tools(ts: Tool[]): AgentBuilder {
        this.agent.addTools(ts)
        return this
    }

    /// Constrói o agent
    build(): Agent {
        return this.agent
    }
}

/// Inicia um builder de agent
fn agent(name: string): AgentBuilder {
    return new AgentBuilder(name)
}

// ══════════════════════════════════════════════════════════════════════════════
// AGENTS PREDEFINIDOS
// ══════════════════════════════════════════════════════════════════════════════

/// Cria um agent simples de chat
fn createChatAgent(name: string, systemPrompt: string): Agent {
    return agent(name)
        .describe("A helpful chat assistant")
        .system(systemPrompt)
        .build()
}

/// Cria um agent de código com tools de filesystem
fn createCodeAgent(name: string): Agent {
    import { createFileSystemTools } from "./tool"

    const fsTools: ToolRegistry = createFileSystemTools()

    return agent(name)
        .describe("A coding assistant that can read and write files")
        .system(`You are a helpful coding assistant. You can read and write files to help users with their code.

When reviewing code:
1. First read the file to understand the code
2. Identify issues and suggest improvements
3. Write back the improved code if requested

Be concise and precise in your responses.`)
        .tools(fsTools.tools)
        .build()
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

declare function now(): i64;
