// std/ai/http.lex — Cliente HTTP para APIs de AI
//
// Usa `curl` como processo externo para suportar HTTPS (TLS).
// Isso é pragmático: implementar TLS nativo seria um projeto enorme.
// APIs de AI (Claude, OpenAI) todas usam HTTPS.
//
// Uso:
//   const client: HTTPClient = new HTTPClient()
//   const response: HTTPResponse = client.post(url, body, headers)
//
// Features:
//   - POST/GET com headers customizados
//   - Timeout configurável
//   - Retry com backoff exponencial
//   - Streaming via callback

import { read, write, close, malloc } from "../libc"

// ══════════════════════════════════════════════════════════════════════════════
// TIPOS
// ══════════════════════════════════════════════════════════════════════════════

/// Um header HTTP
class HTTPHeader {
    name: string
    value: string

    constructor(name: string, value: string) {
        this.name = name
        this.value = value
    }
}

/// Resposta HTTP
class HTTPResponse {
    statusCode: i64
    body: string
    headers: HTTPHeader[]
    error: string

    constructor() {
        this.statusCode = 0
        this.body = ""
        this.headers = []
        this.error = ""
    }

    /// Verifica se a resposta foi bem sucedida (2xx)
    ok(): bool {
        return this.statusCode >= 200 && this.statusCode < 300
    }

    /// Verifica se é erro de rate limit
    isRateLimit(): bool {
        return this.statusCode == 429
    }

    /// Verifica se é erro de autenticação
    isAuthError(): bool {
        return this.statusCode == 401 || this.statusCode == 403
    }

    /// Obtém header por nome
    getHeader(name: string): string {
        const lowerName: string = toLower(name)
        for (const h of this.headers) {
            if (strEq(toLower(h.name), lowerName)) {
                return h.value
            }
        }
        return ""
    }
}

/// Configuração do cliente HTTP
class HTTPConfig {
    timeoutSeconds: i64      // Timeout em segundos
    maxRetries: i64          // Máximo de retries
    retryDelayMs: i64        // Delay inicial entre retries (ms)
    userAgent: string        // User-Agent header

