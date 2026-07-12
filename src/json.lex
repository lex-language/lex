// json.lex — parser JSON mínimo em lex (Fase F6.11), espelha src/json.rs.
// Suficiente pro protocolo do LSP: objetos, arrays, strings (com escapes),
// números (inteiros — basta p/ line/col), true/false/null. A SAÍDA é montada à
// mão; aqui só parseamos a entrada e oferecemos acessores + escape.
// Em caso de JSON malformado, devolve JNull (best-effort, como o LSP precisa).

class Json {}
class JNull extends Json {}
class JBool extends Json { b: bool; constructor(b: bool) { this.b = b } }
class JNum extends Json { n: i64; constructor(n: i64) { this.n = n } }   // inteiro
class JStr extends Json { s: string; constructor(s: string) { this.s = s } }
class JArr extends Json {
    items: Json[]
    constructor(items: Json[]) { this.items = items }
}
class JObj extends Json {
    jkeys: string[]      // 'keys' é reservado → jkeys
    vals: Json[]
    constructor(jkeys: string[], vals: Json[]) { this.jkeys = jkeys; this.vals = vals }
}

class JsonParser {
    src: string
    i: i64
    n: i64
    constructor(src: string) { this.src = src; this.i = 0; this.n = len(src) }

    peek(): i64 {
        if (this.i >= this.n) { return -1; }
        return peek8(this.src, this.i);
    }
    skipWs() {
        while (this.i < this.n) {
            const c: i64 = this.peek();
            if (c == 32 || c == 9 || c == 10 || c == 13) { this.i = this.i + 1; }
            else { break; }
        }
    }
    matchWord(word: string): bool {
        const wl: i64 = len(word);
        let j: i64 = 0;
        while (j < wl) {
            if (this.peek() != peek8(word, j)) { return false; }
            this.i = this.i + 1;
            j = j + 1;
        }
        return true;
    }

    value(): Json {
        this.skipWs();
        const c: i64 = this.peek();
        if (c == 123) { return this.object(); }                       // {
        if (c == 91) { return this.array(); }                         // [
        if (c == 34) { return new JStr(this.parseStr()); }            // "
        if (c == 116) { if (this.matchWord("true")) { return new JBool(true); } return new JNull(); }
        if (c == 102) { if (this.matchWord("false")) { return new JBool(false); } return new JNull(); }
        if (c == 110) { this.matchWord("null"); return new JNull(); }
        return this.number();
    }

    object(): Json {
        this.i = this.i + 1;                                          // {
        let ks: string[] = [];
        let vs: Json[] = [];
        this.skipWs();
        if (this.peek() == 125) { this.i = this.i + 1; return new JObj(ks, vs); }
        while (true) {
            this.skipWs();
            const k: string = this.parseStr();
            this.skipWs();
            if (this.peek() != 58) { return new JNull(); }            // :
            this.i = this.i + 1;
            const v: Json = this.value();
            ks.push(k);
            vs.push(v);
            this.skipWs();
            const c: i64 = this.peek();
            if (c == 44) { this.i = this.i + 1; }                     // ,
            else if (c == 125) { this.i = this.i + 1; return new JObj(ks, vs); }
            else { return new JNull(); }
        }
        return new JNull();
    }

    array(): Json {
        this.i = this.i + 1;                                          // [
        let items: Json[] = [];
        this.skipWs();
        if (this.peek() == 93) { this.i = this.i + 1; return new JArr(items); }
        while (true) {
            items.push(this.value());
            this.skipWs();
            const c: i64 = this.peek();
            if (c == 44) { this.i = this.i + 1; }                     // ,
            else if (c == 93) { this.i = this.i + 1; return new JArr(items); }
            else { return new JNull(); }
        }
        return new JNull();
    }

    // string entre aspas, com escapes. \uXXXX vira "?" (LSP é ~ASCII; lossy ok).
    parseStr(): string {
        if (this.peek() != 34) { return ""; }
        this.i = this.i + 1;
        let s: string = "";
        while (this.i < this.n) {
            const c: i64 = this.peek();
            this.i = this.i + 1;
            if (c == 34) { return s; }                                // " fecha
            if (c == 92) {                                            // \ escape
                const e: i64 = this.peek();
                this.i = this.i + 1;
                if (e == 34) { s = concat(s, "\""); }
                else if (e == 92) { s = concat(s, "\\"); }
                else if (e == 47) { s = concat(s, "/"); }
                else if (e == 110) { s = concat(s, "\n"); }
                else if (e == 116) { s = concat(s, "\t"); }
                else if (e == 114) { s = concat(s, "\r"); }
                else if (e == 117) {                                  // \uXXXX
                    this.i = this.i + 4;
                    s = concat(s, "?");
                }
                else { return s; }
            }
            else { s = concat(s, charAt(this.src, this.i - 1)); }
        }
        return s;
    }

    number(): Json {
        const start: i64 = this.i;
        while (this.i < this.n) {
            const c: i64 = this.peek();
            if ((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 101 || c == 69) {
                this.i = this.i + 1;
            } else { break; }
        }
        return new JNum(parseInt(substring(this.src, start, this.i)));
    }
}

// ── API ──────────────────────────────────────────────────────────────────────
fn jParse(input: string): Json {
    const p: JsonParser = new JsonParser(input);
    p.skipWs();
    return p.value();
}

fn jObjGet(o: JObj, key: string): Json {
    let i: i64 = 0;
    while (i < o.jkeys.len()) {
        if (strEq(o.jkeys[i], key)) { return o.vals[i]; }
        i = i + 1;
    }
    return new JNull();
}
fn jGet(j: Json, key: string): Json {
    return match (j) {
        JObj o => jObjGet(o, key),
        _ => new JNull()
    };
}
fn jStr(j: Json): string {
    return match (j) { JStr s => s.s, _ => "" };
}
fn jNum(j: Json): i64 {
    return match (j) { JNum x => x.n, _ => 0 };
}
fn emptyJsonArr(): Json[] { let e: Json[] = []; return e; }
fn jArr(j: Json): Json[] {
    return match (j) { JArr a => a.items, _ => emptyJsonArr() };
}
// acesso encadeado: jPath(doc, ["a", "b"]).
fn jPath(j: Json, ks: string[]): Json {
    let cur: Json = j;
    for (const k of ks) { cur = jGet(cur, k); }
    return cur;
}

// escapa uma string p/ um literal JSON (sem as aspas externas).
fn jHexDigit(d: i64): string { return charAt("0123456789abcdef", d); }
fn jEscape(s: string): string {
    let out: string = "";
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n) {
        const c: i64 = peek8(s, i);
        if (c == 34) { out = concat(out, "\\\""); }
        else if (c == 92) { out = concat(out, "\\\\"); }
        else if (c == 10) { out = concat(out, "\\n"); }
        else if (c == 13) { out = concat(out, "\\r"); }
        else if (c == 9) { out = concat(out, "\\t"); }
        else if (c < 32) {
            out = concat(out, concat("\\u00", concat(jHexDigit(c / 16), jHexDigit(c % 16))));
        }
        else { out = concat(out, charAt(s, i)); }
        i = i + 1;
    }
    return out;
}
