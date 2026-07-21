// std/agent/memory.lex — Sistema de Memória para Agents
//
// Implementa diferentes tipos de memória:
//   - ShortTermMemory: Contexto da conversa atual
//   - LongTermMemory: Memória persistente com embeddings
//   - WorkingMemory: Estado da sessão
//
// Uso:
//   import { Memory, ShortTermMemory, LongTermMemory } from "std/agent/memory"

import { Message, userMsg, assistantMsg } from "../ai/types"
import { Embeddings, cosineSimilarity, searchTopK, SearchResult } from "../ai/embeddings"

// ══════════════════════════════════════════════════════════════════════════════
// MEMORY ENTRY
// ══════════════════════════════════════════════════════════════════════════════

/// Tipo de entrada de memória
enum MemoryType {
    Message,       // Mensagem de conversa
    Summary,       // Resumo de conversas anteriores
    Fact,          // Fato aprendido
    Task,          // Tarefa ou objetivo
    Context        // Contexto adicional
}

/// Uma entrada de memória
class MemoryEntry {
    entryType: MemoryType
    content: string
    metadata: Map<string>
    timestamp: i64
    embedding: f64[]

    constructor(entryType: MemoryType, content: string) {
        this.entryType = entryType
        this.content = content
        this.metadata = {}
        this.timestamp = now()
        this.embedding = []
    }

    /// Adiciona metadata
    addMeta(key: string, value: string): MemoryEntry {
        mapSet(this.metadata, key, value)
        return this
    }

    /// Converte para Message
    toMessage(): Message {
        // Default: user message
        return userMsg(this.content)
    }
}

/// Cria entrada de mensagem
fn messageEntry(role: string, content: string): MemoryEntry {
    const entry: MemoryEntry = new MemoryEntry(MemoryType.Message, content)
    entry.addMeta("role", role)
    return entry
}

/// Cria entrada de resumo
fn summaryEntry(content: string): MemoryEntry {
    return new MemoryEntry(MemoryType.Summary, content)
}

/// Cria entrada de fato
fn factEntry(content: string): MemoryEntry {
    return new MemoryEntry(MemoryType.Fact, content)
}

// ══════════════════════════════════════════════════════════════════════════════
// MEMORY INTERFACE
// ══════════════════════════════════════════════════════════════════════════════

/// Interface para sistemas de memória
interface Memory {
    add(entry: MemoryEntry): void
    search(query: string, k: i64): MemoryEntry[]
    getRecent(k: i64): MemoryEntry[]
    clear(): void
    size(): i64
}

// ══════════════════════════════════════════════════════════════════════════════
// SHORT TERM MEMORY
// ══════════════════════════════════════════════════════════════════════════════

/// Memória de curto prazo (contexto da conversa)
class ShortTermMemory implements Memory {
    entries: MemoryEntry[]
    maxEntries: i64
    summarizeAfter: i64

    constructor() {
        this.entries = []
        this.maxEntries = 100
        this.summarizeAfter = 50
    }

    /// Adiciona entrada
    add(entry: MemoryEntry) {
        this.entries.push(entry)

        // Resumir se necessário
        if (this.entries.len() > this.summarizeAfter) {
            this.maybeSummarize()
        }

        // Limitar tamanho
        while (this.entries.len() > this.maxEntries) {
            this.entries.shift()
        }
    }

    /// Adiciona mensagem
    addMessage(role: string, content: string) {
        this.add(messageEntry(role, content))
    }

    /// Busca por similaridade textual simples
    search(query: string, k: i64): MemoryEntry[] {
        // Para short-term, retorna as mais recentes que contenham parte da query
        let results: MemoryEntry[] = []
        const queryLower: string = toLower(query)
        let i: i64 = this.entries.len() - 1

        while (i >= 0 && results.len() < k) {
            const entry: MemoryEntry = this.entries[i]
            if (indexOf(toLower(entry.content), queryLower) >= 0) {
                results.push(entry)
            }
            i = i - 1
        }

        return results
    }

