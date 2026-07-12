// std/fs.lex — filesystem em lex.
//
// Os PRIMITIVOS são builtins (não precisam de import): readFile, writeFile,
// appendFile, exists, isFile, isDir, fileSize, remove, rename, mkdir, rmdir,
// readDir, openFile. Eles devolvem valores crus (sentinelas: -1, 0, "").
//
// Esta biblioteca acrescenta a camada idiomática do lex: wrappers FALÍVEIS
// (erros como valores) e uma classe `File` para leitura/escrita por streaming.
//
//   import { readText, writeText, File } from "fs";

import { read, write, close, lseek } from "libc";

// --- wrappers falíveis (erros como valores) --------------------------------

// lê um arquivo de texto inteiro; falha (erro 1) se não existir/abrir
function readText(path: string): string! {
    if (exists(path) == 0) {
        fail 1;
    }
    return readFile(path);
}

// escreve (truncando o que havia); falha (erro 2) se a escrita falhar
function writeText(path: string, data: string): i64! {
    const n: i64 = writeFile(path, data);
    if (n < 0) {
        fail 2;
    }
    return n;
}

// anexa ao fim do arquivo; falha (erro 2) se a escrita falhar
function appendText(path: string, data: string): i64! {
    const n: i64 = appendFile(path, data);
    if (n < 0) {
        fail 2;
    }
    return n;
}

// cria o diretório se ainda não existir (idempotente)
function ensureDir(path: string): i64 {
    if (isDir(path) == 1) {
        return 0;
    }
    return mkdir(path);
}

// --- streaming via fd ------------------------------------------------------

// File guarda um fd aberto por openFile. Modos:
//   0 = leitura, 1 = escrita (trunca/cria), 2 = append (cria).
// read/write/close/lseek (libc) operam nesse fd — ideal p/ arquivos grandes
// ou leitura/escrita parcial, sem carregar tudo na memória.
class File {
    fd: i64

    constructor(path: string, mode: i64) {
        this.fd = openFile(path, mode);
    }

    // o arquivo abriu? (fd >= 0)
    ok(): bool {
        return this.fd > 0 - 1;
    }

    // lê até `max` bytes para `buf`; devolve quantos leu (0 = fim do arquivo)
    readInto(buf: ptr, max: i64): i64 {
        return read(this.fd, buf, max);
    }

    // escreve os primeiros `n` bytes de `buf`; devolve quantos escreveu
    writeBytes(buf: ptr, n: i64): i64 {
        return write(this.fd, buf, n);
    }

    // reposiciona o cursor (whence: 0 = início, 1 = atual, 2 = fim)
    seek(offset: i64, whence: i64): i64 {
        return lseek(this.fd, offset, whence);
    }

    done() {
        close(this.fd);
    }
}