    constructor() {
        this.timeoutSeconds = 120
        this.maxRetries = 3
        this.retryDelayMs = 1000
        this.userAgent = "lex-ai/1.0"
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// CLIENTE HTTP
// ══════════════════════════════════════════════════════════════════════════════

/// Cliente HTTP para APIs de AI
class HTTPClient {
    config: HTTPConfig

    constructor() {
        this.config = new HTTPConfig()
    }

    /// Faz uma requisição POST
    post(url: string, body: string, headers: HTTPHeader[]): HTTPResponse {
        return this.request("POST", url, body, headers)
    }

    /// Faz uma requisição GET
    get(url: string, headers: HTTPHeader[]): HTTPResponse {
        return this.request("GET", url, "", headers)
    }

    /// Faz uma requisição com retry automático
    request(method: string, url: string, body: string, headers: HTTPHeader[]): HTTPResponse {
        let lastResponse: HTTPResponse = new HTTPResponse()
        let attempt: i64 = 0

        while (attempt <= this.config.maxRetries) {
            lastResponse = this.doRequest(method, url, body, headers)

            // Sucesso ou erro não-retryable
            if (lastResponse.ok() || lastResponse.isAuthError()) {
                return lastResponse
            }

            // Rate limit: espera o tempo indicado
            if (lastResponse.isRateLimit()) {
                const retryAfter: string = lastResponse.getHeader("retry-after")
                let waitMs: i64 = this.config.retryDelayMs * (attempt + 1)
                if (len(retryAfter) > 0) {
                    waitMs = parseInt(retryAfter) * 1000
                }
                sleepMs(waitMs)
            } else if (lastResponse.statusCode >= 500) {
                // Server error: exponential backoff
                const waitMs: i64 = this.config.retryDelayMs * (1 << attempt)
                sleepMs(waitMs)
            } else {
                // Outros erros: não retry
                return lastResponse
            }

            attempt = attempt + 1
        }

        return lastResponse
    }

    /// Executa a requisição via curl
    private doRequest(method: string, url: string, body: string, headers: HTTPHeader[]): HTTPResponse {
        // Construir comando curl
        let cmd: string = "curl -s -w '\\n%{http_code}' -X "
        cmd = concat(cmd, method)

        // Timeout
        cmd = concat(cmd, ` --max-time ${this.config.timeoutSeconds}`)

        // Headers
        cmd = concat(cmd, ` -H "User-Agent: ${this.config.userAgent}"`)
        for (const h of headers) {
            cmd = concat(cmd, ` -H "${h.name}: ${h.value}"`)
        }

        // Body (para POST/PUT)
        if (len(body) > 0) {
            // Escrever body em arquivo temporário para evitar problemas com escaping
            const tmpFile: string = "/tmp/lex_http_body.json"
            writeFile(tmpFile, body)
            cmd = concat(cmd, ` -d @${tmpFile}`)
        }

        // URL (escapada)
        cmd = concat(cmd, ` "${url}"`)

        // Executar curl
        const output: string = shell(cmd)

        // Limpar arquivo temporário
        if (len(body) > 0) {
            shell("rm -f /tmp/lex_http_body.json")
        }

        // Parsear resposta
        return this.parseResponse(output)
    }

    /// Parseia a resposta do curl
    private parseResponse(output: string): HTTPResponse {
        const response: HTTPResponse = new HTTPResponse()

        // O output termina com o status code (devido ao -w)
        const lines: string[] = split(output, "\n")
        if (lines.len() == 0) {
            response.error = "Empty response from curl"
            return response
        }

        // Última linha é o status code
        const lastLine: string = trim(lines[lines.len() - 1])
        response.statusCode = parseInt(lastLine)

        // O resto é o body
        let bodyLines: string[] = []
        let i: i64 = 0
        while (i < lines.len() - 1) {
            bodyLines.push(lines[i])
            i = i + 1
        }
        response.body = join(bodyLines, "\n")

        return response
    }

    /// Faz requisição com streaming (callback para cada chunk)
    postStream(url: string, body: string, headers: HTTPHeader[], onChunk: (string) => void): HTTPResponse {
        // Construir comando curl com -N (disable buffering)
        let cmd: string = "curl -s -N -X POST"

        // Timeout
        cmd = concat(cmd, ` --max-time ${this.config.timeoutSeconds}`)

        // Headers
        cmd = concat(cmd, ` -H "User-Agent: ${this.config.userAgent}"`)
        for (const h of headers) {
            cmd = concat(cmd, ` -H "${h.name}: ${h.value}"`)
        }

        // Body
        if (len(body) > 0) {
            const tmpFile: string = "/tmp/lex_http_body.json"
            writeFile(tmpFile, body)
            cmd = concat(cmd, ` -d @${tmpFile}`)
        }

        // URL
        cmd = concat(cmd, ` "${url}"`)

        // Executar com streaming
        const output: string = shellStream(cmd, onChunk)

        // Limpar
        if (len(body) > 0) {
            shell("rm -f /tmp/lex_http_body.json")
        }

        const response: HTTPResponse = new HTTPResponse()
        response.statusCode = 200  // Assumimos sucesso se chegou até aqui
        response.body = output
        return response
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

/// Cria header de autenticação Bearer
fn bearerAuth(token: string): HTTPHeader {
    return new HTTPHeader("Authorization", concat("Bearer ", token))
}

/// Cria header de API key (estilo Anthropic)
fn apiKeyAuth(key: string): HTTPHeader {
    return new HTTPHeader("x-api-key", key)
}

/// Cria header Content-Type JSON
fn jsonContentType(): HTTPHeader {
    return new HTTPHeader("Content-Type", "application/json")
}

/// Cria headers padrão para Anthropic
fn anthropicHeaders(apiKey: string, version: string): HTTPHeader[] {
    let headers: HTTPHeader[] = []
    headers.push(apiKeyAuth(apiKey))
    headers.push(new HTTPHeader("anthropic-version", version))
    headers.push(jsonContentType())
    return headers
}

/// Cria headers padrão para OpenAI
fn openaiHeaders(apiKey: string): HTTPHeader[] {
    let headers: HTTPHeader[] = []
    headers.push(bearerAuth(apiKey))
    headers.push(jsonContentType())
    return headers
}

// ══════════════════════════════════════════════════════════════════════════════
// FUNÇÕES DE SISTEMA (declarações)
// ══════════════════════════════════════════════════════════════════════════════

// Declarações de funções que dependem do runtime
declare function shell(cmd: string): string;
declare function shellStream(cmd: string, onChunk: (string) => void): string;
declare function sleepMs(ms: i64): void;
declare function writeFile(path: string, content: string): void;

// ══════════════════════════════════════════════════════════════════════════════
// CLIENTE GLOBAL (SINGLETON)
// ══════════════════════════════════════════════════════════════════════════════

// Cliente HTTP global compartilhado
fn getHTTPClient(): HTTPClient {
    // TODO: implementar singleton real quando tivermos variáveis globais
    return new HTTPClient()
}
