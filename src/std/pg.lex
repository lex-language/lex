// std/pg.lex — cliente PostgreSQL (protocolo de mensagens v3) em lex PURO.
//
// Cobre o que uma carga estilo `cava` precisa:
//   - handshake (StartupMessage) + autenticação SCRAM-SHA-256 (padrão do PG 14+)
//   - query simples (Q) com parse de RowDescription/DataRow
//   - COPY <tabela> FROM STDIN (formato texto) em streaming, chunk a chunk
//
// Não faz TLS (use rede confiável / proxy) nem prepared statements. Trabalha
// sobre buffers `ptr` porque o protocolo é binário e `string` não guarda o byte 0.
//
//   import { PG } from "pg";
//   const db: PG = new PG();
//   try db.connect("127.0.0.1", 5432, "user", "senha", "banco");
//   const v: string = db.queryScalar("SELECT version()");
//   db.close();

import { read, write, close } from "libc";
import { lexConnect } from "socket";
import { sha256, hmacSha256, pbkdf2Sha256 } from "sha256";
import { b64encode, b64decode } from "base64";

// ── helpers de inteiros big-endian (a ordem de rede do protocolo) ───────────

function put32be(p: ptr, o: i64, v: i64) {
    poke8(p, o, (v >> 24) & 255);
    poke8(p, o + 1, (v >> 16) & 255);
    poke8(p, o + 2, (v >> 8) & 255);
    poke8(p, o + 3, v & 255);
}
function get32be(p: ptr, o: i64): i64 {
    return ((peek8(p, o) << 24) | (peek8(p, o + 1) << 16)
          | (peek8(p, o + 2) << 8) | peek8(p, o + 3)) & 4294967295;
}
function get16be(p: ptr, o: i64): i64 {
    return (peek8(p, o) << 8) | peek8(p, o + 1);
}

// copia `n` bytes de src+srcOff para dst+dstOff
function copyBytes(dst: ptr, dstOff: i64, src: ptr, srcOff: i64, n: i64) {
    let i: i64 = 0;
    while (i < n) {
        poke8(dst, dstOff + i, peek8(src, srcOff + i));
        i = i + 1;
    }
}

// extrai `n` bytes de p+off para uma string lex NOVA (NUL-terminada). Necessário
// porque os campos do protocolo NÃO podem ser lidos com substring: `substring`
// usa strlen e para no primeiro byte 0 (e o protocolo tem zeros no meio).
function bytesToStr(p: ptr, off: i64, n: i64): string {
    const out: ptr = alloc(n + 1);
    copyBytes(out, 0, p, off, n);
    poke8(out, n, 0);
    return out;
}

// grava a string `s` seguida de um byte NUL em dst+off; devolve o novo offset.
function putStrZ(dst: ptr, off: i64, s: string): i64 {
    const n: i64 = len(s);
    copyBytes(dst, off, s, 0, n);
    poke8(dst, off + n, 0);
    return off + n + 1;
}

// ── I/O garantido (read/write podem devolver parcial) ───────────────────────

// lê EXATAMENTE n bytes para buf; devolve n, ou < n em EOF/erro.
function readN(fd: i64, buf: ptr, n: i64): i64 {
    const base: i64 = buf;
    let got: i64 = 0;
    while (got < n) {
        const r: i64 = read(fd, base + got, n - got);
        if (r <= 0) { return got; }
        got = got + r;
    }
    return got;
}

// escreve EXATAMENTE n bytes de buf; devolve n, ou < n em erro.
function writeAll(fd: i64, buf: ptr, n: i64): i64 {
    const base: i64 = buf;
    let sent: i64 = 0;
    while (sent < n) {
        const w: i64 = write(fd, base + sent, n - sent);
        if (w <= 0) { return sent; }
        sent = sent + w;
    }
    return n;
}

// gera um nonce alfanumérico de `n` chars a partir de /dev/urandom
function genNonce(n: i64): string {
    const alpha: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const fd: i64 = openFile("/dev/urandom", 0);
    const rnd: ptr = alloc(n);
    readN(fd, rnd, n);
    close(fd);
    let out: string = "";
    let i: i64 = 0;
    while (i < n) {
        out = concat(out, charAt(alpha, peek8(rnd, i) % 62));
        i = i + 1;
    }
    free(rnd);
    return out;
}

