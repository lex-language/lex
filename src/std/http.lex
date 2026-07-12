// std/http.lex — lex's HTTP library, written in lex, as classes.
//
// You instantiate a server and start it with a handler; the accept loop,
// the threads and the protocol live here.
//
//   import { Server, Conn } from "http";
//   function App(c: Conn): Component { return `<h1>hi</h1>`; }
//   function main(): i32! {
//       const app: Server = new Server(8080);
//       try app.start(App);
//       return 0;
//   }
//
// Concurrency: every connection is handled on its own thread (spawn), with
// its own string arena freed when the request ends. Each request gets a
// fresh Conn object, so `this.conn` is private to that thread — never shared.

import { lexListen, lexAccept } from "./socket";
import { read, write, close, strlen, malloc } from "./libc";

// Texto do status HTTP a partir do código (o necessário para uma API simples).
function httpStatus(code: i64): string {
    if (code == 201) { return "201 Created"; }
    if (code == 400) { return "400 Bad Request"; }
    if (code == 401) { return "401 Unauthorized"; }
    if (code == 404) { return "404 Not Found"; }
    if (code == 405) { return "405 Method Not Allowed"; }
    return "200 OK";
}

// One connection. `conn` (the socket fd) is a field, so every method here
// shares it through `this.conn` — no need to pass it around. `raw` guarda o
// texto da requisição (lido uma vez por `recv`), de onde method/path/query/body
// são extraídos.
class Conn {
    conn: i64
    raw: string

    constructor(conn: i64) {
        this.conn = conn;
        this.raw = "";
    }

    // lê a requisição (uma leitura, até 8 KiB — basta p/ GETs e publishes
    // pequenos) e NUL-termina o buffer para tratá-lo como string.
    recv() {
        const buf: ptr = malloc(8192);
        const n: i64 = read(this.conn, buf, 8191);
        if (n < 0) {
            poke8(buf, 0, 0);
        } else {
            poke8(buf, n, 0);
        }
        this.raw = buf;
    }

    // método HTTP (GET/POST/...) — a 1ª palavra da linha de requisição.
    method(): string {
        const sp: i64 = indexOf(this.raw, " ");
        if (sp < 0) { return ""; }
        return substring(this.raw, 0, sp);
    }

    // alvo bruto da linha de requisição (path + query) — uso interno.
    target(): string {
        const sp1: i64 = indexOf(this.raw, " ");
        if (sp1 < 0) { return "/"; }
        const rest: string = substring(this.raw, sp1 + 1, len(this.raw));
        const sp2: i64 = indexOf(rest, " ");
        if (sp2 < 0) { return rest; }
        return substring(rest, 0, sp2);
    }

    // caminho da requisição, SEM a query string (`/pkg/foo`).
    path(): string {
        const full: string = this.target();
        const q: i64 = indexOf(full, "?");
        if (q >= 0) { return substring(full, 0, q); }
        return full;
    }

    // query string depois do `?` (vazia se não houver).
    query(): string {
        const full: string = this.target();
        const q: i64 = indexOf(full, "?");
        if (q < 0) { return ""; }
        return substring(full, q + 1, len(full));
    }

    // corpo da requisição (depois do cabeçalho \r\n\r\n).
    body(): string {
        const marker: i64 = indexOf(this.raw, "\r\n\r\n");
        if (marker < 0) { return ""; }
        return substring(this.raw, marker + 4, len(this.raw));
    }

    // raw write of `body` to the socket (no headers, no close)
    send(body: ptr) {
        write(this.conn, body, strlen(body));
    }

    // sends a full HTTP 200 response for `body`, then closes the connection
    respond(body: ptr) {
        this.respondWith(200, "text/html; charset=utf-8", body);
    }

    // resposta completa com status e Content-Type quaisquer (API/JSON), depois
    // fecha a conexão. Libera o buffer da requisição (já consumido aqui).
    respondWith(status: i64, ctype: string, body: ptr) {
        const header: ptr = `HTTP/1.1 ${httpStatus(status)}\r\nContent-Type: ${ctype}\r\nContent-Length: ${strlen(body)}\r\nConnection: close\r\n\r\n`;
        this.send(header);
        this.send(body);
        free(this.raw);
        close(this.conn);
    }
}

// Runs on its own thread (spawned per connection). Builds the Conn here, so
// the object lives in this thread's arena and dies with the request.
function serveConn(conn: i64, handler: (Conn) => ptr) {
    const c: Conn = new Conn(conn);
    c.recv();
    c.respond(handler(c));
}

// Como serveConn, mas o handler controla a resposta inteira (status, tipo,
// roteamento) chamando `c.respondWith(...)` — usado por APIs/sites. O valor de
// retorno do handler é ignorado.
function serveConnRaw(conn: i64, handler: (Conn) => i64) {
    const c: Conn = new Conn(conn);
    c.recv();
    handler(c);
}

// The listening server. `new Server(port)` then `start(handler)`.
class Server {
    port: i64
    fd: i64

    constructor(port: i64) {
        this.port = port;
        this.fd = 0;
    }

    // binds, listens and runs the accept loop. error 1 = port already in use.
    start(handler: (Conn) => ptr): i64! {
        this.fd = lexListen(this.port);
        if (this.fd < 0) {
            fail 1;
        }
        Terminal.log(`lex listening on http://localhost:${this.port}`);
        while (1 == 1) {
            const conn: i64 = lexAccept(this.fd);
            if (conn > 0) {
                spawn serveConn(conn, handler);
            }
        }
        return 0;
    }

    // Como `start`, mas o handler responde por conta própria (roteamento +
    // status + Content-Type via `c.respondWith`). Para sites/APIs.
    startRaw(handler: (Conn) => i64): i64! {
        this.fd = lexListen(this.port);
        if (this.fd < 0) {
            fail 1;
        }
        Terminal.log(`lex listening on http://localhost:${this.port}`);
        while (1 == 1) {
            const conn: i64 = lexAccept(this.fd);
            if (conn > 0) {
                spawn serveConnRaw(conn, handler);
            }
        }
        return 0;
    }
}