    /// Retorna as k entradas mais recentes
    getRecent(k: i64): MemoryEntry[] {
        let results: MemoryEntry[] = []
        let count: i64 = k
        if (count > this.entries.len()) {
            count = this.entries.len()
        }

        let i: i64 = this.entries.len() - count
        while (i < this.entries.len()) {
            results.push(this.entries[i])
            i = i + 1
        }

        return results
    }

    /// Converte para array de Messages
    toMessages(): Message[] {
        let messages: Message[] = []
        for (const entry of this.entries) {
            messages.push(entry.toMessage())
        }
        return messages
    }

    /// Limpa a memória
    clear() {
        this.entries = []
    }

    /// Retorna o tamanho
    size(): i64 {
        return this.entries.len()
    }

    /// Resumir entradas antigas (interno)
    private maybeSummarize() {
        // TODO: Chamar LLM para resumir as entradas antigas
        // Por enquanto, apenas remove as mais antigas
        const toRemove: i64 = this.entries.len() / 2
        let i: i64 = 0
        while (i < toRemove) {
            this.entries.shift()
            i = i + 1
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// LONG TERM MEMORY
// ══════════════════════════════════════════════════════════════════════════════

/// Memória de longo prazo com embeddings
class LongTermMemory implements Memory {
    entries: MemoryEntry[]
    embedder: Embeddings
    minScore: f64

    constructor() {
        this.entries = []
        this.embedder = new Embeddings()
        this.minScore = 0.7
    }

    /// Adiciona entrada (com embedding)
    add(entry: MemoryEntry) {
        // Gerar embedding
        const vec: f64[] = this.embedder.embed(entry.content) catch []
        entry.embedding = vec
        this.entries.push(entry)
    }

    /// Busca por similaridade semântica
    search(query: string, k: i64): MemoryEntry[] {
        // Gerar embedding da query
        const queryVec: f64[] = this.embedder.embed(query) catch []
        if (queryVec.len() == 0) {
            return this.getRecent(k)
        }

        // Buscar top-k por similaridade
        let vectors: f64[][] = []
        for (const entry of this.entries) {
            vectors.push(entry.embedding)
        }

        const topK: SearchResult[] = searchTopK(queryVec, vectors, k)

        // Filtrar por score mínimo
        let results: MemoryEntry[] = []
        for (const result of topK) {
            if (result.score >= this.minScore) {
                results.push(this.entries[result.index])
            }
        }

        return results
    }

    /// Retorna as k entradas mais recentes
    getRecent(k: i64): MemoryEntry[] {
        let results: MemoryEntry[] = []
        let count: i64 = k
        if (count > this.entries.len()) {
            count = this.entries.len()
        }

        let i: i64 = this.entries.len() - count
        while (i < this.entries.len()) {
            results.push(this.entries[i])
            i = i + 1
        }

        return results
    }

    /// Limpa a memória
    clear() {
        this.entries = []
    }

    /// Retorna o tamanho
    size(): i64 {
        return this.entries.len()
    }

    /// Salva em arquivo
    save(path: string) {
        // TODO: Serializar entries para JSON e salvar
    }

    /// Carrega de arquivo
    load(path: string) {
        // TODO: Carregar JSON e deserializar entries
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// WORKING MEMORY
// ══════════════════════════════════════════════════════════════════════════════

/// Memória de trabalho (estado da sessão)
class WorkingMemory {
    state: Map<string>
    lists: Map<string[]>
    numbers: Map<i64>

    constructor() {
        this.state = {}
        this.lists = {}
        this.numbers = {}
    }

    /// Define um valor string
    set(key: string, value: string) {
        mapSet(this.state, key, value)
    }

    /// Obtém um valor string
    get(key: string): string {
        if (mapHas(this.state, key)) {
            return mapGet(this.state, key)
        }
        return ""
    }

    /// Define um valor numérico
    setNumber(key: string, value: i64) {
        mapSet(this.numbers, key, value)
    }

    /// Obtém um valor numérico
    getNumber(key: string): i64 {
        if (mapHas(this.numbers, key)) {
            return mapGet(this.numbers, key)
        }
        return 0
    }

    /// Incrementa um contador
    increment(key: string): i64 {
        const current: i64 = this.getNumber(key)
        const next: i64 = current + 1
        this.setNumber(key, next)
        return next
    }

    /// Define uma lista
    setList(key: string, values: string[]) {
        mapSet(this.lists, key, values)
    }

    /// Obtém uma lista
    getList(key: string): string[] {
        if (mapHas(this.lists, key)) {
            return mapGet(this.lists, key)
        }
        let empty: string[] = []
        return empty
    }

    /// Adiciona item a uma lista
    addToList(key: string, value: string) {
        let list: string[] = this.getList(key)
        list.push(value)
        this.setList(key, list)
    }

    /// Remove todas as entradas
    clear() {
        this.state = {}
        this.lists = {}
        this.numbers = {}
    }

    /// Exporta como string (para debug)
    toString(): string {
        let result: string = "WorkingMemory {\n"

        // State
        const stateKeys: string[] = keys(this.state)
        for (const k of stateKeys) {
            result = concat(result, `  ${k}: "${mapGet(this.state, k)}"\n`)
        }

        // Numbers
        const numKeys: string[] = keys(this.numbers)
        for (const k of numKeys) {
            result = concat(result, `  ${k}: ${mapGet(this.numbers, k)}\n`)
        }

        result = concat(result, "}")
        return result
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// COMPOSITE MEMORY
// ══════════════════════════════════════════════════════════════════════════════

/// Memória composta (short + long + working)
class CompositeMemory {
    shortTerm: ShortTermMemory
    longTerm: LongTermMemory
    working: WorkingMemory

    constructor() {
        this.shortTerm = new ShortTermMemory()
        this.longTerm = new LongTermMemory()
        this.working = new WorkingMemory()
    }

    /// Adiciona mensagem
    addMessage(role: string, content: string) {
        // Adiciona ao short-term
        this.shortTerm.addMessage(role, content)

        // Também adiciona ao long-term para busca futura
        this.longTerm.add(messageEntry(role, content))
    }

    /// Busca contexto relevante para uma query
    getContext(query: string, maxMessages: i64 = 10, maxLongTerm: i64 = 5): MemoryEntry[] {
        let context: MemoryEntry[] = []

        // Mensagens recentes do short-term
        const recent: MemoryEntry[] = this.shortTerm.getRecent(maxMessages)
        for (const e of recent) {
            context.push(e)
        }

        // Buscar memórias relevantes do long-term
        const relevant: MemoryEntry[] = this.longTerm.search(query, maxLongTerm)
        for (const e of relevant) {
            context.push(e)
        }

        return context
    }

    /// Converte contexto para messages
    contextToMessages(query: string): Message[] {
        let messages: Message[] = []

        // Adicionar memórias relevantes como contexto
        const relevant: MemoryEntry[] = this.longTerm.search(query, 5)
        if (relevant.len() > 0) {
            let contextStr: string = "Relevant context from memory:\n"
            for (const e of relevant) {
                contextStr = concat(contextStr, `- ${e.content}\n`)
            }
            messages.push(userMsg(contextStr))
        }

        // Adicionar mensagens recentes
        const recent: Message[] = this.shortTerm.toMessages()
        for (const m of recent) {
            messages.push(m)
        }

        return messages
    }

    /// Limpa toda a memória
    clear() {
        this.shortTerm.clear()
        this.longTerm.clear()
        this.working.clear()
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

declare function now(): i64;
declare function mapSet<T>(m: Map<T>, key: string, value: T): void;
declare function mapGet<T>(m: Map<T>, key: string): T;
declare function mapHas<T>(m: Map<T>, key: string): bool;
declare function keys<T>(m: Map<T>): string[];
