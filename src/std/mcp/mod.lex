// std/mcp/mod.lex — Módulo MCP (Model Context Protocol)
//
// Re-exporta todos os componentes do sistema MCP.
//
// Uso:
//   import { MCPServer, MCPClient } from "std/mcp"

// Server
export {
    MCPServer, MCPServerBuilder,
    mcpServer,

    // Types
    MCPMessage, MCPError,
    MCPResource, MCPPrompt, PromptArgument,

    // Constants
    MCP_VERSION,
    MCP_PARSE_ERROR, MCP_INVALID_REQUEST,
    MCP_METHOD_NOT_FOUND, MCP_INVALID_PARAMS,
    MCP_INTERNAL_ERROR
} from "./server"

// Client
export {
    MCPClient,
    ConnectionStatus,
    ServerInfo
} from "./client"
