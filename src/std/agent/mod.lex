// std/agent/mod.lex — Módulo principal de Agents
//
// Re-exporta todos os componentes do sistema de agents.
//
// Uso:
//   import { Agent, Tool, Crew } from "std/agent"

// Tools
export {
    // Core
    Tool, ToolRegistry, ToolBuilder, ToolHandler,
    tool,

    // Builtin tools
    createReadFileTool, createWriteFileTool, createListFilesTool,
    createShellTool, createWebSearchTool,
    createFileSystemTools, createBuiltinTools
} from "./tool"

// Memory
export {
    // Types
    MemoryType, MemoryEntry,
    messageEntry, summaryEntry, factEntry,

    // Memory implementations
    Memory,
    ShortTermMemory,
    LongTermMemory,
    WorkingMemory,
    CompositeMemory
} from "./memory"

// Agent
export {
    // Core
    Agent, AgentConfig, AgentResult,
    AgentBuilder, agent,

    // Decisions
    ToolCallDecision, ErrorAction, ErrorResponse,
    failError, retryError,

    // Predefined agents
    createChatAgent, createCodeAgent
} from "./agent"

// Crew
export {
    // Core
    Crew, CrewConfig, CrewResult,
    CrewBuilder, crew,

    // Workflow types
    WorkflowType,

    // Agent output
    AgentOutput,

    // Predefined crews
    createCodeReviewCrew
} from "./crew"
