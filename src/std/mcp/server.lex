// std/mcp/server.lex — MCP Server Implementation
//
// Implementa o Model Context Protocol (MCP) para expor tools como servidor.
// https://spec.modelcontextprotocol.io/
//
// Um MCP server pode ser usado por:
//   - Claude Desktop
//   - Cursor
//   - Qualquer cliente MCP
//
// Uso:
//   import { MCPServer } from "std/mcp/server"
//
//   const server: MCPServer = new MCPServer("my-tools")
//   server.addTool(readFileTool)
//   server.serve()  // Escuta em stdio

import { Tool, ToolRegistry, ToolSchema } from "../agent/tool"
import { ToolCall, ToolResult } from "../ai/types"
import { jParse, jGet, jStr, jNum, jArr, JObj, JArr, Json } from "../../tools/json"
import { read, write } from "../libc"

// ══════════════════════════════════════════════════════════════════════════════
// TIPOS MCP
// ══════════════════════════════════════════════════════════════════════════════

/// Versão do protocolo MCP
const MCP_VERSION: string = "2024-11-05"

/// Tipos de mensagem MCP
enum MCPMessageType {
    Request,
    Response,
    Notification
}

/// Uma mensagem MCP (JSON-RPC 2.0)
class MCPMessage {
    jsonrpc: string
    id: string              // Para requests/responses
    method: string          // Para requests/notifications
    params: Json            // Parâmetros
    result: Json            // Resultado (para responses)
    error: MCPError         // Erro (para responses)

    constructor() {
        this.jsonrpc = "2.0"
        this.id = ""
        this.method = ""
        this.params = new JNull()
        this.result = new JNull()
        this.error = new MCPError(0, "")
    }
}

/// Erro MCP
class MCPError {
    code: i64
    message: string
    data: Json

    constructor(code: i64, message: string) {
        this.code = code
        this.message = message
        this.data = new JNull()
    }
}

// Códigos de erro padrão
const MCP_PARSE_ERROR: i64 = -32700
const MCP_INVALID_REQUEST: i64 = -32600
const MCP_METHOD_NOT_FOUND: i64 = -32601
const MCP_INVALID_PARAMS: i64 = -32602
const MCP_INTERNAL_ERROR: i64 = -32603

/// Resource MCP (contexto estático)
class MCPResource {
    uri: string
    name: string
    description: string
    mimeType: string

    constructor(uri: string, name: string) {
        this.uri = uri
        this.name = name
        this.description = ""
        this.mimeType = "text/plain"
    }
}

/// Prompt MCP (template)
class MCPPrompt {
    name: string
    description: string
    arguments: PromptArgument[]

    constructor(name: string, description: string) {
        this.name = name
        this.description = description
        this.arguments = []
    }
}

class PromptArgument {
    name: string
    description: string
    required: bool