// ── o cliente ───────────────────────────────────────────────────────────────

class PG {
    fd: i64
    hdr: ptr        // scratch de 5 bytes p/ o cabeçalho (tipo + tamanho)
    rbuf: ptr       // payload da última mensagem lida
    rcap: i64       // capacidade de rbuf
    mtype: i64      // tipo da última mensagem
    mlen: i64       // tamanho do payload da última mensagem
    err: string     // última mensagem de erro do servidor

    constructor() {
        this.fd = 0 - 1;
        this.hdr = alloc(5);
        this.rcap = 8192;
        this.rbuf = alloc(this.rcap);
        this.mtype = 0;
        this.mlen = 0;
        this.err = "";
    }

    // garante rbuf com pelo menos `need` bytes
    ensureCap(need: i64) {
        if (need <= this.rcap) { return; }
        free(this.rbuf);
        let c: i64 = this.rcap;
        while (c < need) { c = c * 2; }
        this.rbuf = alloc(c);
        this.rcap = c;
    }

    // escreve uma mensagem: 1 byte tipo + int32(len incluindo os 4) + payload
    sendMsg(mtype: i64, payload: ptr, plen: i64) {
        poke8(this.hdr, 0, mtype);
        put32be(this.hdr, 1, plen + 4);
        writeAll(this.fd, this.hdr, 5);
        if (plen > 0) { writeAll(this.fd, payload, plen); }
    }

    // lê a próxima mensagem para rbuf; devolve o tipo (byte) ou -1 em EOF.
    // ErrorResponse ('E'=69) é lido normalmente; quem chama decide o que fazer.
    recvMsg(): i64 {
        if (readN(this.fd, this.hdr, 5) < 5) { return 0 - 1; }
        const mtype: i64 = peek8(this.hdr, 0);
        const total: i64 = get32be(this.hdr, 1);
        const plen: i64 = total - 4;
        this.ensureCap(plen + 1);
        if (plen > 0) {
            if (readN(this.fd, this.rbuf, plen) < plen) { return 0 - 1; }
        }
        poke8(this.rbuf, plen, 0);   // sentinela NUL (facilita ler campos-string)
        this.mtype = mtype;
        this.mlen = plen;
        return mtype;
    }

    // extrai o campo 'M' (mensagem humana) de um ErrorResponse em rbuf
    parseError(): string {
        let o: i64 = 0;
        while (o < this.mlen) {
            const code: i64 = peek8(this.rbuf, o);
            if (code == 0) { return "erro desconhecido"; }
            // string NUL-terminada a partir de o+1
            let e: i64 = o + 1;
            while (peek8(this.rbuf, e) != 0) { e = e + 1; }
            if (code == 77) {   // 'M'
                return bytesToStr(this.rbuf, o + 1, e - (o + 1));
            }
            o = e + 1;
        }
        return "erro desconhecido";
    }

    // conecta e autentica. erro 1 = TCP, 2 = auth/protocolo, 3 = ErrorResponse.
    connect(host: string, port: i64, user: string, password: string, db: string): i64! {
        this.fd = lexConnect(host, port);
        if (this.fd < 0) { fail 1; }

        // StartupMessage: int32 len + int32 proto(196608) + "user\0<u>\0database\0<d>\0" + "\0"
        // montado byte a byte (tem NULs no meio, que string/concat não guardam).
        const bodyLen: i64 = 5 + len(user) + 1 + 9 + len(db) + 1 + 1;   // "user"\0 u \0 "database"\0 d \0 \0
        const total: i64 = 8 + bodyLen;
        const msg: ptr = alloc(total);
        put32be(msg, 0, total);
        put32be(msg, 4, 196608);   // protocolo 3.0
        let o: i64 = 8;
        o = putStrZ(msg, o, "user");
        o = putStrZ(msg, o, user);
        o = putStrZ(msg, o, "database");
        o = putStrZ(msg, o, db);
        poke8(msg, o, 0);   // terminador da lista de parâmetros
        writeAll(this.fd, msg, o + 1);
        free(msg);

        try this.authenticate(user, password);
        try this.waitReady();
        return 0;
    }

