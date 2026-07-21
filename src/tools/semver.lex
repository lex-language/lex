// semver.lex — versões semânticas em lex (Fase F6.8-B). Usado pelo `pkg.lex`:
// parse de "1.2.3" (com 'v' opcional), comparação, e
// requisitos (`^`, `~`, `>=`, `>`, `<=`, `<`, `=`, `*`; bare = caret). Ignora
// pré-release/build (as tags do registry são x.y.z simples). Usado p/ escolher
// a maior versão que casa com o requisito.

class SemVer {
    major: i64
    minor: i64
    patch: i64
    constructor(major: i64, minor: i64, patch: i64) {
        this.major = major; this.minor = minor; this.patch = patch
    }
}

// "v1.2.3"/"1.2"/"1" → SemVer (partes ausentes = 0).
fn parseSemVer(s: string): SemVer {
    let t: string = s;
    if (len(t) > 0 && (peek8(t, 0) == 118 || peek8(t, 0) == 86)) { t = substring(t, 1, len(t)); }  // tira v/V
    let parts: i64[] = [];
    const n: i64 = len(t);
    let start: i64 = 0;
    let i: i64 = 0;
    while (i < n) {
        if (peek8(t, i) == 46) { parts.push(parseInt(substring(t, start, i))); start = i + 1; }   // .
        i = i + 1;
    }
    parts.push(parseInt(substring(t, start, n)));
    let maj: i64 = 0;
    let mnr: i64 = 0;
    let pat: i64 = 0;
    if (parts.len() >= 1) { maj = parts[0]; }
    if (parts.len() >= 2) { mnr = parts[1]; }
    if (parts.len() >= 3) { pat = parts[2]; }
    return new SemVer(maj, mnr, pat);
}

// -1 se a<b, 0 se igual, 1 se a>b.
fn cmpSemVer(a: SemVer, b: SemVer): i64 {
    if (a.major != b.major) { if (a.major < b.major) { return -1; } return 1; }
    if (a.minor != b.minor) { if (a.minor < b.minor) { return -1; } return 1; }
    if (a.patch != b.patch) { if (a.patch < b.patch) { return -1; } return 1; }
    return 0;
}

class VersionReq {
    op: string          // "^" "~" ">=" ">" "<=" "<" "=" ; "" se any
    any: bool           // "*" ou vazio → casa qualquer
    ver: SemVer
    constructor(op: string, any: bool, ver: SemVer) { this.op = op; this.any = any; this.ver = ver }
}

fn parseReq(s: string): VersionReq {
    const t: string = s;
    let zero: SemVer = new SemVer(0, 0, 0);
    if (len(t) == 0 || strEq(t, "*")) { return new VersionReq("", true, zero); }
    if (peek8(t, 0) == 94) { return new VersionReq("^", false, parseSemVer(substring(t, 1, len(t)))); }  // ^
    if (peek8(t, 0) == 126) { return new VersionReq("~", false, parseSemVer(substring(t, 1, len(t)))); } // ~
    if (len(t) >= 2 && peek8(t, 0) == 62 && peek8(t, 1) == 61) {                                          // >=
        return new VersionReq(">=", false, parseSemVer(substring(t, 2, len(t))));
    }
    if (len(t) >= 2 && peek8(t, 0) == 60 && peek8(t, 1) == 61) {                                          // <=
        return new VersionReq("<=", false, parseSemVer(substring(t, 2, len(t))));
    }
    if (peek8(t, 0) == 62) { return new VersionReq(">", false, parseSemVer(substring(t, 1, len(t)))); }   // >
    if (peek8(t, 0) == 60) { return new VersionReq("<", false, parseSemVer(substring(t, 1, len(t)))); }   // <
    if (peek8(t, 0) == 61) { return new VersionReq("=", false, parseSemVer(substring(t, 1, len(t)))); }   // =
    return new VersionReq("^", false, parseSemVer(t));   // bare = caret (convenção do semver)
}

// limite superior (exclusivo) do caret: ^1.2.3<2.0.0; ^0.2.3<0.3.0; ^0.0.3<0.0.4.
fn caretUpper(v: SemVer): SemVer {
    if (v.major > 0) { return new SemVer(v.major + 1, 0, 0); }
    if (v.minor > 0) { return new SemVer(0, v.minor + 1, 0); }
    return new SemVer(0, 0, v.patch + 1);
}

fn reqMatches(req: VersionReq, v: SemVer): bool {
    if (req.any) { return true; }
    const c: i64 = cmpSemVer(v, req.ver);
    if (strEq(req.op, "=")) { return c == 0; }
    if (strEq(req.op, ">=")) { return c >= 0; }
    if (strEq(req.op, ">")) { return c > 0; }
    if (strEq(req.op, "<=")) { return c <= 0; }
    if (strEq(req.op, "<")) { return c < 0; }
    if (strEq(req.op, "^")) {
        if (c < 0) { return false; }
        return cmpSemVer(v, caretUpper(req.ver)) < 0;
    }
    if (strEq(req.op, "~")) {
        if (c < 0) { return false; }
        const upper: SemVer = new SemVer(req.ver.major, req.ver.minor + 1, 0);
        return cmpSemVer(v, upper) < 0;
    }
    return false;
}

// ── conveniências (strings) p/ os testes e p/ o pkg ──────────────────────────
fn semverCmp(a: string, b: string): i64 {
    return cmpSemVer(parseSemVer(a), parseSemVer(b));
}
fn semverMatches(reqStr: string, vStr: string): bool {
    return reqMatches(parseReq(reqStr), parseSemVer(vStr));
}
// maior versão de `versions` que casa com `reqStr`, ou "" se nenhuma.
fn semverPickBest(reqStr: string, versions: string[]): string {
    const req: VersionReq = parseReq(reqStr);
    let best: string = "";
    let haveBest: bool = false;
    for (const vs of versions) {
        const v: SemVer = parseSemVer(vs);
        if (reqMatches(req, v)) {
            if (!haveBest || cmpSemVer(v, parseSemVer(best)) > 0) { best = vs; haveBest = true; }
        }
    }
    return best;
}
