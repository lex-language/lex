// std/agent/tool.lex — Sistema de Tools para Agents
//
// Tools são funções que agents podem chamar para interagir com o mundo.
// Este módulo fornece:
//   - Registro de tools
//   - Execução de tools
//   - Validação de inputs
//   - Geração de JSON Schema
//
// Uso:
//   import { ToolRegistry, Tool } from "std/agent/tool"
//
//   const registry: ToolRegistry = new ToolRegistry()
//   registry.register(myTool)
//   const result: ToolResult = registry.execute("myTool", input)

import {
    ToolCall, ToolResult, ToolSchema, ToolParam, ParamType,
    toolError, paramTypeToStr
} from "../ai/types"

import { jParse, jGet, jStr, jNum, jArr, Json, JObj, JArr, JStr, JNum, JBool } from "../../tools/json"

// ══════════════════════════════════════════════════════════════════════════════
// TOOL
// ══════════════════════════════════════════════════════════════════════════════

/// Tipo do handler de uma tool
type ToolHandler = (Json) => string

/// Uma tool completa
class Tool {
    schema: ToolSchema
    handler: ToolHandler
    dangerous: bool        // Marca como operação perigosa
    requiresConfirm: bool  // Requer confirmação do usuário
    permissions: string[]  // Permissões necessárias

    constructor(schema: ToolSchema, handler: ToolHandler) {
        this.schema = schema
        this.handler = handler
        this.dangerous = false
        this.requiresConfirm = false
        this.permissions = []
    }

    /// Marca como perigosa
    markDangerous(): Tool {
        this.dangerous = true
        return this
    }

    /// Requer confirmação
    markRequiresConfirm(): Tool {
        this.requiresConfirm = true
        return this
    }

    /// Adiciona permissão necessária
    addPermission(perm: string): Tool {
        this.permissions.push(perm)
        return this
    }

    /// Executa a tool
    execute(input: Json): ToolResult {
        const result: string = this.handler(input)
        return new ToolResult("", this.schema.name, result)
    }

    /// Executa com validação
    executeWithValidation(inputJson: string): ToolResult {
        const input: Json = jParse(inputJson)

        // Validar parâmetros obrigatórios
        for (const param of this.schema.params) {
            if (param.required) {
                const value: Json = jGet(input, param.name)
                if (isNull(value)) {
                    return toolError("", this.schema.name, `Missing required parameter: ${param.name}`)
                }
            }
        }

        return this.execute(input)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// TOOL REGISTRY
// ══════════════════════════════════════════════════════════════════════════════

/// Registro de tools disponíveis
class ToolRegistry {
    tools: Tool[]
    private toolMap: Map<Tool>  // name -> Tool

    constructor() {
        this.tools = []
        this.toolMap = {}
    }

    /// Registra uma tool
    register(tool: Tool) {
        this.tools.push(tool)
        mapSet(this.toolMap, tool.schema.name, tool)
    }

    /// Registra múltiplas tools
    registerAll(tools: Tool[]) {
        for (const t of tools) {
            this.register(t)
        }
    }

    /// Obtém tool por nome
    get(name: string): Tool? {
        if (mapHas(this.toolMap, name)) {
            return mapGet(this.toolMap, name)
        }
        return null
    }

    /// Verifica se uma tool existe
    has(name: string): bool {
        return mapHas(this.toolMap, name)
    }

    /// Lista nomes de todas as tools
    listNames(): string[] {
        let names: string[] = []
        for (const t of this.tools) {
            names.push(t.schema.name)
        }
        return names
    }

    /// Obtém schemas de todas as tools
    getSchemas(): ToolSchema[] {
        let schemas: ToolSchema[] = []
        for (const t of this.tools) {
            schemas.push(t.schema)
        }
        return schemas
    }

    /// Executa uma tool por nome
    execute(name: string, inputJson: string): ToolResult {
        if (!this.has(name)) {
            return toolError("", name, `Tool not found: ${name}`)
        }

        const tool: Tool = mapGet(this.toolMap, name)
        return tool.executeWithValidation(inputJson)
    }

    /// Executa um ToolCall
    executeCall(call: ToolCall): ToolResult {
        const result: ToolResult = this.execute(call.name, call.input)
        result.toolCallId = call.id
        return result
    }

    /// Exporta schemas em formato JSON
    toJSON(): string {
        let json: string = "["
        let first: bool = true

        for (const t of this.tools) {
            if (!first) { json = concat(json, ","); }
            first = false
            json = concat(json, t.schema.toJSON())
        }

        return concat(json, "]")
    }

    /// Exporta em formato OpenAI
    toOpenAIJSON(): string {
        let json: string = "["
        let first: bool = true

        for (const t of this.tools) {
            if (!first) { json = concat(json, ","); }
            first = false
            json = concat(json, `{"type":"function","function":${t.schema.toJSON()}}`)
        }

        return concat(json, "]")
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// TOOL BUILDER
// ══════════════════════════════════════════════════════════════════════════════

/// Builder para criar tools de forma fluente
class ToolBuilder {
    private name: string
    private description: string
    private params: ToolParam[]
    private handler: ToolHandler

    constructor(name: string) {
        this.name = name
        this.description = ""
        this.params = []
        this.handler = (input: Json) => ""
    }

    /// Define descrição
    describe(desc: string): ToolBuilder {
        this.description = desc
        return this
    }

    /// Adiciona parâmetro string
    stringParam(name: string, desc: string, required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.String, desc)
        p.required = required
        this.params.push(p)
        return this
    }

    /// Adiciona parâmetro inteiro
    intParam(name: string, desc: string, required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.Integer, desc)
        p.required = required
        this.params.push(p)
        return this
    }

    /// Adiciona parâmetro número
    numberParam(name: string, desc: string, required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.Number, desc)
        p.required = required
        this.params.push(p)
        return this
    }

    /// Adiciona parâmetro boolean
    boolParam(name: string, desc: string, required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.Boolean, desc)
        p.required = required
        this.params.push(p)
        return this
    }

