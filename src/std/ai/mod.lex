// std/ai/mod.lex — Módulo principal de AI
//
// Re-exporta todos os componentes do sistema de AI.
//
// Uso:
//   import { Claude, OpenAI, Embeddings } from "std/ai"

// Tipos fundamentais
export {
    // Mensagens
    Message, Role,
    userMsg, assistantMsg, systemMsg, toolResultMsg,

    // Tools
    ToolCall, ToolResult, ToolSchema, ToolParam, ParamType,
    toolError,

    // Respostas
    ModelResponse, TokenUsage, StopReason,

    // Streaming
    StreamEvent, StreamEventType,

    // Configuração
    ModelConfig, claudeDefaultConfig, openaiDefaultConfig,

    // Erros
    AIError, AIErrorKind,
    networkError, rateLimitError, authError
} from "./types"

// HTTP Client
export {
    HTTPClient, HTTPConfig, HTTPResponse, HTTPHeader,
    bearerAuth, apiKeyAuth, jsonContentType,
    anthropicHeaders, openaiHeaders
} from "./http"

// Providers
export {
    Claude, ClaudeConfig,
    configureClaude, configureClaudeFull,
    claudeComplete, claudeCompleteWithKey, claudeChat
} from "./claude"

export {
    OpenAI, OpenAIConfig,
    configureOpenAI, configureOpenAIFull,
    openaiComplete, openaiCompleteWithKey
} from "./openai"

// Embeddings
export {
    Embeddings, EmbeddingsConfig,
    configureEmbeddings, configureEmbeddingsFull,
    embed, embedWithKey,

    // Operações vetoriais
    cosineSimilarity, euclideanDistance, dotProduct,
    normalize, vectorAdd, vectorSub, vectorScale, vectorMean,

    // Busca
    SearchResult, searchTopK
} from "./embeddings"
