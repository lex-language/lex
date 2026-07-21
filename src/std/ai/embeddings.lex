// std/ai/embeddings.lex — Embeddings e operações vetoriais
//
// Suporta OpenAI embeddings e operações vetoriais básicas.
//
// Uso:
//   import { Embeddings } from "std/ai/embeddings"
//
//   const vec: f64[] = Embeddings.embed("texto")
//   const similarity: f64 = Embeddings.cosineSimilarity(vec1, vec2)

import {
    HTTPClient, HTTPResponse, HTTPHeader,
    openaiHeaders, jsonContentType
} from "./http"

import { jParse, jGet, jStr, jNum, jArr, JObj, JArr, JNum, Json } from "../../tools/json"

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração de embeddings
class EmbeddingsConfig {
    provider: string        // "openai" | "anthropic" | "local"
    apiKey: string
    baseUrl: string
    model: string
    dimensions: i64         // Dimensionalidade (0 = default do modelo)

    constructor() {
        this.provider = "openai"
        this.apiKey = ""
        this.baseUrl = "https://api.openai.com/v1"
        this.model = "text-embedding-3-small"
        this.dimensions = 0
    }
}

// Configuração global
let embeddingsConfig: EmbeddingsConfig = new EmbeddingsConfig()

/// Configura embeddings
fn configureEmbeddings(apiKey: string) {
    embeddingsConfig.apiKey = apiKey
}

fn configureEmbeddingsFull(config: EmbeddingsConfig) {
    embeddingsConfig = config
}

// ══════════════════════════════════════════════════════════════════════════════
// EMBEDDINGS
// ══════════════════════════════════════════════════════════════════════════════

/// Classe principal de embeddings
class Embeddings {
    config: EmbeddingsConfig
    client: HTTPClient

    constructor() {
        this.config = embeddingsConfig
        this.client = new HTTPClient()
    }

    /// Construtor com API key
    static withKey(apiKey: string): Embeddings {
        const e: Embeddings = new Embeddings()
        e.config.apiKey = apiKey
        return e
    }

    /// Gera embedding para um texto
    embed(text: string): f64[]! {
        let texts: string[] = []
        texts.push(text)
        const results: f64[][] = try this.embedBatch(texts)
        if (results.len() > 0) {
            return results[0]
        }
        fail 1
    }

    /// Gera embeddings para múltiplos textos
    embedBatch(texts: string[]): f64[][]! {
        // Construir request body
        let body: string = "{"
        body = concat(body, `"model":"${this.config.model}"`)

        // Input array
        body = concat(body, `,"input":[`)
        let first: bool = true
        for (const t of texts) {
            if (!first) { body = concat(body, ","); }
            first = false
            body = concat(body, `"${jEscape(t)}"`)
        }
        body = concat(body, "]")

        // Dimensions (se especificado)
        if (this.config.dimensions > 0) {
            body = concat(body, `,"dimensions":${this.config.dimensions}`)
        }

        body = concat(body, "}")

        // Fazer request
        const url: string = concat(this.config.baseUrl, "/embeddings")
        const headers: HTTPHeader[] = openaiHeaders(this.config.apiKey)

        const httpResponse: HTTPResponse = this.client.post(url, body, headers)

        if (!httpResponse.ok()) {
            Terminal.error(`Embeddings API error: ${httpResponse.body}`)
            fail httpResponse.statusCode
        }

        return this.parseResponse(httpResponse.body)
    }