    /// Adiciona parâmetro array
    arrayParam(name: string, desc: string, required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.Array, desc)
        p.required = required
        this.params.push(p)
        return this
    }

    /// Adiciona parâmetro enum (string com valores fixos)
    enumParam(name: string, desc: string, values: string[], required: bool = true): ToolBuilder {
        const p: ToolParam = new ToolParam(name, ParamType.String, desc)
        p.required = required
        p.enumValues = values
        this.params.push(p)
        return this
    }

    /// Define o handler
    handle(fn: ToolHandler): ToolBuilder {
        this.handler = fn
        return this
    }

    /// Constrói a tool
    build(): Tool {
        const schema: ToolSchema = new ToolSchema(this.name, this.description)
        for (const p of this.params) {
            schema.addParam(p)
        }
        return new Tool(schema, this.handler)
    }
}

/// Inicia um builder de tool
fn tool(name: string): ToolBuilder {
    return new ToolBuilder(name)
}

// ══════════════════════════════════════════════════════════════════════════════
// TOOLS BUILTIN
// ══════════════════════════════════════════════════════════════════════════════

/// Tool para ler arquivos
fn createReadFileTool(): Tool {
    return tool("readFile")
        .describe("Read the contents of a file")
        .stringParam("path", "Path to the file to read")
        .handle((input: Json) => {
            const path: string = jStr(jGet(input, "path"))
            const content: string = readFile(path) catch ""
            if (len(content) == 0) {
                return `{"error": "Could not read file: ${path}"}`
            }
            return `{"content": "${jEscape(content)}"}`
        })
        .build()
}

/// Tool para escrever arquivos
fn createWriteFileTool(): Tool {
    return tool("writeFile")
        .describe("Write content to a file")
        .stringParam("path", "Path to the file to write")
        .stringParam("content", "Content to write to the file")
        .handle((input: Json) => {
            const path: string = jStr(jGet(input, "path"))
            const content: string = jStr(jGet(input, "content"))
            writeFile(path, content)
            return `{"success": true, "path": "${path}"}`
        })
        .build()
        .markDangerous()
}

/// Tool para listar arquivos
fn createListFilesTool(): Tool {
    return tool("listFiles")
        .describe("List files in a directory")
        .stringParam("directory", "Directory path to list")
        .stringParam("pattern", "Optional glob pattern to filter files", false)
        .handle((input: Json) => {
            const dir: string = jStr(jGet(input, "directory"))
            const files: string[] = readDir(dir) catch []
            let result: string = `{"files": [`
            let first: bool = true
            for (const f of files) {
                if (!first) { result = concat(result, ","); }
                first = false
                result = concat(result, `"${jEscape(f)}"`)
            }
            result = concat(result, "]}")
            return result
        })
        .build()
}

/// Tool para executar comandos shell
fn createShellTool(): Tool {
    return tool("shell")
        .describe("Execute a shell command")
        .stringParam("command", "The shell command to execute")
        .handle((input: Json) => {
            const cmd: string = jStr(jGet(input, "command"))
            const output: string = shell(cmd)
            return `{"output": "${jEscape(output)}"}`
        })
        .build()
        .markDangerous()
        .markRequiresConfirm()
}

/// Tool para buscar na web (via curl)
fn createWebSearchTool(): Tool {
    return tool("webSearch")
        .describe("Search the web for information")
        .stringParam("query", "Search query")
        .handle((input: Json) => {
            const query: string = jStr(jGet(input, "query"))
            // Placeholder - em produção usaria uma API de busca real
            return `{"error": "Web search not implemented. Query was: ${query}"}`
        })
        .build()
}

/// Cria um registry com tools padrão de filesystem
fn createFileSystemTools(): ToolRegistry {
    const registry: ToolRegistry = new ToolRegistry()
    registry.register(createReadFileTool())
    registry.register(createWriteFileTool())
    registry.register(createListFilesTool())
    return registry
}

/// Cria um registry com todas as tools builtin
fn createBuiltinTools(): ToolRegistry {
    const registry: ToolRegistry = new ToolRegistry()
    registry.register(createReadFileTool())
    registry.register(createWriteFileTool())
    registry.register(createListFilesTool())
    registry.register(createShellTool())
    registry.register(createWebSearchTool())
    return registry
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

// Declarações externas
declare function readFile(path: string): string!;
declare function writeFile(path: string, content: string): void;
declare function readDir(path: string): string[]!;
declare function shell(cmd: string): string;
declare function jEscape(s: string): string;

// Import JNull
import { JNull } from "../../tools/json"
