// std/socket.lex — sockets em lex PURO. Antes existia um socket.c ao lado só
// para montar a struct sockaddr_in; agora ela é construída aqui mesmo, byte a
// byte, com os primitivos de memória (`alloc`/`poke`). Não há mais .c: o
// encanamento de rede é todo lex + chamadas diretas à libc.
//
// Layout da sockaddr_in (macOS/BSD, 16 bytes):
//   offset 0: sin_len    (u8)  = 16
//   offset 1: sin_family (u8)  = AF_INET (2)
//   offset 2: sin_port   (u16, ordem de rede)
//   offset 4: sin_addr   (u32, ordem de rede) = INADDR_ANY (0)
//   offset 8: 8 bytes zerados
// (`alloc` já devolve memória zerada, então só preenchemos o que não é zero.)

declare function socket(domain: i64, kind: i64, protocol: i64): i64;
declare function setsockopt(fd: i64, level: i64, opt: i64, val: ptr, len: i64): i64;
declare function bind(fd: i64, addr: ptr, len: i64): i64;
declare function listen(fd: i64, backlog: i64): i64;
declare function accept(fd: i64, addr: ptr, len: ptr): i64;
// monta a sockaddr_in no layout do SO alvo (a runtime resolve macOS vs Linux)
declare function lex_sockaddr_in(port: i64): ptr;

// socket + bind + listen; devolve o fd do servidor, ou -1 se a porta falhar.
function lexListen(port: i64): i64 {
    // AF_INET = 2, SOCK_STREAM = 1
    const fd: i64 = socket(2, 1, 0);
    if (fd < 0) {
        return 0 - 1;
    }

    // SO_REUSEADDR para reusar a porta logo após reiniciar (macOS: nível
    // SOL_SOCKET = 0xffff = 65535, opção SO_REUSEADDR = 4)
    const yes: ptr = alloc(4);
    poke32(yes, 0, 1);
    setsockopt(fd, 65535, 4, yes, 4);
    free(yes);

    // monta a sockaddr_in (16 bytes) — a runtime usa o layout certo do SO
    const addr: ptr = lex_sockaddr_in(port);

    if (bind(fd, addr, 16) < 0) {
        free(addr);
        return 0 - 1;
    }
    free(addr);
    if (listen(fd, 64) < 0) {
        return 0 - 1;
    }
    return fd;
}

function lexAccept(fd: i64): i64 {
    return accept(fd, 0, 0);
}