    // negocia SCRAM-SHA-256 até AuthenticationOk
    authenticate(user: string, password: string): i64! {
        const t: i64 = this.recvMsg();
        if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
        if (t != 82) { fail 2; }                                 // espera 'R'
        const code: i64 = get32be(this.rbuf, 0);
        if (code == 0) { return 0; }                             // sem senha (trust)
        if (code != 10) { fail 2; }                              // 10 = SASL

        // client-first
        const clientNonce: string = genNonce(24);
        const clientFirstBare: string = concat("n=,r=", clientNonce);
        const clientFirst: string = concat("n,,", clientFirstBare);
        // SASLInitialResponse: "SCRAM-SHA-256\0" + int32(len) + client-first
        const mech: string = "SCRAM-SHA-256";
        const cfLen: i64 = len(clientFirst);
        const p1len: i64 = len(mech) + 1 + 4 + cfLen;
        const p1: ptr = alloc(p1len);
        copyBytes(p1, 0, mech, 0, len(mech));
        poke8(p1, len(mech), 0);
        put32be(p1, len(mech) + 1, cfLen);
        copyBytes(p1, len(mech) + 5, clientFirst, 0, cfLen);
        this.sendMsg(112, p1, p1len);   // 'p'
        free(p1);

        // server-first (R, code 11)
        const t2: i64 = this.recvMsg();
        if (t2 == 69) { this.err = this.parseError(); fail 3; }
        if (t2 != 82) { fail 2; }
        if (get32be(this.rbuf, 0) != 11) { fail 2; }
        const serverFirst: string = this.saslData();
        // parse "r=<nonce>,s=<salt_b64>,i=<iters>"
        const parts: string[] = split(serverFirst, ",");
        const fullNonce: string = substring(parts[0], 2, len(parts[0]));
        const saltB64: string = substring(parts[1], 2, len(parts[1]));
        const iters: i64 = parseInt(substring(parts[2], 2, len(parts[2])));

        // SaltedPassword = PBKDF2(password, salt, iters, 32)
        const salt: ptr = alloc(len(saltB64));
        const saltLen: i64 = b64decode(saltB64, salt);
        const salted: ptr = alloc(32);
        pbkdf2Sha256(password, len(password), salt, saltLen, iters, salted, 32);

        // ClientKey = HMAC(SaltedPassword, "Client Key"); StoredKey = SHA256(ClientKey)
        const clientKey: ptr = alloc(32);
        hmacSha256(salted, 32, "Client Key", 10, clientKey);
        const storedKey: ptr = alloc(32);
        sha256(clientKey, 32, storedKey);

        // AuthMessage = client-first-bare + "," + server-first + "," + client-final-no-proof
        const clientFinalBare: string = concat("c=biws,r=", fullNonce);
        const authMsg: string = concat(concat(concat(concat(clientFirstBare, ","), serverFirst), ","), clientFinalBare);

        // ClientSignature = HMAC(StoredKey, AuthMessage); Proof = ClientKey XOR ClientSig
        const clientSig: ptr = alloc(32);
        hmacSha256(storedKey, 32, authMsg, len(authMsg), clientSig);
        const proof: ptr = alloc(32);
        let i: i64 = 0;
        while (i < 32) { poke8(proof, i, peek8(clientKey, i) ^ peek8(clientSig, i)); i = i + 1; }
        const proofB64: string = b64encode(proof, 32);

        // client-final: "c=biws,r=<nonce>,p=<proof>"
        const clientFinal: string = concat(concat(clientFinalBare, ",p="), proofB64);
        this.sendMsg(112, clientFinal, len(clientFinal));   // 'p'

        free(proof); free(clientSig); free(storedKey); free(clientKey);
        free(salted); free(salt);

        // SASLFinal (R,12) e depois AuthenticationOk (R,0)
        const t3: i64 = this.recvMsg();
        if (t3 == 69) { this.err = this.parseError(); fail 3; }
        if (t3 != 82) { fail 2; }
        const c3: i64 = get32be(this.rbuf, 0);
        if (c3 == 12) {
            const t4: i64 = this.recvMsg();
            if (t4 == 69) { this.err = this.parseError(); fail 3; }
            if (t4 != 82) { fail 2; }
            if (get32be(this.rbuf, 0) != 0) { fail 2; }
        } else if (c3 != 0) {
            fail 2;
        }
        return 0;
    }

