// toml.lex — parser/serializer TOML em lex (Fase F6.8-A), para `lex.toml` e
// `lex.lock`. Cobre o subconjunto que o gerenciador de pacotes usa:
//   - tabelas `[secao]` e array-de-tabelas `[[secao]]`
//   - pares `chave = "string"` e `chave = ["a", "b", ...]` (listas de string)
//   - comentários de linha `#`
// Não cobre TOML completo (inteiros/datas/tabelas inline/multi-linha) — não é
// preciso aqui. Espelha o uso de toml::from_str/to_string_pretty em src/pkg.rs.

// um valor: string simples OU lista de strings
class TomlValue {
    isList: bool
    str: string
    list: string[]
    constructor(isList: bool, str: string, list: string[]) {
        this.isList = isList; this.str = str; this.list = list
    }
}
class TomlPair {
    key: string
    value: TomlValue
    constructor(key: string, value: TomlValue) { this.key = key; this.value = value }
}
class TomlSection {
    name: string            // "" = raiz; "package"; "dependencies"; …
    isArray: bool           // veio de `[[...]]`?
    pairs: TomlPair[]
    constructor(name: string, isArray: bool) { this.name = name; this.isArray = isArray; this.pairs = [] }

    getStr(key: string): string {
        for (const p of this.pairs) {
            if (strEq(p.key, key) && !p.value.isList) { return p.value.str; }
        }
        return "";
    }
    has(key: string): bool {
        for (const p of this.pairs) { if (strEq(p.key, key)) { return true; } }
        return false;
    }
    getList(key: string): string[] {
        for (const p of this.pairs) {
            if (strEq(p.key, key) && p.value.isList) { return p.value.list; }
        }
        let empty: string[] = [];
        return empty;
    }
    // define/atualiza uma chave string.
    setStr(key: string, value: string) {
        for (const p of this.pairs) {
            if (strEq(p.key, key)) { p.value.isList = false; p.value.str = value; return; }
        }
        let none: string[] = [];
        this.pairs.push(new TomlPair(key, new TomlValue(false, value, none)));
    }
    // define/atualiza uma chave de lista de strings.
    setList(key: string, value: string[]) {
        for (const p of this.pairs) {
            if (strEq(p.key, key)) { p.value.isList = true; p.value.list = value; return; }
        }
        this.pairs.push(new TomlPair(key, new TomlValue(true, "", value)));
    }
}
class TomlDoc {
    sections: TomlSection[]
    constructor() { this.sections = [] }

    // primeira tabela (não-array) com esse nome; cria uma vazia se não existir.
    table(name: string): TomlSection {
        for (const s of this.sections) {
            if (strEq(s.name, name) && !s.isArray) { return s; }
        }
        return new TomlSection(name, false);
    }
    // todas as `[[name]]` na ordem.
    arrayTables(name: string): TomlSection[] {
        let out: TomlSection[] = [];
        for (const s of this.sections) {
            if (strEq(s.name, name) && s.isArray) { out.push(s); }
        }
        return out;
    }
    // tabela `[name]` existente, ou cria uma nova (adicionada ao doc).
    ensureTable(name: string): TomlSection {
        for (const s of this.sections) {
            if (strEq(s.name, name) && !s.isArray) { return s; }
        }
        const t: TomlSection = new TomlSection(name, false);
        this.sections.push(t);
        return t;
    }
    // adiciona uma `[[name]]` nova e devolve.
    addArrayTable(name: string): TomlSection {
        const t: TomlSection = new TomlSection(name, true);
        this.sections.push(t);
        return t;
    }
}

// ── helpers de string ────────────────────────────────────────────────────────
fn tTrim(s: string): string {
    const n: i64 = len(s);
    let a: i64 = 0;
    while (a < n && (peek8(s, a) == 32 || peek8(s, a) == 9 || peek8(s, a) == 13)) { a = a + 1; }
    let b: i64 = n;
    while (b > a && (peek8(s, b - 1) == 32 || peek8(s, b - 1) == 9 || peek8(s, b - 1) == 13)) { b = b - 1; }
    return substring(s, a, b);
}
fn tStarts(s: string, pre: string): bool {
    const pl: i64 = len(pre);
    if (pl > len(s)) { return false; }
    return strEq(substring(s, 0, pl), pre);
}
// tira as aspas de `"..."` (sem tratar escapes — os dados são nomes/urls/versões)
fn unquote(s: string): string {
    const t: string = tTrim(s);
    const n: i64 = len(t);
    if (n >= 2 && peek8(t, 0) == 34 && peek8(t, n - 1) == 34) { return substring(t, 1, n - 1); }
    return t;
}

