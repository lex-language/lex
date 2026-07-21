// std/sha256.lex — SHA-256, HMAC-SHA256 e PBKDF2-HMAC-SHA256 em lex PURO.
//
// Motivação: o PostgreSQL 14+ autentica com SCRAM-SHA-256, que precisa dessas
// três primitivas bit-exatas. Não há crypto no runtime; aqui está, escrita só
// com inteiros i64 e operações de bit.
//
// Restrições da linguagem que moldam o código:
//   - NÃO há tipos sem sinal. Todo "u32" é um i64 mantido em [0, 2^32) e
//     RE-mascarado (`& 4294967295`) depois de cada soma/shift-left.
//   - `>>` é aritmético; como os valores ficam sempre positivos (< 2^63), ele
//     coincide com o shift lógico. `<<` pode transbordar do bit 32 pra cima,
//     mas o `& 4294967295` seguinte descarta o excesso.
//   - Bytes vivem em buffers `ptr` (alloc/poke8/peek8); `peek8` devolve 0..255.
//
//   import { sha256, hmacSha256, pbkdf2Sha256 } from "sha256";

// rotação de 32 bits à direita (u32). 4294967295 = 0xFFFFFFFF (lex não tem hex
// nem tipos sem sinal, então a máscara de 32 bits vai inline em cada operação).
function rotr32(x: i64, n: i64): i64 {
    return ((x >> n) | (x << (32 - n))) & 4294967295;
}

// as 64 constantes de round (raízes cúbicas dos 64 primeiros primos)
function sha256K(): i64[] {
    return [
        1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993,
        2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987,
        1925078388, 2162078206, 2614888103, 3248222580, 3835390401, 4022224774,
        264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
        2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711,
        113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291,
        1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411,
        3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
        430227734, 506948616, 659060556, 883997877, 958139571, 1322822218,
        1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424,
        2428436474, 2756734187, 3204031479, 3329325298
    ];
}

// lê um u32 big-endian de `p` no offset `o`
function ld32be(p: ptr, o: i64): i64 {
    return ((peek8(p, o) << 24) | (peek8(p, o + 1) << 16)
          | (peek8(p, o + 2) << 8) | peek8(p, o + 3)) & 4294967295;
}

// grava um u32 big-endian em `p` no offset `o`
function st32be(p: ptr, o: i64, v: i64) {
    poke8(p, o, (v >> 24) & 255);
    poke8(p, o + 1, (v >> 16) & 255);
    poke8(p, o + 2, (v >> 8) & 255);
    poke8(p, o + 3, v & 255);
}

// SHA-256 de `len` bytes em `data`; escreve os 32 bytes do digest em `out`.
function sha256(data: ptr, len: i64, out: ptr) {
    // padding: 1 bit '1' (0x80), zeros, e o comprimento em bits (u64 be).
    // total múltiplo de 64. blocks = ceil((len+9)/64).
    const blocks: i64 = (len + 9 + 63) / 64;
    const total: i64 = blocks * 64;
    const buf: ptr = alloc(total);
    let i: i64 = 0;
    while (i < len) { poke8(buf, i, peek8(data, i)); i = i + 1; }
    poke8(buf, len, 128);           // 0x80
    i = len + 1;
    while (i < total) { poke8(buf, i, 0); i = i + 1; }
    // comprimento em bits, big-endian, nos últimos 8 bytes
    const bits: i64 = len * 8;
    st32be(buf, total - 8, (bits >> 32) & 4294967295);
    st32be(buf, total - 4, bits & 4294967295);

    const K: i64[] = sha256K();
    // estado inicial H0..H7 (raízes quadradas dos 8 primeiros primos)
    let h0: i64 = 1779033703; let h1: i64 = 3144134277;
    let h2: i64 = 1013904242; let h3: i64 = 2773480762;
    let h4: i64 = 1359893119; let h5: i64 = 2600822924;
    let h6: i64 = 528734635;  let h7: i64 = 1541459225;

    const W: ptr = alloc(64 * 8);   // 64 palavras de 32 bits (uma célula i64 cada)

    let b: i64 = 0;
    while (b < blocks) {
        const base: i64 = b * 64;
        // W[0..15] = bloco; W[16..63] = mistura
        let t: i64 = 0;
        while (t < 16) { poke64(W, t * 8, ld32be(buf, base + t * 4)); t = t + 1; }
        t = 16;
        while (t < 64) {
            const w15: i64 = peek64(W, (t - 15) * 8);
            const w2: i64 = peek64(W, (t - 2) * 8);
            const s0: i64 = rotr32(w15, 7) ^ rotr32(w15, 18) ^ (w15 >> 3);
            const s1: i64 = rotr32(w2, 17) ^ rotr32(w2, 19) ^ (w2 >> 10);
            const v: i64 = (peek64(W, (t - 16) * 8) + s0
                          + peek64(W, (t - 7) * 8) + s1) & 4294967295;
            poke64(W, t * 8, v);
            t = t + 1;
        }

        let a: i64 = h0; let bb: i64 = h1; let c: i64 = h2; let d: i64 = h3;
        let e: i64 = h4; let f: i64 = h5; let g: i64 = h6; let hh: i64 = h7;

        t = 0;
        while (t < 64) {
            const S1: i64 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
            const ch: i64 = (e & f) ^ ((~e) & g);
            const t1: i64 = (hh + S1 + ch + K[t] + peek64(W, t * 8)) & 4294967295;
            const S0: i64 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
            const maj: i64 = (a & bb) ^ (a & c) ^ (bb & c);
            const t2: i64 = (S0 + maj) & 4294967295;
            hh = g; g = f; f = e;
            e = (d + t1) & 4294967295;
            d = c; c = bb; bb = a;
            a = (t1 + t2) & 4294967295;
            t = t + 1;
        }

        h0 = (h0 + a) & 4294967295;  h1 = (h1 + bb) & 4294967295;
        h2 = (h2 + c) & 4294967295;  h3 = (h3 + d) & 4294967295;
        h4 = (h4 + e) & 4294967295;  h5 = (h5 + f) & 4294967295;
        h6 = (h6 + g) & 4294967295;  h7 = (h7 + hh) & 4294967295;
        b = b + 1;
    }
    free(W);
    free(buf);

    st32be(out, 0, h0);  st32be(out, 4, h1);  st32be(out, 8, h2);
    st32be(out, 12, h3); st32be(out, 16, h4); st32be(out, 20, h5);
    st32be(out, 24, h6); st32be(out, 28, h7);
}

