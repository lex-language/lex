// crypto.test.lex — vetores conhecidos de SHA-256/HMAC/PBKDF2/base64.
// Computação pura (sem rede/banco), roda em CI. Confere contra os vetores
// oficiais (FIPS 180-4, RFC 4231/6070, RFC 4648).
import { sha256, hmacSha256, pbkdf2Sha256 } from "../std/sha256"
import { b64encode, b64decode } from "../std/base64"

// digest -> hex minúsculo
fn hexOf(buf: ptr, n: i64): string {
    const digits: string = "0123456789abcdef";
    let out: string = "";
    let i: i64 = 0;
    while (i < n) {
        const b: i64 = peek8(buf, i);
        out = concat(out, charAt(digits, (b >> 4) & 15));
        out = concat(out, charAt(digits, b & 15));
        i = i + 1;
    }
    return out;
}
fn shaHex(s: string): string {
    const d: ptr = alloc(32);
    sha256(s, len(s), d);
    const h: string = hexOf(d, 32);
    free(d);
    return h;
}

describe("sha256", () => {
    test("vetores FIPS 180-4", () => {
        expect(shaHex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        expect(shaHex("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        expect(shaHex("The quick brown fox jumps over the lazy dog"))
            .toBe("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592");
    });
});

describe("hmac-sha256 / pbkdf2", () => {
    test("HMAC (RFC 4231)", () => {
        const msg: string = "The quick brown fox jumps over the lazy dog";
        const d: ptr = alloc(32);
        hmacSha256("key", 3, msg, len(msg), d);
        expect(hexOf(d, 32)).toBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
        free(d);
    });
    test("PBKDF2 (RFC 6070-like, SHA-256)", () => {
        const d: ptr = alloc(32);
        pbkdf2Sha256("password", 8, "salt", 4, 1, d, 32);
        expect(hexOf(d, 32)).toBe("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
        pbkdf2Sha256("password", 8, "salt", 4, 4096, d, 32);
        expect(hexOf(d, 32)).toBe("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
        free(d);
    });
});

describe("base64 (RFC 4648)", () => {
    test("encode com padding", () => {
        expect(b64encode("M", 1)).toBe("TQ==");
        expect(b64encode("Ma", 2)).toBe("TWE=");
        expect(b64encode("Man", 3)).toBe("TWFu");
    });
    test("roundtrip decode(encode)", () => {
        const src: string = "Hello, SCRAM world! 123";
        const enc: string = b64encode(src, len(src));
        const out: ptr = alloc(64);
        const n: i64 = b64decode(enc, out);
        poke8(out, n, 0);
        const back: string = out;
        expect(n).toBe(len(src));
        expect(back).toBe(src);
        free(out);
    });
});
