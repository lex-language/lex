// std/libc.lex — assinaturas de funções da libc (estilo .d.ts).
// Os símbolos vêm da libc do sistema; nada disso gera código.
// Uso: import { write, strlen } from "libc";

declare function read(fd: i64, buf: ptr, n: i64): i64;
declare function write(fd: i64, buf: ptr, n: i64): i64;
declare function close(fd: i64): i64;
declare function lseek(fd: i64, offset: i64, whence: i64): i64;
declare function strlen(s: ptr): i64;
declare function malloc(n: i64): ptr;
declare function usleep(microssegundos: i64): i32;
// `free` e `alloc` agora são builtins da linguagem (memória dinâmica) —
// não precisam de declaração.