// HMAC-SHA256(key[keyLen], msg[msgLen]) -> out[32]
function hmacSha256(key: ptr, keyLen: i64, msg: ptr, msgLen: i64, out: ptr) {
    const block: i64 = 64;
    const k0: ptr = alloc(block);
    let i: i64 = 0;
    // se a chave > bloco, K0 = SHA256(key); senão K0 = key com zero-pad
    if (keyLen > block) {
        sha256(key, keyLen, k0);
        i = 32;
        while (i < block) { poke8(k0, i, 0); i = i + 1; }
    } else {
        while (i < keyLen) { poke8(k0, i, peek8(key, i)); i = i + 1; }
        while (i < block) { poke8(k0, i, 0); i = i + 1; }
    }

    // ipad/opad
    const inner: ptr = alloc(block + msgLen);
    i = 0;
    while (i < block) { poke8(inner, i, peek8(k0, i) ^ 54); i = i + 1; }   // 0x36
    i = 0;
    while (i < msgLen) { poke8(inner, block + i, peek8(msg, i)); i = i + 1; }
    const innerHash: ptr = alloc(32);
    sha256(inner, block + msgLen, innerHash);

    const outer: ptr = alloc(block + 32);
    i = 0;
    while (i < block) { poke8(outer, i, peek8(k0, i) ^ 92); i = i + 1; }   // 0x5c
    i = 0;
    while (i < 32) { poke8(outer, block + i, peek8(innerHash, i)); i = i + 1; }
    sha256(outer, block + 32, out);

    free(outer); free(innerHash); free(inner); free(k0);
}

// PBKDF2-HMAC-SHA256(pw, salt, iters) -> out[dkLen]. Para o SCRAM dkLen=32,
// ou seja um único bloco (T1); mesmo assim implementamos o caso geral.
function pbkdf2Sha256(pw: ptr, pwLen: i64, salt: ptr, saltLen: i64,
                      iters: i64, out: ptr, dkLen: i64) {
    const hLen: i64 = 32;
    const blocks: i64 = (dkLen + hLen - 1) / hLen;
    const u: ptr = alloc(hLen);
    const tacc: ptr = alloc(hLen);
    // salt || INT(i) para a primeira iteração de cada bloco
    const saltInt: ptr = alloc(saltLen + 4);
    let s: i64 = 0;
    while (s < saltLen) { poke8(saltInt, s, peek8(salt, s)); s = s + 1; }

    let bi: i64 = 1;
    while (bi <= blocks) {
        // U1 = HMAC(pw, salt || INT32BE(bi))
        st32be(saltInt, saltLen, bi);
        hmacSha256(pw, pwLen, saltInt, saltLen + 4, u);
        let j: i64 = 0;
        while (j < hLen) { poke8(tacc, j, peek8(u, j)); j = j + 1; }
        // U2..Uc = HMAC(pw, U_{n-1}); T ^= Un
        let it: i64 = 1;
        while (it < iters) {
            hmacSha256(pw, pwLen, u, hLen, u);
            j = 0;
            while (j < hLen) { poke8(tacc, j, peek8(tacc, j) ^ peek8(u, j)); j = j + 1; }
            it = it + 1;
        }
        // copia hLen (ou o resto) pro output
        const off: i64 = (bi - 1) * hLen;
        let take: i64 = hLen;
        if (off + take > dkLen) { take = dkLen - off; }
        j = 0;
        while (j < take) { poke8(out, off + j, peek8(tacc, j)); j = j + 1; }
        bi = bi + 1;
    }
    free(saltInt); free(tacc); free(u);
}
