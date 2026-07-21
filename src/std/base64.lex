// std/base64.lex — Base64 padrão (RFC 4648) em lex puro.
//
// O SCRAM (auth do PostgreSQL) troca salt, ClientProof e ServerSignature em
// base64; e a mensagem de senha do protocolo v3 também. Opera sobre buffers
// `ptr` (bytes crus) — não sobre `string`, que não suporta byte 0 no meio.
//
//   import { b64encode, b64decode } from "base64";

// alfabeto: A-Z a-z 0-9 + /
function b64alpha(i: i64): i64 {
    if (i < 26) { return 65 + i; }        // 'A'..'Z'
    if (i < 52) { return 97 + (i - 26); } // 'a'..'z'
    if (i < 62) { return 48 + (i - 52); } // '0'..'9'
    if (i == 62) { return 43; }           // '+'
    return 47;                            // '/'
}

// valor 0..63 de um caractere base64, ou -1 se não faz parte do alfabeto
function b64val(ch: i64): i64 {
    if (ch >= 65 && ch <= 90) { return ch - 65; }
    if (ch >= 97 && ch <= 122) { return ch - 97 + 26; }
    if (ch >= 48 && ch <= 57) { return ch - 48 + 52; }
    if (ch == 43) { return 62; }
    if (ch == 47) { return 63; }
    return 0 - 1;
}

// codifica `n` bytes de `data` numa string base64 (com padding '='). NUL-termina.
function b64encode(data: ptr, n: i64): string {
    const outLen: i64 = ((n + 2) / 3) * 4;
    const out: ptr = alloc(outLen + 1);
    let i: i64 = 0;
    let o: i64 = 0;
    while (i < n) {
        const b0: i64 = peek8(data, i);
        let b1: i64 = 0;
        let b2: i64 = 0;
        if (i + 1 < n) { b1 = peek8(data, i + 1); }
        if (i + 2 < n) { b2 = peek8(data, i + 2); }
        const triple: i64 = (b0 << 16) | (b1 << 8) | b2;
        poke8(out, o, b64alpha((triple >> 18) & 63));
        poke8(out, o + 1, b64alpha((triple >> 12) & 63));
        if (i + 1 < n) { poke8(out, o + 2, b64alpha((triple >> 6) & 63)); }
        else { poke8(out, o + 2, 61); }   // '='
        if (i + 2 < n) { poke8(out, o + 3, b64alpha(triple & 63)); }
        else { poke8(out, o + 3, 61); }   // '='
        i = i + 3;
        o = o + 4;
    }
    poke8(out, outLen, 0);
    return out;
}

// decodifica a string base64 `s` para bytes em `out`; devolve o nº de bytes.
// Ignora '=' e qualquer caractere fora do alfabeto (whitespace etc.).
function b64decode(s: string, out: ptr): i64 {
    const n: i64 = len(s);
    let acc: i64 = 0;
    let bits: i64 = 0;
    let o: i64 = 0;
    let i: i64 = 0;
    while (i < n) {
        const v: i64 = b64val(peek8(s, i));
        i = i + 1;
        if (v >= 0) {
            acc = (acc << 6) | v;
            bits = bits + 6;
            if (bits >= 8) {
                bits = bits - 8;
                poke8(out, o, (acc >> bits) & 255);
                o = o + 1;
            }
        }
    }
    return o;
}