    constructor(name: string, description: string, required: bool) {
        this.name = name
        this.description = description
        this.required = required
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// MCP SERVER
// ══════════════════════════════════════════════════════════════════════════════

/// Servidor MCP
class MCPServer {
    name: string
    version: string
    description: string
    tools: ToolRegistry
    resources: MCPResource[]
    prompts: MCPPrompt[]
    private running: bool

    constructor(name: string) {
        this.name = name
        this.version = "1.0.0"
        this.description = ""
        this.tools = new ToolRegistry()
        this.resources = []
        this.prompts = []
        this.running = false
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONFIGURAÇÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Define versão
    setVersion(version: string): MCPServer {
        this.version = version
        return this
    }

    /// Define descrição
    setDescription(desc: string): MCPServer {
        this.description = desc
        return this
    }

    /// Adiciona uma tool
    addTool(tool: Tool): MCPServer {
        this.tools.register(tool)
        return this
    }

    /// Adiciona múltiplas tools
    addTools(tools: Tool[]): MCPServer {
        for (const t of tools) {
            this.tools.register(t)
        }
        return this
    }

    /// Adiciona um resource
    addResource(resource: MCPResource): MCPServer {
        this.resources.push(resource)
        return this
    }

    /// Adiciona um prompt
    addPrompt(prompt: MCPPrompt): MCPServer {
        this.prompts.push(prompt)
        return this
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SERVIDOR
    // ══════════════════════════════════════════════════════════════════════════

    /// Inicia o servidor (stdio)
    serve() {
        this.running = true
        this.log(`MCP Server '${this.name}' starting...`)

        while (this.running) {
            // Ler linha do stdin
            const line: string = this.readLine()
            if (len(line) == 0) {
                continue
            }

            // Parsear mensagem
            const message: MCPMessage = this.parseMessage(line)

            // Processar e responder
            const response: string = this.handleMessage(message)
            if (len(response) > 0) {
                this.writeLine(response)
            }
        }
    }

    /// Para o servidor
    stop() {
        this.running = false
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HANDLERS
    // ══════════════════════════════════════════════════════════════════════════

    /// Processa uma mensagem
    private handleMessage(msg: MCPMessage): string {
        match (msg.method) {
            "initialize" => return this.handleInitialize(msg),
            "initialized" => return "",  // Notification, sem resposta
            "tools/list" => return this.handleToolsList(msg),
            "tools/call" => return this.handleToolsCall(msg),
            "resources/list" => return this.handleResourcesList(msg),
            "resources/read" => return this.handleResourcesRead(msg),
            "prompts/list" => return this.handlePromptsList(msg),
            "prompts/get" => return this.handlePromptsGet(msg),
            "ping" => return this.handlePing(msg),
            _ => return this.errorResponse(msg.id, MCP_METHOD_NOT_FOUND, `Method not found: ${msg.method}`)
        }
    }

    /// Handle initialize
    private handleInitialize(msg: MCPMessage): string {
        const result: string = `{
            "protocolVersion": "${MCP_VERSION}",
            "capabilities": {
                "tools": {},
                "resources": {},
                "prompts": {}
            },
            "serverInfo": {
                "name": "${jEscape(this.name)}",
                "version": "${jEscape(this.version)}"
            }
        }`
        return this.successResponse(msg.id, result)
    }

    /// Handle tools/list
    private handleToolsList(msg: MCPMessage): string {
        let toolsJson: string = "["
        let first: bool = true

        for (const tool of this.tools.tools) {
            if (!first) { toolsJson = concat(toolsJson, ","); }
            first = false

            toolsJson = concat(toolsJson, `{
                "name": "${jEscape(tool.schema.name)}",
                "description": "${jEscape(tool.schema.description)}",
                "inputSchema": ${this.schemaToJSON(tool.schema)}
            }`)
        }

        toolsJson = concat(toolsJson, "]")
        return this.successResponse(msg.id, `{"tools": ${toolsJson}}`)
    }

    /// Handle tools/call
    private handleToolsCall(msg: MCPMessage): string {
        const name: string = jStr(jGet(msg.params, "name"))
        const args: Json = jGet(msg.params, "arguments")

        if (!this.tools.has(name)) {
            return this.errorResponse(msg.id, MCP_INVALID_PARAMS, `Tool not found: ${name}`)
        }

        // Executar tool
        const argsJson: string = jsonStringify(args)
        const result: ToolResult = this.tools.execute(name, argsJson)

        if (result.isError) {
            return this.successResponse(msg.id, `{
                "content": [{"type": "text", "text": "${jEscape(result.output)}"}],
                "isError": true
            }`)
        }

        return this.successResponse(msg.id, `{
            "content": [{"type": "text", "text": "${jEscape(result.output)}"}]
        }`)
    }

    /// Handle resources/list
    private handleResourcesList(msg: MCPMessage): string {
        let resourcesJson: string = "["
        let first: bool = true

        for (const r of this.resources) {
            if (!first) { resourcesJson = concat(resourcesJson, ","); }
            first = false

            resourcesJson = concat(resourcesJson, `{
                "uri": "${jEscape(r.uri)}",
                "name": "${jEscape(r.name)}",
                "description": "${jEscape(r.description)}",
                "mimeType": "${jEscape(r.mimeType)}"
            }`)
        }

        resourcesJson = concat(resourcesJson, "]")
        return this.successResponse(msg.id, `{"resources": ${resourcesJson}}`)
    }

    /// Handle resources/read
    private handleResourcesRead(msg: MCPMessage): string {
        const uri: string = jStr(jGet(msg.params, "uri"))

        // Procurar resource
        for (const r of this.resources) {
            if (strEq(r.uri, uri)) {
                // TODO: Ler conteúdo real do resource
                return this.successResponse(msg.id, `{
                    "contents": [{"uri": "${jEscape(uri)}", "mimeType": "${jEscape(r.mimeType)}", "text": ""}]
                }`)
            }
        }

        return this.errorResponse(msg.id, MCP_INVALID_PARAMS, `Resource not found: ${uri}`)
    }

    /// Handle prompts/list
    private handlePromptsList(msg: MCPMessage): string {
        let promptsJson: string = "["
        let first: bool = true

        for (const p of this.prompts) {
            if (!first) { promptsJson = concat(promptsJson, ","); }
            first = false

            let argsJson: string = "["
            let firstArg: bool = true
            for (const a of p.arguments) {
                if (!firstArg) { argsJson = concat(argsJson, ","); }
                firstArg = false
                argsJson = concat(argsJson, `{"name": "${jEscape(a.name)}", "description": "${jEscape(a.description)}", "required": ${if (a.required) { "true" } else { "false" }}}`)
            }
            argsJson = concat(argsJson, "]")

            promptsJson = concat(promptsJson, `{
                "name": "${jEscape(p.name)}",
                "description": "${jEscape(p.description)}",
                "arguments": ${argsJson}
            }`)
        }

        promptsJson = concat(promptsJson, "]")
        return this.successResponse(msg.id, `{"prompts": ${promptsJson}}`)
    }

    /// Handle prompts/get
    private handlePromptsGet(msg: MCPMessage): string {
        const name: string = jStr(jGet(msg.params, "name"))

        for (const p of this.prompts) {
            if (strEq(p.name, name)) {
                // TODO: Renderizar prompt com argumentos
                return this.successResponse(msg.id, `{
                    "description": "${jEscape(p.description)}",
                    "messages": []
                }`)
            }
        }

        return this.errorResponse(msg.id, MCP_INVALID_PARAMS, `Prompt not found: ${name}`)
    }

    /// Handle ping
    private handlePing(msg: MCPMessage): string {
        return this.successResponse(msg.id, "{}")
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /// Parseia mensagem JSON-RPC
    private parseMessage(line: string): MCPMessage {
        let msg: MCPMessage = new MCPMessage()
        const json: Json = jParse(line)

        msg.jsonrpc = jStr(jGet(json, "jsonrpc"))
        msg.id = jStr(jGet(json, "id"))
        msg.method = jStr(jGet(json, "method"))
        msg.params = jGet(json, "params")

        return msg
    }

    /// Cria resposta de sucesso
    private successResponse(id: string, result: string): string {
        return `{"jsonrpc":"2.0","id":"${jEscape(id)}","result":${result}}`
    }

    /// Cria resposta de erro
    private errorResponse(id: string, code: i64, message: string): string {
        return `{"jsonrpc":"2.0","id":"${jEscape(id)}","error":{"code":${code},"message":"${jEscape(message)}"}}`
    }

    /// Converte schema para JSON (formato MCP)
    private schemaToJSON(schema: ToolSchema): string {
        let props: string = ""
        let required: string = ""
        let firstProp: bool = true
        let firstReq: bool = true

        for (const p of schema.params) {
            if (!firstProp) { props = concat(props, ","); }
            firstProp = false

            props = concat(props, `"${p.name}":{"type":"${paramTypeToStr(p.paramType)}","description":"${jEscape(p.description)}"}`)

            if (p.required) {
                if (!firstReq) { required = concat(required, ","); }
                firstReq = false
                required = concat(required, `"${p.name}"`)
            }
        }

        return `{"type":"object","properties":{${props}},"required":[${required}]}`
    }

    /// Lê uma linha do stdin
    private readLine(): string {
        // Implementação simplificada - ler até newline
        let buf: ptr = alloc(65536)
        let pos: i64 = 0

        while (pos < 65535) {
            const n: i64 = read(0, buf + pos, 1)
            if (n <= 0) { break; }

            const c: i64 = peek8(buf, pos)
            if (c == 10) { break; }  // newline
            pos = pos + 1
        }

        poke8(buf, pos, 0)
        return buf
    }

    /// Escreve uma linha no stdout
    private writeLine(line: string) {
        const output: string = concat(line, "\n")
        write(1, output, len(output))
    }

    /// Log para stderr
    private log(msg: string) {
        const output: string = concat(concat("[MCP] ", msg), "\n")
        write(2, output, len(output))
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// BUILDER
// ══════════════════════════════════════════════════════════════════════════════

/// Builder para criar MCP servers
class MCPServerBuilder {
    private server: MCPServer

    constructor(name: string) {
        this.server = new MCPServer(name)
    }

    /// Define versão
    version(v: string): MCPServerBuilder {
        this.server.setVersion(v)
        return this
    }

    /// Define descrição
    describe(desc: string): MCPServerBuilder {
        this.server.setDescription(desc)
        return this
    }

    /// Adiciona tool
    tool(t: Tool): MCPServerBuilder {
        this.server.addTool(t)
        return this
    }

    /// Adiciona tools
    tools(ts: Tool[]): MCPServerBuilder {
        this.server.addTools(ts)
        return this
    }

    /// Adiciona resource
    resource(r: MCPResource): MCPServerBuilder {
        this.server.addResource(r)
        return this
    }

    /// Adiciona prompt
    prompt(p: MCPPrompt): MCPServerBuilder {
        this.server.addPrompt(p)
        return this
    }

    /// Constrói o server
    build(): MCPServer {
        return this.server
    }
}

/// Inicia um builder de MCP server
fn mcpServer(name: string): MCPServerBuilder {
    return new MCPServerBuilder(name)
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

import { JNull } from "../../tools/json"
import { paramTypeToStr } from "../ai/types"

declare function jEscape(s: string): string;
declare function jsonStringify(j: Json): string;