    /// Parseia resposta da API
    private parseResponse(body: string): f64[][] {
        let results: f64[][] = []
        const json: Json = jParse(body)

        const data: Json[] = jArr(jGet(json, "data"))
        for (const item of data) {
            const embedding: Json[] = jArr(jGet(item, "embedding"))
            let vec: f64[] = []
            for (const v of embedding) {
                vec.push(jNumFloat(v))
            }
            results.push(vec)
        }

        return results
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// OPERAÇÕES VETORIAIS
// ══════════════════════════════════════════════════════════════════════════════

/// Similaridade de cosseno entre dois vetores
fn cosineSimilarity(a: f64[], b: f64[]): f64 {
    if (a.len() != b.len()) {
        return 0.0
    }

    let dotProduct: f64 = 0.0
    let normA: f64 = 0.0
    let normB: f64 = 0.0

    let i: i64 = 0
    while (i < a.len()) {
        dotProduct = dotProduct + (a[i] * b[i])
        normA = normA + (a[i] * a[i])
        normB = normB + (b[i] * b[i])
        i = i + 1
    }

    if (normA == 0.0 || normB == 0.0) {
        return 0.0
    }

    return dotProduct / (sqrt(normA) * sqrt(normB))
}

/// Distância euclidiana entre dois vetores
fn euclideanDistance(a: f64[], b: f64[]): f64 {
    if (a.len() != b.len()) {
        return 0.0
    }

    let sum: f64 = 0.0
    let i: i64 = 0
    while (i < a.len()) {
        const diff: f64 = a[i] - b[i]
        sum = sum + (diff * diff)
        i = i + 1
    }

    return sqrt(sum)
}

/// Produto escalar entre dois vetores
fn dotProduct(a: f64[], b: f64[]): f64 {
    if (a.len() != b.len()) {
        return 0.0
    }

    let sum: f64 = 0.0
    let i: i64 = 0
    while (i < a.len()) {
        sum = sum + (a[i] * b[i])
        i = i + 1
    }

    return sum
}

/// Normaliza um vetor (L2 norm)
fn normalize(v: f64[]): f64[] {
    let norm: f64 = 0.0
    for (const x of v) {
        norm = norm + (x * x)
    }
    norm = sqrt(norm)

    if (norm == 0.0) {
        return v
    }

    let result: f64[] = []
    for (const x of v) {
        result.push(x / norm)
    }
    return result
}

/// Soma de dois vetores
fn vectorAdd(a: f64[], b: f64[]): f64[] {
    let result: f64[] = []
    let i: i64 = 0
    while (i < a.len() && i < b.len()) {
        result.push(a[i] + b[i])
        i = i + 1
    }
    return result
}

/// Subtração de dois vetores
fn vectorSub(a: f64[], b: f64[]): f64[] {
    let result: f64[] = []
    let i: i64 = 0
    while (i < a.len() && i < b.len()) {
        result.push(a[i] - b[i])
        i = i + 1
    }
    return result
}

/// Multiplicação por escalar
fn vectorScale(v: f64[], scalar: f64): f64[] {
    let result: f64[] = []
    for (const x of v) {
        result.push(x * scalar)
    }
    return result
}

/// Média de múltiplos vetores
fn vectorMean(vectors: f64[][]): f64[] {
    if (vectors.len() == 0) {
        let empty: f64[] = []
        return empty
    }

    const dim: i64 = vectors[0].len()
    let result: f64[] = []

    let d: i64 = 0
    while (d < dim) {
        let sum: f64 = 0.0
        for (const v of vectors) {
            if (d < v.len()) {
                sum = sum + v[d]
            }
        }
        result.push(sum / (vectors.len() as f64))
        d = d + 1
    }

    return result
}

// ══════════════════════════════════════════════════════════════════════════════
// BUSCA VETORIAL SIMPLES
// ══════════════════════════════════════════════════════════════════════════════

/// Resultado de busca vetorial
class SearchResult {
    index: i64
    score: f64

    constructor(index: i64, score: f64) {
        this.index = index
        this.score = score
    }
}

/// Busca os k vetores mais similares
fn searchTopK(query: f64[], vectors: f64[][], k: i64): SearchResult[] {
    // Calcular todas as similaridades
    let scores: SearchResult[] = []
    let i: i64 = 0
    while (i < vectors.len()) {
        const score: f64 = cosineSimilarity(query, vectors[i])
        scores.push(new SearchResult(i, score))
        i = i + 1
    }

    // Ordenar por score (insertion sort simples)
    let j: i64 = 1
    while (j < scores.len()) {
        const current: SearchResult = scores[j]
        let idx: i64 = j - 1
        while (idx >= 0 && scores[idx].score < current.score) {
            scores[idx + 1] = scores[idx]
            idx = idx - 1
        }
        scores[idx + 1] = current
        j = j + 1
    }

    // Retornar top k
    let results: SearchResult[] = []
    let n: i64 = 0
    while (n < k && n < scores.len()) {
        results.push(scores[n])
        n = n + 1
    }

    return results
}

// ══════════════════════════════════════════════════════════════════════════════
// FUNÇÕES DE CONVENIÊNCIA
// ══════════════════════════════════════════════════════════════════════════════

/// Embed rápido
fn embed(text: string): f64[]! {
    const e: Embeddings = new Embeddings()
    return try e.embed(text)
}

/// Embed com API key específica
fn embedWithKey(apiKey: string, text: string): f64[]! {
    const e: Embeddings = Embeddings.withKey(apiKey)
    return try e.embed(text)
}

// ══════════════════════════════════════════════════════════════════════════════
// DECLARAÇÕES EXTERNAS
// ══════════════════════════════════════════════════════════════════════════════

declare function jEscape(s: string): string;
declare function jNumFloat(j: Json): f64;
