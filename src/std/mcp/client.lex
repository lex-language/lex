// std/mcp/client.lex — MCP Client Implementation
//
// Cliente para conectar a MCP servers e usar suas tools.
//
// Uso:
//   import { MCPClient } from "std/mcp/client"
//
//   const client: MCPClient = MCPClient.connect("npx @anthropic/mcp-server-fs")
//   const tools: ToolSchema[] = client.listTools()
//   const result: string = client.callTool("readFile", args)

import { Tool, ToolRegistry, ToolSchema, ToolParam, ParamType } from "../agent/tool"
import { ToolCall, ToolResult } from "../ai/types"
import { jParse, jGet, jStr, jNum, jArr, JObj, JArr, Json, JNull } from "../../tools/json"

// ══════════════════════════════════════════════════════════════════════════════
// MCP CLIENT
// ══════════════════════════════════════════════════════════════════════════════

/// Status da conexão
enum ConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    Error
}

/// Informações do servidor
class ServerInfo {
    name: string
    version: string
    protocolVersion: string

    constructor() {
        this.name = ""
        this.version = ""
        this.protocolVersion = ""
    }
}

/// Cliente MCP
class MCPClient {
    command: string
    serverInfo: ServerInfo
    status: ConnectionStatus
    private processId: i64
    private requestId: i64
    private tools: ToolSchema[]