fn splitLinesT(src: string): string[] {
    let lines: string[] = [];
    const n: i64 = len(src);
    let start: i64 = 0;
    let i: i64 = 0;
    while (i < n) {
        if (peek8(src, i) == 10) { lines.push(substring(src, start, i)); start = i + 1; }
        i = i + 1;
    }
    if (start < n) { lines.push(substring(src, start, n)); }
    return lines;
}

// `["a", "b"]` → ["a", "b"]; `[]` → vazio.
fn parseList(s: string): string[] {
    let out: string[] = [];
    const t: string = tTrim(s);
    const n: i64 = len(t);
    if (n < 2) { return out; }
    const inner: string = substring(t, 1, n - 1);     // tira [ ]
    // divide por vírgulas (itens são strings simples, sem vírgula interna)
    let i: i64 = 0;
    let start: i64 = 0;
    const m: i64 = len(inner);
    while (i < m) {
        if (peek8(inner, i) == 44) {                  // ,
            const piece: string = tTrim(substring(inner, start, i));
            if (len(piece) > 0) { out.push(unquote(piece)); }
            start = i + 1;
        }
        i = i + 1;
    }
    const last: string = tTrim(substring(inner, start, m));
    if (len(last) > 0) { out.push(unquote(last)); }
    return out;
}

fn parseValue(raw: string): TomlValue {
    const t: string = tTrim(raw);
    if (tStarts(t, "[")) {
        let empty: string[] = [];
        return new TomlValue(true, "", parseList(t));
    }
    let none: string[] = [];
    return new TomlValue(false, unquote(t), none);
}

// índice do primeiro '=' (separador chave/valor), ou -1.
fn indexOfEq(s: string): i64 {
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n) { if (peek8(s, i) == 61) { return i; } i = i + 1; }
    return -1;
}

// ── parse / serialize ────────────────────────────────────────────────────────
fn parseToml(src: string): TomlDoc {
    const doc: TomlDoc = new TomlDoc();
    let cur: TomlSection = new TomlSection("", false);   // seção raiz
    let started: bool = false;                            // já abriu alguma seção?
    for (const raw of splitLinesT(src)) {
        const line: string = tTrim(raw);
        if (len(line) == 0) { }                       // linha vazia
        else if (peek8(line, 0) == 35) { }            // # comentário
        else if (tStarts(line, "[[")) {
            const e: i64 = len(line);
            const name: string = tTrim(substring(line, 2, e - 2));
            cur = new TomlSection(name, true);
            doc.sections.push(cur);
            started = true;
        }
        else if (tStarts(line, "[")) {
            const e: i64 = len(line);
            const name: string = tTrim(substring(line, 1, e - 1));
            cur = new TomlSection(name, false);
            doc.sections.push(cur);
            started = true;
        }
        else {
            const eq: i64 = indexOfEq(line);
            if (eq >= 0) {
                if (!started) { doc.sections.push(cur); started = true; }
                const key: string = tTrim(substring(line, 0, eq));
                const val: TomlValue = parseValue(substring(line, eq + 1, len(line)));
                cur.pairs.push(new TomlPair(key, val));
            }
        }
    }
    return doc;
}

fn serializeValue(v: TomlValue): string {
    if (!v.isList) { return `"${v.str}"`; }
    let s: string = "[";
    let first: bool = true;
    for (const item of v.list) {
        if (!first) { s = concat(s, ", "); }
        s = concat(s, `"${item}"`);
        first = false;
    }
    return concat(s, "]");
}
fn serializeToml(doc: TomlDoc): string {
    let out: string = "";
    let firstSec: bool = true;
    for (const s of doc.sections) {
        if (!strEq(s.name, "")) {
            if (!firstSec) { out = concat(out, "\n"); }
            if (s.isArray) { out = concat(out, `[[${s.name}]]\n`); }
            else { out = concat(out, `[${s.name}]\n`); }
        }
        for (const p of s.pairs) {
            out = concat(out, `${p.key} = ${serializeValue(p.value)}\n`);
        }
        firstSec = false;
    }
    return out;
}