    // dado SASL (após o int32 code) da mensagem R corrente, como string
    saslData(): string {
        return bytesToStr(this.rbuf, 4, this.mlen - 4);
    }

    // consome ParameterStatus/BackendKeyData/Notice até ReadyForQuery ('Z'=90)
    waitReady(): i64! {
        while (1 == 1) {
            const t: i64 = this.recvMsg();
            if (t < 0) { fail 2; }
            if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
            if (t == 90) { return 0; }                              // 'Z'
        }
        return 0;
    }

    // ── queries ─────────────────────────────────────────────────────────────

    // envia uma Query simples (Q). Não consome a resposta.
    sendQuery(sql: string) {
        this.sendMsg(81, sql, len(sql) + 1);   // 'Q' com o \0 final incluído no len
    }

    // executa `sql` e devolve o command tag (ex. "SELECT 1", "COPY 1000").
    // erro 3 = ErrorResponse do servidor.
    exec(sql: string): string! {
        this.sendQuery(sql);
        let tag: string = "";
        while (1 == 1) {
            const t: i64 = this.recvMsg();
            if (t < 0) { fail 2; }
            if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
            if (t == 67) { tag = bytesToStr(this.rbuf, 0, this.mlen); } // 'C' CommandComplete
            if (t == 90) { return tag; }                            // 'Z' ReadyForQuery
        }
        return tag;
    }

    // executa `sql` e devolve o 1º campo da 1ª linha (ou "" se não houver linha).
    queryScalar(sql: string): string! {
        this.sendQuery(sql);
        let result: string = "";
        let have: bool = false;
        while (1 == 1) {
            const t: i64 = this.recvMsg();
            if (t < 0) { fail 2; }
            if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
            if (t == 68) {                                          // 'D' DataRow
                if (!have) {
                    const nfields: i64 = get16be(this.rbuf, 0);
                    if (nfields > 0) {
                        const flen: i64 = get32be(this.rbuf, 2);
                        if (flen != 4294967295) {   // != -1 (NULL); get32be é u32
                            result = bytesToStr(this.rbuf, 6, flen);
                        }
                    }
                    have = true;
                }
            }
            if (t == 90) { return result; }                        // 'Z'
        }
        return result;
    }

    // ── COPY <tabela> FROM STDIN (formato texto) ─────────────────────────────

    // inicia o COPY: envia a query e espera CopyInResponse ('G'=71).
    copyBegin(sql: string): i64! {
        this.sendQuery(sql);
        while (1 == 1) {
            const t: i64 = this.recvMsg();
            if (t < 0) { fail 2; }
            if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
            if (t == 71) { return 0; }                              // 'G'
        }
        return 0;
    }

    // envia um bloco de dados do COPY (uma ou mais linhas em formato texto).
    // O buffer é enviado como uma mensagem CopyData ('d'=100).
    copySend(buf: ptr, n: i64) {
        this.sendMsg(100, buf, n);
    }

    // encerra o COPY: CopyDone ('c'=99), lê até ReadyForQuery, devolve o tag.
    copyEnd(): string! {
        this.sendMsg(99, this.hdr, 0);   // payload vazio
        let tag: string = "";
        while (1 == 1) {
            const t: i64 = this.recvMsg();
            if (t < 0) { fail 2; }
            if (t == 69) { this.err = this.parseError(); fail 3; }   // 'E'
            if (t == 67) { tag = bytesToStr(this.rbuf, 0, this.mlen); } // 'C'
            if (t == 90) { return tag; }                            // 'Z'
        }
        return tag;
    }

    close() {
        if (this.fd >= 0) {
            // Terminate ('X'=88)
            this.sendMsg(88, this.hdr, 0);
            close(this.fd);
            this.fd = 0 - 1;
        }
    }
}
