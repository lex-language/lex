// pkg.lex — núcleo do gerenciador de pacotes em lex (Fase F6.8-C). Espelha a
// lógica de parsing/manifesto de src/pkg.rs. As partes PURAS (parse de spec,
// normalização de URL, mutação do lex.toml) vivem aqui e são testáveis sem rede;
// o fetch via git/curl fica no driver (lexpkg.lex), ainda parcial.
import { TomlDoc, TomlSection, parseToml, serializeToml } from "./toml"

// uma dependência resolvida da forma textual: kind = "file"|"git"|"registry".
class DepSpec {
    name: string
    kind: string
    url: string         // git: URL clonável; file: caminho; registry: ""
    reqOrRef: string    // registry: req semver; git: ref/req; file: ""
    canonical: string   // forma a gravar no lex.toml
    constructor(name: string, kind: string, url: string, reqOrRef: string, canonical: string) {
        this.name = name; this.kind = kind; this.url = url
        this.reqOrRef = reqOrRef; this.canonical = canonical
    }
}

fn pStarts(s: string, pre: string): bool {
    if (len(pre) > len(s)) { return false; }
    return strEq(substring(s, 0, len(pre)), pre);
}
fn hasSlash(s: string): bool {
    const n: i64 = len(s);
    let i: i64 = 0;
    while (i < n) { if (peek8(s, i) == 47) { return true; } i = i + 1; }   // /
    return false;
}
// último segmento de um caminho/URL (após o último '/' ou '\'), sem barra final.
fn lastSegment(s: string): string {
    let e: i64 = len(s);
    while (e > 0 && (peek8(s, e - 1) == 47 || peek8(s, e - 1) == 92)) { e = e - 1; }
    let start: i64 = 0;
    let i: i64 = 0;
    while (i < e) { if (peek8(s, i) == 47 || peek8(s, i) == 92) { start = i + 1; } i = i + 1; }
    return substring(s, start, e);
}
fn stripDotGit(s: string): string {
    const n: i64 = len(s);
    if (n >= 4 && strEq(substring(s, n - 4, n), ".git")) { return substring(s, 0, n - 4); }
    return s;
}
fn looksUrl(s: string): bool {
    return hasSlash(s) || pStarts(s, "http://") || pStarts(s, "https://")
        || pStarts(s, "git@") || pStarts(s, "git:");
}
// índice do '@' útil (ignora o "git@host" inicial), ou -1.
fn markerAt(s: string): i64 {
    let start: i64 = 0;
    if (pStarts(s, "git@")) { start = 4; }
    let i: i64 = start;
    const n: i64 = len(s);
    while (i < n) { if (peek8(s, i) == 64) { return i; } i = i + 1; }      // @
    return -1;
}
// garante esquema clonável: "github.com/u/r" → "https://github.com/u/r".
fn normalizeGitUrl(u: string): string {
    if (pStarts(u, "http://") || pStarts(u, "https://") || pStarts(u, "git@")
        || pStarts(u, "ssh://") || pStarts(u, "git://") || pStarts(u, "file://")
        || pStarts(u, "/") || pStarts(u, "./") || pStarts(u, "../")) {
        return u;
    }
    return concat("https://", u);
}

// (nameHint vazio = sem dica). Espelha parse_dep de src/pkg.rs.
fn parseDep(nameHint: string, spec: string): DepSpec {
    if (pStarts(spec, "file:")) {
        const rest: string = substring(spec, 5, len(spec));
        let name: string = nameHint;
        if (strEq(name, "")) { name = lastSegment(rest); }
        return new DepSpec(name, "file", rest, "", spec);
    }
    if (looksUrl(spec)) {
        let raw: string = spec;
        if (pStarts(raw, "git:")) { raw = substring(raw, 4, len(raw)); }
        const at: i64 = markerAt(raw);
        let urlPart: string = raw;
        let refPart: string = "";
        if (at >= 0) { urlPart = substring(raw, 0, at); refPart = substring(raw, at + 1, len(raw)); }
        const url: string = normalizeGitUrl(urlPart);
        let name: string = nameHint;
        if (strEq(name, "")) { name = stripDotGit(lastSegment(urlPart)); }
        let canonical: string = urlPart;
        if (!strEq(refPart, "")) { canonical = concat(urlPart, concat("@", refPart)); }
        return new DepSpec(name, "git", url, refPart, canonical);
    }
    // registry: "nome@req" ou só "nome"; req default "*"
    const at: i64 = markerAt(spec);
    let head: string = spec;
    let ver: string = "*";
    if (at >= 0) { head = substring(spec, 0, at); ver = substring(spec, at + 1, len(spec)); }
    let name: string = nameHint;
    if (strEq(name, "")) { name = head; }
    return new DepSpec(name, "registry", "", ver, ver);
}

// ── manipulação do manifesto (lex.toml) ──────────────────────────────────────
fn newManifest(name: string): string {
    const doc: TomlDoc = new TomlDoc();
    const pkg: TomlSection = doc.ensureTable("package");
    pkg.setStr("name", name);
    pkg.setStr("version", "0.1.0");
    doc.ensureTable("dependencies");
    return serializeToml(doc);
}

// adiciona/atualiza uma dependência no [dependencies] e devolve o manifesto novo.
fn addDep(manifestSrc: string, depName: string, depValue: string): string {
    const doc: TomlDoc = parseToml(manifestSrc);
    doc.ensureTable("dependencies").setStr(depName, depValue);
    return serializeToml(doc);
}

// remove uma dependência (se existir) e devolve o manifesto novo.
fn removeDep(manifestSrc: string, depName: string): string {
    const doc: TomlDoc = parseToml(manifestSrc);
    const deps: TomlSection = doc.ensureTable("dependencies");
    let kept: TomlSection = new TomlSection("dependencies", false);
    for (const p of deps.pairs) {
        if (!strEq(p.key, depName)) { kept.pairs.push(p); }
    }
    deps.pairs = kept.pairs;
    return serializeToml(doc);
}