    constructor(command: string) {
        this.command = command
        this.serverInfo = new ServerInfo()
        this.status = ConnectionStatus.Disconnected
        this.processId = 0
        this.requestId = 0
        this.tools = []
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONEXÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Conecta a um MCP server
    static connect(command: string): MCPClient! {
        const client: MCPClient = new MCPClient(command)
        try client.initialize()
        return client
    }

    /// Inicializa a conexão
    private initialize(): void! {
        this.status = ConnectionStatus.Connecting

        // Iniciar processo
        this.processId = try this.startProcess(this.command)

        // Enviar initialize
        const initRequest: string = this.buildRequest("initialize", `{
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {
                "name": "lex-mcp-client",
                "version": "1.0.0"
            }
        }`)

        const response: string = try this.sendRequest(initRequest)
        const json: Json = jParse(response)
        const result: Json = jGet(json, "result")

        // Extrair info do servidor
        const serverInfoJson: Json = jGet(result, "serverInfo")
        this.serverInfo.name = jStr(jGet(serverInfoJson, "name"))
        this.serverInfo.version = jStr(jGet(serverInfoJson, "version"))
        this.serverInfo.protocolVersion = jStr(jGet(result, "protocolVersion"))

        // Enviar initialized notification
        const initializedNotif: string = `{"jsonrpc":"2.0","method":"initialized"}`
        this.sendNotification(initializedNotif)

        this.status = ConnectionStatus.Connected
    }

    /// Desconecta
    disconnect() {
        if (this.status == ConnectionStatus.Connected) {
            this.stopProcess(this.processId)
            this.status = ConnectionStatus.Disconnected
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TOOLS
    // ══════════════════════════════════════════════════════════════════════════

    /// Lista tools disponíveis
    listTools(): ToolSchema[]! {
        if (this.tools.len() > 0) {
            return this.tools
        }

        const request: string = this.buildRequest("tools/list", "{}")
        const response: string = try this.sendRequest(request)

        const json: Json = jParse(response)
        const result: Json = jGet(json, "result")
        const toolsArr: Json[] = jArr(jGet(result, "tools"))

        let schemas: ToolSchema[] = []
        for (const t of toolsArr) {
            const schema: ToolSchema = this.parseToolSchema(t)
            schemas.push(schema)
        }

        this.tools = schemas
        return schemas
    }

    /// Chama uma tool
    callTool(name: string, arguments: string): string! {
        const request: string = this.buildRequest("tools/call", `{
            "name": "${jEscape(name)}",
            "arguments": ${arguments}
        }`)

        const response: string = try this.sendRequest(request)
        const json: Json = jParse(response)

        // Verificar erro
        const error: Json = jGet(json, "error")
        if (!isNull(error)) {
            fail jStr(jGet(error, "message"))
        }

        const result: Json = jGet(json, "result")
        const content: Json[] = jArr(jGet(result, "content"))

        // Concatenar conteúdo
        let output: string = ""
        for (const c of content) {
            const contentType: string = jStr(jGet(c, "type"))
            if (strEq(contentType, "text")) {
                output = concat(output, jStr(jGet(c, "text")))
            }
        }

        return output
    }

    /// Converte para ToolRegistry
    toToolRegistry(): ToolRegistry! {
        const schemas: ToolSchema[] = try this.listTools()
        const registry: ToolRegistry = new ToolRegistry()

        for (const schema of schemas) {
            // Criar tool que chama o MCP server
            const client: MCPClient = this
            const toolName: string = schema.name

            const tool: Tool = new Tool(schema, (input: Json) => {
                const argsJson: string = jsonStringify(input)
                const result: string = client.callTool(toolName, argsJson) catch ""
                return result
            })

            registry.register(tool)
        }

        return registry
    }

    // ══════════════════════════════════════════════════════════════════════════
    // RESOURCES
    // ══════════════════════════════════════════════════════════════════════════

    /// Lista resources disponíveis
    listResources(): Json[]! {
        const request: string = this.buildRequest("resources/list", "{}")
        const response: string = try this.sendRequest(request)

        const json: Json = jParse(response)
        const result: Json = jGet(json, "result")
        return jArr(jGet(result, "resources"))
    }

    /// Lê um resource
    readResource(uri: string): string! {
        const request: string = this.buildRequest("resources/read", `{"uri": "${jEscape(uri)}"}`)
        const response: string = try this.sendRequest(request)

        const json: Json = jParse(response)
        const result: Json = jGet(json, "result")
        const contents: Json[] = jArr(jGet(result, "contents"))

        if (contents.len() > 0) {
            return jStr(jGet(contents[0], "text"))
        }

        return ""
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PROMPTS
    // ══════════════════════════════════════════════════════════════════════════

    /// Lista prompts disponíveis
    listPrompts(): Json[]! {
        const request: string = this.buildRequest("prompts/list", "{}")
        const response: string = try this.sendRequest(request)

        const json: Json = jParse(response)
        const result: Json = jGet(json, "result")
        return jArr(jGet(result, "prompts"))
    }

    /// Obtém um prompt
    getPrompt(name: string, arguments: string): Json! {
        const request: string = this.buildRequest("prompts/get", `{
            "name": "${jEscape(name)}",
            "arguments": ${arguments}
        }`)

        const response: string = try this.sendRequest(request)
        const json: Json = jParse(response)
        return jGet(json, "result")
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /// Constrói uma request JSON-RPC
    private buildRequest(method: string, params: string): string {
        this.requestId = this.requestId + 1
        return `{"jsonrpc":"2.0","id":"${this.requestId}","method":"${method}","params":${params}}`
    }

    /// Parseia schema de tool
    private parseToolSchema(json: Json): ToolSchema {
        const name: string = jStr(jGet(json, "name"))
        const description: string = jStr(jGet(json, "description"))
        const schema: ToolSchema = new ToolSchema(name, description)

        const inputSchema: Json = jGet(json, "inputSchema")
        const properties: Json = jGet(inputSchema, "properties")
        const requiredArr: Json[] = jArr(jGet(inputSchema, "required"))

        // Construir set de required
        let requiredSet: Map<bool> = {}
        for (const r of requiredArr) {
            mapSet(requiredSet, jStr(r), true)
        }

        // Parsear propriedades (simplificado)
        // TODO: iterar sobre properties quando tivermos essa capacidade

        return schema
    }

    /// Envia request e aguarda resposta
    private sendRequest(request: string): string! {
        // Implementação via processo
        const output: string = shell(`echo '${request}' | ${this.command}`)
        return output
    }

    /// Envia notification (sem resposta)
    private sendNotification(notification: string) {
        shell(`echo '${notification}' | ${this.command}`)
    }

    /// Inicia processo
    private startProcess(command: string): i64! {
        // Simplificado - em produção usaria pipes reais
        return 0
    }

    /// Para processo
    private stopProcess(pid: i64) {
        // Simplificado
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

/// Verifica se um Json é null
fn isNull(j: Json): bool {
    return match (j) {
        JNull => true,
        _ => false
    }
}

declare function jEscape(s: string): string;
declare function jsonStringify(j: Json): string;
declare function shell(cmd: string): string;
declare function mapSet<T>(m: Map<T>, key: string, value: T): void;
declare function mapHas<T>(m: Map<T>, key: string): bool;
