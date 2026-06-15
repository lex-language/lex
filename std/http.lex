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

// One connection. `conn` (the socket fd) is a field, so every method here
// shares it through `this.conn` — no need to pass it around.
class Conn {
    conn: i64

    constructor(conn: i64) {
        this.conn = conn;
    }

    // drains the request off the socket (reading isn't parsed yet)
    recv() {
        const buf: ptr = malloc(4096);
        read(this.conn, buf, 4095);
        free(buf);
    }

    // raw write of `body` to the socket (no headers, no close)
    send(body: ptr) {
        write(this.conn, body, strlen(body));
    }

    // sends a full HTTP 200 response for `body`, then closes the connection
    respond(body: ptr) {
        const header: ptr = `HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${strlen(body)}\r\nConnection: close\r\n\r\n`;
        this.send(header);
        this.send(body);
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
}
