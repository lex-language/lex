// lsx.lex — o front-end dos arquivos .lsx (componentes no estilo Astro).
//
// Um .lsx é um arquivo com DUAS metades:
//
//     ---                          <- frontmatter: código lex normal
//     import { Card } from "./Card.lsx"
//     class Props { titulo: string }
//     const cor: string = "azul";
//     ---
//     <div class="${cor}">         <- corpo: markup, com {expr} interpolando
//       <h2>{props.titulo}</h2>
//     </div>
//
// e que vira UM módulo lex comum:
//
//     class <Nome>Props { titulo: string; constructor(titulo: string) {…} }
//     fn <Nome>(props: <Nome>Props): string {
//         const cor: string = "azul";          // os stmts do frontmatter
//         return `<div …>…</div>`;             // o corpo, como Template
//     }
//
// O NOME DO COMPONENTE É O NOME DO ARQUIVO (Card.lsx → Card). Como o espaço de
// nomes do lex é plano e global, dois Card.lsx em pastas diferentes colidiriam —
// o ModuleLoader acusa isso explicitamente em vez de deixar as tags se
// embaralharem em silêncio.
//
// Por que o corpo é fatiado AQUI e não no lexer: o `---` não é token (lexa como
// `--` + `-`), e markup em início de linha não passa por `markupPos`, que só
// reconhece `<` logo após `return`/`=`/`(`/… Tratando o corpo inteiro como um
// literal só, os dois problemas somem e o núcleo do compilador fica intocado.
import { lexSrc, Tok } from "./lexer"
import { Program, ClassDecl, ClassField, Func, Param, Stmt, Expr, ReturnStmt, AssignStmt, Field, Var, StrLit, BoolLit, IntLit, FloatLit, Template, ElementExpr, Parser, Call, LetStmt, Import, Unary, Binary, MethodCall, ArrayLit, IfStmt, WhileStmt, BreakStmt, ContinueStmt, ExprStmt, NewExpr, Index, ForOfStmt, ForStmt } from "./parser"

// nome do componente a partir do caminho: "a/b/Card.lsx" → "Card".
fn componentName(path: string): string {
    const n: i64 = len(path);

    // Dentro de `pages/` o nome é o CAMINHO inteiro a partir dali, e não só o
    // arquivo: sob roteamento por arquivo, `index.lsx` se repete em cada pasta
    // (é assim que `pages/docs/index.lsx` vira `/docs`), e com o nome-do-arquivo
    // os dois viravam o mesmo símbolo `index` num espaço de nomes plano. O
    // ModuleLoader acusava a colisão, mas o layout que a provoca é o NORMAL —
    // então aqui ela deixa de existir: `pages/docs/index.lsx` → `docs_index`.
    const p: i64 = afterPagesSeg(path);
    if (p >= 0) { return sanitizeIdent(stripLsx(substring(path, p, n))); }

    let cut: i64 = -1;
    let i: i64 = 0;
    while (i < n) {
        if (peek8(path, i) == 47) { cut = i; }        // '/'
        i = i + 1;
    }
    return stripLsx(substring(path, cut + 1, n));
}

fn stripLsx(base: string): string {
    const bn: i64 = len(base);
    if (bn > 4 && strEq(substring(base, bn - 4, bn), ".lsx")) {
        return substring(base, 0, bn - 4);
    }
    return base;
}

// Byte seguinte ao último segmento `pages/` do caminho; -1 se não houver.
// Tem de ser um SEGMENTO inteiro — `subpages/x.lsx` não conta.
fn afterPagesSeg(path: string): i64 {
    const seg: string = "pages/";
    const sn: i64 = len(seg);
    let achou: i64 = 0 - 1;
    let i: i64 = 0;
    const n: i64 = len(path);
    while (i + sn <= n) {
        if (strEq(substring(path, i, i + sn), seg)) {
            if (i == 0 || peek8(path, i - 1) == 47) { achou = i + sn; }
        }
        i = i + 1;
    }
    return achou;
}

// O nome vira um SÍMBOLO na IR, então só [A-Za-z0-9_] sobrevive: uma pasta
// `docs-api/` daria `docs-api_index`, que não é identificador. A rota continua
// com o traço — quem é sanitizado é o símbolo, não o caminho.
fn sanitizeIdent(s: string): string {
    let out: string = "";
    let i: i64 = 0;
    while (i < len(s)) {
        const c: i64 = peek8(s, i);
        const ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
        if (ok) { out = concat(out, charAt(s, i)); }
        else { out = concat(out, "_"); }
        i = i + 1;
    }
    return out;
}

// nome da classe de props de um componente. Ver a nota de colisão no topo.
fn propsClassName(comp: string): string { return concat(comp, "Props"); }

// ── fatiar o frontmatter ────────────────────────────────────────────────────
// Um `---` sozinho numa linha abre; o próximo `---` sozinho numa linha fecha.
// Devolve o índice do byte onde o CORPO começa; -1 = não há frontmatter.
// `fmEnd` recebe (por array de 1) o fim do frontmatter.
fn isDashLine(src: string, i: i64, n: i64): bool {
    if (i + 3 > n) { return false; }
    if (peek8(src, i) != 45 || peek8(src, i + 1) != 45 || peek8(src, i + 2) != 45) { return false; }
    // resto da linha só pode ter espaço
    let j: i64 = i + 3;
    while (j < n && peek8(src, j) != 10) {
        const c: i64 = peek8(src, j);
        if (c != 32 && c != 9 && c != 13) { return false; }
        j = j + 1;
    }
    return true;
}

// avança até o byte seguinte ao próximo '\n' (ou o fim).
fn afterLine(src: string, i: i64, n: i64): i64 {
    let j: i64 = i;
    while (j < n && peek8(src, j) != 10) { j = j + 1; }
    if (j < n) { j = j + 1; }
    return j;
}

// Acha o `---` que FECHA o frontmatter; -1 se não houver.
//
// Não basta olhar linha a linha: o frontmatter é código lex, e uma página que
// documenta o próprio formato tem `---` DENTRO de uma string — foi o que
// aconteceu com a landing page. O fecho era detectado no meio do literal, o
// corpo começava no meio de uma string e a interpolação `{nome}` do exemplo
// virava uma variável de verdade. O erro só aparecia no clang, como
// "use of undefined value '%nome.addr'", que não diz nada sobre o que houve.
//
// Então a varredura pula strings ("…", '…' e crase) e comentários (// e /*…*/)
// — sem os comentários, um apóstrofo em "// não" abriria uma string e comeria
// o resto do arquivo.
fn findFmEnd(src: string, fmStart: i64, n: i64): i64 {
    let i: i64 = fmStart;
    let lineStart: bool = true;
    while (i < n) {
        if (lineStart && isDashLine(src, i, n)) { return i; }
        const c: i64 = peek8(src, i);

        if (c == 47 && i + 1 < n && peek8(src, i + 1) == 47) {        // //
            i = afterLine(src, i, n);
            lineStart = true;
            continue;
        }
        if (c == 47 && i + 1 < n && peek8(src, i + 1) == 42) {        // /*
            i = i + 2;
            while (i + 1 < n && !(peek8(src, i) == 42 && peek8(src, i + 1) == 47)) { i = i + 1; }
            i = i + 2;
            lineStart = false;
            continue;
        }
        if (c == 34 || c == 39 || c == 96) {                          // " ' `
            const q: i64 = c;
            i = i + 1;
            while (i < n && peek8(src, i) != q) {
                if (peek8(src, i) == 92) { i = i + 1; }                // escape
                i = i + 1;
            }
            i = i + 1;
            lineStart = false;
            continue;
        }

        lineStart = c == 10;
        i = i + 1;
    }
    return 0 - 1;
}

// ── interpolação `{expr}` ───────────────────────────────────────────────────
// Acha o `}` que fecha o `{` em `i0`. Conta profundidade de chaves e RESPEITA
// strings ("…", '…' e crase), senão um `{ f("}") }` fecharia cedo.
fn matchBrace(src: string, i0: i64, n: i64): i64 {
    let i: i64 = i0 + 1;
    let depth: i64 = 1;
    while (i < n) {
        const c: i64 = peek8(src, i);
        if (c == 34 || c == 39 || c == 96) {          // " ' `
            const q: i64 = c;
            i = i + 1;
            while (i < n && peek8(src, i) != q) {
                if (peek8(src, i) == 92) { i = i + 1; }   // escape
                i = i + 1;
            }
            i = i + 1;
            continue;
        }
        if (c == 123) { depth = depth + 1; }
        else if (c == 125) {
            depth = depth - 1;
            if (depth == 0) { return i; }
        }
        i = i + 1;
    }
    return -1;
}

// nome da tag que começa em `i` (logo após o '<' ou '</'); "" se não for tag.
fn tagNameAt(src: string, i: i64, n: i64): string {
    let j: i64 = i;
    while (j < n) {
        const c: i64 = peek8(src, j);
        const ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 95;
        if (!ok) { break; }
        j = j + 1;
    }
    return substring(src, i, j);
}

fn lowerEq(a: string, b: string): bool { return strEq(toLower(a), b); }

// Convenção JSX/Astro: tag capitalizada = componente, minúscula = HTML literal.
fn isComponentTag(nm: string): bool {
    if (len(nm) == 0) { return false; }
    const c: i64 = peek8(nm, 0);
    return c >= 65 && c <= 90;
}

// ── atributos de uma tag de componente ──────────────────────────────────────
// Aceita `nome="literal"` e `nome={expr}`. Um atributo solto (`disabled`) vale
// `true`. Devolve o índice logo após o `>` que fecha a tag de abertura; grava
// em `sc` (array de 1) se a tag era self-closing.
class Attrs {
    names: string[]
    vals: Expr[]
    end: i64
    selfClose: bool
    island: bool        // a tag trazia `client:load`
    constructor() {
        this.names = []; this.vals = []; this.end = 0
        this.selfClose = false; this.island = false
    }
}

// nome de ATRIBUTO: como o de tag, mas aceita ':' (é o que permite `client:load`).
fn attrNameAt(src: string, i: i64, n: i64): string {
    let j: i64 = i;
    while (j < n) {
        const c: i64 = peek8(src, j);
        const ok: bool = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 95 || c == 58;
        if (!ok) { break; }
        j = j + 1;
    }
    return substring(src, i, j);
}

// `client:load` e amigos: diretiva de hidratação, não é prop do componente.
// `startsWith` é um builtin que devolve i64 (0/1), não bool — daí o `!= 0`.
fn isClientDirective(nm: string): bool { return startsWith(nm, "client:") != 0; }

fn parseAttrs(raw: string, i0: i64, n: i64, basePos: i64, host: Parser): Attrs {
    const a: Attrs = new Attrs();
    let i: i64 = i0;
    while (i < n) {
        const c: i64 = peek8(raw, i);
        if (c == 32 || c == 9 || c == 10 || c == 13) { i = i + 1; continue; }
        if (c == 62) { a.end = i + 1; return a; }                        // '>'
        if (c == 47 && i + 1 < n && peek8(raw, i + 1) == 62) {           // '/>'
            a.selfClose = true; a.end = i + 2; return a;
        }
        const nm: string = attrNameAt(raw, i, n);
        if (len(nm) == 0) { i = i + 1; continue; }                       // byte solto
        i = i + len(nm);
        if (isClientDirective(nm)) {                                     // client:load
            a.island = true;
            while (i < n && (peek8(raw, i) == 32 || peek8(raw, i) == 9)) { i = i + 1; }
            if (i < n && peek8(raw, i) == 61) {                           // valor opcional
                i = i + 1;
                while (i < n && (peek8(raw, i) == 32 || peek8(raw, i) == 9)) { i = i + 1; }
                const q0: i64 = peek8(raw, i);
                if (q0 == 34 || q0 == 39) {
                    i = i + 1;
                    while (i < n && peek8(raw, i) != q0) { i = i + 1; }
                    i = i + 1;
                }
            }
            continue;
        }
        while (i < n && (peek8(raw, i) == 32 || peek8(raw, i) == 9)) { i = i + 1; }
        if (i < n && peek8(raw, i) == 61) {                              // '='
            i = i + 1;
            while (i < n && (peek8(raw, i) == 32 || peek8(raw, i) == 9)) { i = i + 1; }
            const q: i64 = peek8(raw, i);
            if (q == 34 || q == 39) {                                    // "…" ou '…'
                let j: i64 = i + 1;
                while (j < n && peek8(raw, j) != q) { j = j + 1; }
                a.names.push(nm);
                a.vals.push(new StrLit(substring(raw, i + 1, j)));
                i = j + 1;
            } else if (q == 123) {                                       // {expr}
                const close: i64 = matchBrace(raw, i, n);
                if (close < 0) {
                    host.recordErrAt(basePos + i, concat(concat("lsx: '{' sem '}' no atributo '", nm), "'"));
                    a.end = n; return a;
                }
                a.names.push(nm);
                a.vals.push(subExpr(substring(raw, i + 1, close), basePos + i + 1, host));
                i = close + 1;
            } else {
                host.recordErrAt(basePos + i, concat(concat("lsx: valor do atributo '", nm), "' precisa ser \"texto\" ou {expr}"));
                i = i + 1;
            }
        } else {
            a.names.push(nm);                                            // atributo solto = true
            a.vals.push(new BoolLit(true));
        }
    }
    a.end = n;
    return a;
}

// acha `</Nome>` no mesmo nível de aninhamento a partir de `i0`; -1 se não há.
// Uma tag `<Nome … />` aninhada NÃO abre nível — senão `<Card><Card/></Card>`
// contaria um fecho a mais e engoliria o resto do arquivo.
fn findCloseTag(raw: string, i0: i64, n: i64, nm: string): i64 {
    let i: i64 = i0;
    let depth: i64 = 0;
    while (i < n) {
        if (peek8(raw, i) == 60) {                                       // '<'
            if (i + 1 < n && peek8(raw, i + 1) == 47) {
                if (strEq(tagNameAt(raw, i + 2, n), nm)) {
                    if (depth == 0) { return i; }
                    depth = depth - 1;
                }
            } else if (strEq(tagNameAt(raw, i + 1, n), nm)) {
                // só conta se NÃO for self-closing
                let j: i64 = i + 1;
                let sc: bool = false;
                while (j < n && peek8(raw, j) != 62) {
                    const q: i64 = peek8(raw, j);
                    if (q == 34 || q == 39) {                            // aspas
                        j = j + 1;
                        while (j < n && peek8(raw, j) != q) { j = j + 1; }
                    } else if (q == 47 && j + 1 < n && peek8(raw, j + 1) == 62) {
                        sc = true; break;
                    }
                    j = j + 1;
                }
                if (!sc) { depth = depth + 1; }
            }
        }
        i = i + 1;
    }
    return -1;
}

// texto de uma interpolação → Expr, com um sub-parser. Os lambdas içados e os
// erros voltam para o parser hospedeiro (senão o link acusa símbolo indefinido
// e os erros de sintaxe somem — ver a nota em Parser.parseTemplate).
fn subExpr(inner: string, at: i64, host: Parser): Expr {
    const sub: Parser = new Parser(lexSrc(inner));
    sub.lambdaN = host.lambdaN;
    sub.curClassName = host.curClassName;
    const e: Expr = sub.parseExpr();
    host.lambdaN = sub.lambdaN;
    for (const lm of sub.lambdas) { host.lambdas.push(lm); }
    let ei: i64 = 0;
    while (ei < sub.errs.len()) {
        host.recordErrAt(at + sub.errPos[ei], sub.errs[ei]);
        ei = ei + 1;
    }
    return e;
}

// ── escopo de <style> ───────────────────────────────────────────────────────
// Cada componente com <style> ganha um atributo `data-lsx-<hash>`, injetado em
// toda tag HTML literal do seu corpo e anexado a todo seletor do seu CSS. É o
// mesmo truque de Vue/Svelte: o CSS deixa de vazar sem precisar de runtime.
//
// O hash vem do NOME do componente, que o loader já garante ser único no
// programa — então é estável entre builds (importa para diff de output).
fn scopeHash(comp: string): string {
    let h: i64 = 2166136261;                       // FNV-1a de 32 bits
    let i: i64 = 0;
    while (i < len(comp)) {
        h = h ^ peek8(comp, i);
        h = (h * 16777619) & 4294967295;
        i = i + 1;
    }
    const digits: string = "0123456789abcdefghijklmnopqrstuvwxyz";
    let out: string = "";
    let k: i64 = 0;
    while (k < 6) {
        out = concat(out, charAt(digits, h % 36));
        h = h / 36;
        k = k + 1;
    }
    return out;
}

fn isSpaceByte(c: i64): bool { return c == 32 || c == 9 || c == 10 || c == 13; }

// ── <style is:global> ───────────────────────────────────────────────────────
// Um .lsx é um COMPONENTE: não escreve `<html>` nem `<body>`, que vêm do
// envelope do documento (ver lexDocument em std/web.lex). Por isso um reset
// global (`*`, `:root`, `body`) não pode ser escopado — `body[data-lsx-x]` não
// casaria com um `<body>` que o componente nem emite. `is:global` diz "este
// bloco sai como está", igual ao Astro.

// a tag que ABRE em `i` traz `is:global`?
fn styleIsGlobal(raw: string, i: i64, n: i64): bool {
    let j: i64 = i;
    while (j < n && peek8(raw, j) != 62) { j = j + 1; }      // até o '>'
    return contains(toLower(substring(raw, i, j)), "is:global") != 0;
}

// a diretiva é do compilador, não HTML — some da saída. O espaço que a separava
// do nome da tag vai junto, senão sobra um `<style >` na página.
fn stripDirective(tag: string, dir: string): string {
    let at: i64 = indexOf(toLower(tag), dir);
    if (at < 0) { return tag; }
    let fim: i64 = at + len(dir);
    while (at > 0 && peek8(tag, at - 1) == 32) { at = at - 1; }
    return concat(substring(tag, 0, at), substring(tag, fim, len(tag)));
}

// há algum <style> LOCAL? Só ele exige o atributo de escopo nas tags — se o
// arquivo só tem estilo global, marcar cada tag com `data-lsx-…` seria ruído.
fn hasScopedStyle(body: string): bool {
    const low: string = toLower(body);
    const n: i64 = len(low);
    let i: i64 = 0;
    while (i < n) {
        const at: i64 = indexOf(substring(low, i, n), "<style");
        if (at < 0) { return false; }
        const start: i64 = i + at;
        let j: i64 = start;
        while (j < n && peek8(low, j) != 62) { j = j + 1; }
        if (!contains(substring(low, start, j), "is:global")) { return true; }
        i = j + 1;
    }
    return false;
}

// anexa `[attr]` a cada seletor do CSS. Anda por profundidade de chaves, então
// as regras dentro de um `@media` também são escopadas — mas o prelúdio do
// próprio `@media` passa intacto (não é seletor).
fn scopeCss(css: string, attr: string): string {
    let out: string = "";
    let sel: string = "";
    let i: i64 = 0;
    const n: i64 = len(css);
    while (i < n) {
        const c: i64 = peek8(css, i);
        if (c == 123) {                                        // '{'
            const t: string = trim(sel);
            if (len(t) > 0 && peek8(t, 0) == 64) {             // '@' — at-rule
                out = concat(out, concat(sel, "{"));
            } else {
                let scoped: string = "";
                let first: bool = true;
                for (const one of split(t, ",")) {
                    const s: string = trim(one);
                    if (len(s) == 0) { continue; }
                    if (!first) { scoped = concat(scoped, ", "); }
                    scoped = concat(scoped, concat(s, concat("[", concat(attr, "]"))));
                    first = false;
                }
                if (len(scoped) == 0) { scoped = t; }
                out = concat(out, concat(scoped, " {"));
            }
            sel = "";
            i = i + 1;
            continue;
        }
        if (c == 125) {                                        // '}'
            out = concat(out, concat(sel, "}"));
            sel = "";
            i = i + 1;
            continue;
        }
        sel = concat(sel, charAt(css, i));
        i = i + 1;
    }
    return concat(out, sel);
}

// ── o corpo → Template ──────────────────────────────────────────────────────
// Percorre o markup cru. Texto vira StrLit BYTE A BYTE (nada de processar `\n`:
// isto é HTML, e um `\d` num atributo de regex tem de sobreviver). `{expr}`
// vira a expressão parseada. `<style>`/`<script>` são RAW TEXT — o conteúdo sai
// intacto, o que também evita que um `i < n` dentro de script vire tag.
//
// `host` empresta o parser de quem chamou, p/ que os lambdas içados e os erros
// das interpolações não se percam (mesmo motivo do sub-parser em parseTemplate).
// Estado que atravessa a recursão do corpo: o parser hospedeiro, o atributo de
// escopo do <style> ("" = componente sem estilo) e se o corpo usou <slot/>.
class LsxCtx {
    host: Parser
    attr: string
    usedSlot: bool
    constructor(host: Parser, attr: string) {
        this.host = host; this.attr = attr; this.usedSlot = false
    }
}

fn parseLsxBody(raw: string, basePos: i64, ctx: LsxCtx): Expr {
    const host: Parser = ctx.host;
    let parts: Expr[] = [];
    let lit: string = "";
    let i: i64 = 0;
    let inTag: bool = false;        // estamos entre `<` e `>` de uma tag literal?
    const n: i64 = len(raw);
    while (i < n) {
        const c: i64 = peek8(raw, i);

        // <style> / <script>: copia cru até a tag de fecho correspondente.
        if (c == 60 && i + 1 < n) {
            const nm: string = tagNameAt(raw, i + 1, n);
            if (lowerEq(nm, "style") || lowerEq(nm, "script")) {
                let j: i64 = i + 1;
                let stop: i64 = -1;
                while (j < n) {
                    if (peek8(raw, j) == 60 && j + 1 < n && peek8(raw, j + 1) == 47) {
                        if (lowerEq(tagNameAt(raw, j + 2, n), toLower(nm))) { stop = j; break; }
                    }
                    j = j + 1;
                }
                if (stop < 0) { stop = n; }
                let k: i64 = stop;
                while (k < n && peek8(raw, k) != 62) { k = k + 1; }   // até o '>'
                if (k < n) { k = k + 1; }
                const global: bool = lowerEq(nm, "style") && styleIsGlobal(raw, i, n);
                if (lowerEq(nm, "style") && !strEq(ctx.attr, "") && !global) {
                    // só o MIOLO é reescrito; as tags de abertura/fecho passam
                    let open: i64 = i;
                    while (open < n && peek8(raw, open) != 62) { open = open + 1; }
                    open = open + 1;
                    lit = concat(lit, substring(raw, i, open));
                    lit = concat(lit, scopeCss(substring(raw, open, stop), ctx.attr));
                    lit = concat(lit, substring(raw, stop, k));
                } else if (global) {
                    // sai inteiro, sem escopo — só a diretiva não vai junto.
                    let open: i64 = i;
                    while (open < n && peek8(raw, open) != 62) { open = open + 1; }
                    open = open + 1;
                    lit = concat(lit, stripDirective(substring(raw, i, open), "is:global"));
                    lit = concat(lit, substring(raw, open, k));
                } else {
                    lit = concat(lit, substring(raw, i, k));
                }
                i = k;
                continue;
            }
        }

        // <slot /> — o ponto onde o conteúdo dos filhos entra. Vira `props.children`.
        if (c == 60 && i + 1 < n) {
            const nm: string = tagNameAt(raw, i + 1, n);
            if (lowerEq(nm, "slot")) {
                let k: i64 = i + 1;
                while (k < n && peek8(raw, k) != 62) { k = k + 1; }
                k = k + 1;
                // <slot></slot> — o conteúdo entre as tags seria o fallback, que
                // ainda não suportamos; pula até o fecho p/ não vazar markup.
                if (i + 1 + len(nm) < n && peek8(raw, k - 2) != 47) {
                    const close: i64 = findCloseTag(raw, k, n, nm);
                    if (close >= 0) {
                        let z: i64 = close;
                        while (z < n && peek8(raw, z) != 62) { z = z + 1; }
                        k = z + 1;
                    }
                }
                if (len(lit) > 0) { parts.push(new StrLit(lit)); lit = ""; }
                parts.push(new Field(new Var("props", 0), "children"));
                ctx.usedSlot = true;
                i = k;
                continue;
            }
        }

        // <Componente …/> ou <Componente …>filhos</Componente>
        if (c == 60 && i + 1 < n) {
            const nm: string = tagNameAt(raw, i + 1, n);
            if (isComponentTag(nm)) {
                const a: Attrs = parseAttrs(raw, i + 1 + len(nm), n, basePos, host);
                let kids: Expr = new StrLit("");
                let hasKids: bool = false;
                let after: i64 = a.end;
                if (!a.selfClose) {
                    const close: i64 = findCloseTag(raw, a.end, n, nm);
                    if (close < 0) {
                        host.recordErrAt(basePos + i, concat(concat("lsx: <", nm), "> nunca é fechado"));
                        after = n;
                    } else {
                        kids = parseLsxBody(substring(raw, a.end, close), basePos + a.end, ctx);
                        hasKids = true;
                        let k: i64 = close;
                        while (k < n && peek8(raw, k) != 62) { k = k + 1; }
                        after = k + 1;
                    }
                }
                if (len(lit) > 0) { parts.push(new StrLit(lit)); lit = ""; }
                const el: ElementExpr = new ElementExpr(nm, a.names, a.vals, kids, hasKids, basePos + i);
                el.island = a.island;
                parts.push(el);
                i = after;
                continue;
            }
            // tag HTML literal: injeta o atributo de escopo logo após o nome
            if (!strEq(ctx.attr, "") && len(nm) > 0 && peek8(raw, i + 1) != 47) {
                const at: i64 = i + 1 + len(nm);
                lit = concat(lit, substring(raw, i, at));
                lit = concat(lit, concat(" ", ctx.attr));
                inTag = true;        // este ramo pula o fallback que rastreia isto
                i = at;
                continue;
            }
        }

        // {expr}
        if (c == 123) {
            const close: i64 = matchBrace(raw, i, n);
            if (close < 0) {
                host.recordErrAt(basePos + i, "lsx: '{' sem '}' correspondente");
                lit = concat(lit, charAt(raw, i));
                i = i + 1;
                continue;
            }
            // `<div title={x}>` — o valor TEM de sair entre aspas. Sem isto um
            // texto com espaço (`title=a b`) quebraria a tag, e o bug só
            // apareceria com o dado certo em produção.
            const bare: bool = inTag && len(lit) > 0 && peek8(lit, len(lit) - 1) == 61;
            if (bare) { lit = concat(lit, "\""); }
            if (len(lit) > 0) { parts.push(new StrLit(lit)); lit = ""; }
            parts.push(subExpr(substring(raw, i + 1, close), basePos + i + 1, host));
            if (bare) { lit = "\""; }
            i = close + 1;
            continue;
        }

        if (c == 60) { inTag = true; }
        else if (c == 62) { inTag = false; }
        lit = concat(lit, charAt(raw, i));
        i = i + 1;
    }
    if (len(lit) > 0) { parts.push(new StrLit(lit)); }
    // ESCAPA: este é o corpo de um componente, onde uma interpolação de tipo
    // `string` é dado (potencialmente de usuário) e não markup. O que já é
    // markup — outro componente, ou um `html(...)` explícito — tem tipo `Html`
    // e passa intacto.
    const tpl: Template = new Template(parts);
    tpl.escapes = true;
    return tpl;
}

// ── a classe de props ───────────────────────────────────────────────────────
// O usuário escreve `class Props { … }` (como o `interface Props` do Astro).
// Renomeamos p/ `<Nome>Props` e, se não houver constructor, sintetizamos um
// POSICIONAL — sem ele o `new` só aloca e zera os slots (ver genNew), e as
// props chegariam todas vazias.
// `<slot/>` no corpo ⇒ o componente recebe o conteúdo dos filhos. O campo entra
// por ÚLTIMO para que a ordem posicional das props escritas à mão não mude.
fn addChildrenField(cd: ClassDecl) {
    for (const f of cd.fields) {
        if (strEq(f.name, "children")) { return; }
    }
    cd.fields.push(new ClassField("children", "Html"));   // o slot já é markup
}

fn synthPropsCtor(cd: ClassDecl) {
    for (const m of cd.methods) {
        if (strEq(m.name, "constructor")) { return; }
    }
    let ps: Param[] = [];
    let body: Stmt[] = [];
    for (const f of cd.fields) {
        ps.push(new Param(f.name, f.ty));
        body.push(new AssignStmt(new Field(new Var("this", 0), f.name), new Var(f.name, 0)));
    }
    cd.methods.push(new Func("constructor", ps, "", false, body));
}

// ── o objeto `Lex` (o `Astro` do Astro) ─────────────────────────────────────
// Uma página que menciona `Lex.` recebe, no topo de CADA função do arquivo,
// um `const Lex: LexCtx = lexCtx();`. Com isso `Lex.request.path` é só acesso
// a campo de um local comum — nada de namespace mágico no codegen, nada de
// reescrever AST, e o typecheck valida os campos como valida qualquer classe.
//
// Por que um LOCAL e não um parâmetro do componente: a assinatura de render é
// `Comp(props): Html`, e é ela que faz `<Card/>` compor. Passar o contexto como
// argumento obrigaria todo componente no caminho a repassá-lo — inclusive os
// que não o usam. O contexto mora numa slot POR THREAD (ver std/web.lex), que é
// o que mantém duas requisições concorrentes separadas.
//
// A decisão é textual e por ARQUIVO, no espírito do teste de `<style` logo
// abaixo: um .lsx que não fala de `Lex.` não paga nada — nem o import de
// std/web, o que importa para as ilhas, que vão para o wasm.
// `contains` é builtin e devolve i64 (0/1), não bool — daí o `!= 0`.
fn usesLexCtx(src: string): bool { return contains(src, "Lex.") != 0; }

fn lexCtxDecl(): Stmt {
    let noArgs: Expr[] = [];
    return new LetStmt("Lex", "LexCtx", false, new Call("lexCtx", noArgs));
}

fn withLexCtx(body: Stmt[]): Stmt[] {
    let out: Stmt[] = [];
    out.push(lexCtxDecl());
    for (const s of body) { out.push(s); }
    return out;
}

// ── geração de JavaScript para funções client ───────────────────────────────
// Transpila funções marcadas com `client` para JavaScript, permitindo que elas
// rodem no browser. É uma tradução direta: `Terminal.log` → `console.log`, etc.

fn jsBool(b: bool): string {
    if (b) { return "true"; }
    return "false";
}

fn jsCall(c: Call): string {
    // Tradução de funções Lex para JS
    // str(x) → String(x)
    if (strEq(c.name, "str")) { return `String(${jsArgs(c.args)})`; }
    // parseInt, parseFloat já são iguais no JS
    return `${c.name}(${jsArgs(c.args)})`;
}

fn jsExpr(e: Expr): string {
    return match (e) {
        IntLit n => str(n.value),
        FloatLit f => `${f.value}`,
        BoolLit b => jsBool(b.value),
        StrLit s => `"${s.value}"`,
        Var v => v.name,
        Unary u => `(${jsUnaryOp(u.op)}${jsExpr(u.operand)})`,
        Binary bb => `(${jsExpr(bb.lhs)} ${jsBinaryOp(bb.op)} ${jsExpr(bb.rhs)})`,
        Call c => jsCall(c),
        MethodCall m => jsMethodCall(m),
        Field fld => `${jsExpr(fld.base)}.${fld.field}`,
        ArrayLit a => `[${jsArgs(a.items)}]`,
        NewExpr ne => `new ${ne.cls}(${jsArgs(ne.args)})`,
        Index ix => `${jsExpr(ix.base)}[${jsExpr(ix.index)}]`,
        _ => "undefined"
    };
}

fn jsUnaryOp(op: Tok): string {
    if (op == Tok.Bang) { return "!"; }
    if (op == Tok.Minus) { return "-"; }
    if (op == Tok.Tilde) { return "~"; }
    return "";
}

fn jsBinaryOp(op: Tok): string {
    if (op == Tok.Plus) { return "+"; }
    if (op == Tok.Minus) { return "-"; }
    if (op == Tok.Star) { return "*"; }
    if (op == Tok.Slash) { return "/"; }
    if (op == Tok.Percent) { return "%"; }
    if (op == Tok.EqEq) { return "==="; }
    if (op == Tok.Neq) { return "!=="; }
    if (op == Tok.Lt) { return "<"; }
    if (op == Tok.Gt) { return ">"; }
    if (op == Tok.Le) { return "<="; }
    if (op == Tok.Ge) { return ">="; }
    if (op == Tok.AmpAmp) { return "&&"; }
    if (op == Tok.PipePipe) { return "||"; }
    if (op == Tok.Amp) { return "&"; }
    if (op == Tok.Pipe) { return "|"; }
    if (op == Tok.Caret) { return "^"; }
    if (op == Tok.Shl) { return "<<"; }
    if (op == Tok.Shr) { return ">>"; }
    return "";
}

fn jsArgs(xs: Expr[]): string {
    let out: string = "";
    let first: bool = true;
    for (const x of xs) {
        if (!first) { out = concat(out, ", "); }
        out = concat(out, jsExpr(x));
        first = false;
    }
    return out;
}

fn jsMethodCall(m: MethodCall): string {
    // Tradução de métodos Lex para JS
    const base: string = jsExpr(m.base);
    // Terminal.log → console.log
    if (strEq(base, "Terminal") && strEq(m.method, "log")) {
        return `console.log(${jsArgs(m.args)})`;
    }
    // document.querySelector, etc.
    return `${base}.${m.method}(${jsArgs(m.args)})`;
}

fn jsLetKw(mutable: bool): string {
    if (mutable) { return "let"; }
    return "const";
}

fn jsLet(l: LetStmt): string {
    return `${jsLetKw(l.mutable)} ${l.name} = ${jsExpr(l.value)};`;
}

fn jsReturn(r: ReturnStmt): string {
    if (r.hasValue) { return `return ${jsExpr(r.value)};`; }
    return "return;";
}

fn jsForOf(fo: ForOfStmt): string {
    const kw: string = jsLetKw(fo.mutable);
    return `for (${kw} ${fo.name} of ${jsExpr(fo.iter)}) { ${jsBlock(fo.body)} }`;
}

fn jsFor(f: ForStmt): string {
    let init: string = "";
    if (f.hasInit) { init = jsStmt(f.init); }
    let cond: string = "";
    if (f.hasCond) { cond = jsExpr(f.cond); }
    let upd: string = "";
    if (f.hasUpdate) { upd = jsStmt(f.update); }
    // Remove trailing semicolon from update
    if (len(upd) > 0 && peek8(upd, len(upd) - 1) == 59) {
        upd = substring(upd, 0, len(upd) - 1);
    }
    return `for (${init} ${cond}; ${upd}) { ${jsBlock(f.body)} }`;
}

fn jsStmt(s: Stmt): string {
    return match (s) {
        LetStmt l => jsLet(l),
        AssignStmt a => `${jsExpr(a.target)} = ${jsExpr(a.value)};`,
        ReturnStmt r => jsReturn(r),
        IfStmt ii => jsIf(ii),
        WhileStmt w => `while (${jsExpr(w.cond)}) { ${jsBlock(w.body)} }`,
        ForOfStmt fo => jsForOf(fo),
        ForStmt ff => jsFor(ff),
        BreakStmt bb => "break;",
        ContinueStmt cc => "continue;",
        ExprStmt ee => `${jsExpr(ee.expr)};`,
        _ => ""
    };
}

fn jsIf(i: IfStmt): string {
    let out: string = `if (${jsExpr(i.cond)}) { ${jsBlock(i.thenB)} }`;
    if (i.elseB.len() > 0) {
        out = concat(out, ` else { ${jsBlock(i.elseB)} }`);
    }
    return out;
}

fn jsBlock(stmts: Stmt[]): string {
    let out: string = "";
    for (const s of stmts) {
        out = concat(out, concat(jsStmt(s), " "));
    }
    return out;
}

fn jsParams(ps: Param[]): string {
    let out: string = "";
    let first: bool = true;
    for (const p of ps) {
        if (!first) { out = concat(out, ", "); }
        out = concat(out, p.name);
        first = false;
    }
    return out;
}

fn jsFunc(f: Func): string {
    return `function ${f.name}(${jsParams(f.params)}) { ${jsBlock(f.body)} }`;
}

// Gera um método JS (dentro de uma classe)
fn jsMethod(f: Func): string {
    if (strEq(f.name, "constructor")) {
        return `constructor(${jsParams(f.params)}) { ${jsBlock(f.body)} }`;
    }
    return `${f.name}(${jsParams(f.params)}) { ${jsBlock(f.body)} }`;
}

// Gera uma classe JS a partir de ClassDecl
fn jsClass(cd: ClassDecl): string {
    let out: string = `class ${cd.name}`;
    if (len(cd.parent) > 0) {
        out = concat(out, ` extends ${cd.parent}`);
    }
    out = concat(out, " {\n");

    // Campos (em JS, são declarados no constructor)
    // Métodos
    for (const m of cd.methods) {
        out = concat(out, concat("  ", concat(jsMethod(m), "\n")));
    }

    out = concat(out, "}");
    return out;
}

// Gera um bloco <script> com classes e funções client transpiladas para JS
fn genClientScript(funcs: Func[]): string {
    if (funcs.len() == 0) { return ""; }
    let js: string = "";
    for (const f of funcs) {
        js = concat(js, concat(jsFunc(f), "\n"));
    }
    return concat("<script>\n", concat(js, "</script>\n"));
}

// Versão completa que inclui classes
fn genClientScriptFull(classes: ClassDecl[], funcs: Func[]): string {
    if (classes.len() == 0 && funcs.len() == 0) { return ""; }
    let js: string = "";
    for (const cd of classes) {
        js = concat(js, concat(jsClass(cd), "\n"));
    }
    for (const f of funcs) {
        js = concat(js, concat(jsFunc(f), "\n"));
    }
    return concat("<script>\n", concat(js, "</script>\n"));
}

// ── .lsx → Program ──────────────────────────────────────────────────────────
fn parseLsx(path: string, src: string, host: Parser): Program {
    const comp: string = componentName(path);
    const propsTy: string = propsClassName(comp);

    // 1. fatia o frontmatter
    let fm: string = "";
    let bodyAt: i64 = 0;
    const n: i64 = len(src);
    let i: i64 = 0;
    while (i < n) {                                   // pula espaço/linhas iniciais
        const c: i64 = peek8(src, i);
        if (c != 32 && c != 9 && c != 10 && c != 13) { break; }
        i = i + 1;
    }
    if (isDashLine(src, i, n)) {
        const fmStart: i64 = afterLine(src, i, n);
        let fmEnd: i64 = findFmEnd(src, fmStart, n);
        if (fmEnd < 0) {
            host.recordErrAt(i, "lsx: frontmatter aberto com '---' e nunca fechado");
            fmEnd = n;
            bodyAt = n;
        } else {
            bodyAt = afterLine(src, fmEnd, n);
        }
        fm = substring(src, fmStart, fmEnd);
    }

    // 2. o frontmatter é um módulo lex normal
    let fmProg: Program = new Program([], [], [], [], []);
    if (len(fm) > 0) {
        const fp: Parser = new Parser(lexSrc(fm));
        fmProg = fp.parseModule();
        const fmBase: i64 = bodyAt - len(fm) - 4;     // "---\n" antes do corpo
        let ei: i64 = 0;
        while (ei < fp.errs.len()) {
            host.recordErrAt(fmBase + fp.errPos[ei], fp.errs[ei]);
            ei = ei + 1;
        }
    }

    // 3. o corpo → Template.
    //
    // ANTES das props de propósito: é o corpo que diz se há <slot/> (e portanto
    // um campo `children`) e se há <style> (e portanto atributo de escopo). O
    // constructor posicional só pode ser sintetizado depois de saber disso.
    let body: string = substring(src, bodyAt, n);
    while (len(body) > 0 && isSpaceByte(peek8(body, len(body) - 1))) {
        body = substring(body, 0, len(body) - 1);      // apara o \n final do arquivo
    }

    // Coleta classes e funções client ANTES de parsear o corpo, para poder
    // injetar o script gerado no final do corpo.
    let clientClassesPreview: ClassDecl[] = [];
    for (const cd of fmProg.classes) {
        if (cd.isClient) { clientClassesPreview.push(cd); }
    }
    let clientFuncsPreview: Func[] = [];
    for (const f of fmProg.funcs) {
        if (f.isClient) { clientFuncsPreview.push(f); }
    }
    // Se houver classes ou funções client, anexa o script ao corpo
    if (clientClassesPreview.len() > 0 || clientFuncsPreview.len() > 0) {
        body = concat(body, concat("\n", genClientScriptFull(clientClassesPreview, clientFuncsPreview)));
    }

    let attr: string = "";
    if (hasScopedStyle(body)) { attr = concat("data-lsx-", scopeHash(comp)); }
    const ctx: LsxCtx = new LsxCtx(host, attr);
    const tpl: Expr = parseLsxBody(body, bodyAt, ctx);

    // 4. a classe de props: renomeia `Props` → `<Nome>Props`, injeta `children`
    // se o corpo usou <slot/>, e só então sintetiza o constructor.
    // Classes marcadas como `client` não são incluídas no servidor.
    let classes: ClassDecl[] = [];
    let hasProps: bool = false;
    for (const cd of fmProg.classes) {
        if (cd.isClient) { continue; }   // pula classes client (vão para o JS)
        if (strEq(cd.name, "Props")) {
            cd.name = propsTy;
            if (ctx.usedSlot) { addChildrenField(cd); }
            synthPropsCtor(cd);
            hasProps = true;
        }
        classes.push(cd);
    }
    if (!hasProps) {
        let noFields: ClassField[] = [];
        let noMethods: Func[] = [];
        const empty: ClassDecl = new ClassDecl(propsTy, "", noFields, noMethods);
        if (ctx.usedSlot) { addChildrenField(empty); }
        synthPropsCtor(empty);
        classes.push(empty);
    }

    // 5. a função de render: stmts do frontmatter + `return <template>`
    const usaLex: bool = usesLexCtx(src);
    let rbody: Stmt[] = [];
    if (usaLex) { rbody.push(lexCtxDecl()); }
    for (const s of fmProg.main) { rbody.push(s); }
    rbody.push(new ReturnStmt(true, tpl));
    let rps: Param[] = [];
    rps.push(new Param("props", propsTy));
    // devolve `Html`, não `string`: é isso que faz `<Card/>` e `{Card(...)}`
    // comporem sem escape duplo, enquanto um `string` qualquer escapa.
    const render: Func = new Func(comp, rps, "Html", false, rbody);

    // 6. as funções do frontmatter. Um `fn hydrate(root: i64)` é a metade
    // CLIENTE do componente: renomeada p/ `<Nome>_hydrate`, ela sai exportada
    // no módulo wasm (o wasm-ld usa --export-all) e é o que o host chama ao
    // encontrar a <lsx-island> correspondente no HTML.
    //
    // `fn get()` / `fn post()` são a metade ENDPOINT da página: renomeadas p/
    // `<Nome>_get` / `<Nome>_post`, do mesmo jeito e pelo mesmo motivo que o
    // hydrate. O espaço de nomes do lex é plano, então dois arquivos com um
    // `fn get` dariam duas `@get` na IR e o clang recusaria por símbolo
    // duplicado — a mesma armadilha que `noteComponent` já cobre p/ o render.
    //
    // `client function` — função que roda no browser (compila p/ WASM). O nome
    // é prefixado com o componente para evitar colisões, e a função é separada
    // para ser compilada em um módulo WASM à parte.
    let funcs: Func[] = [];
    let clientFuncs: Func[] = [];
    for (const f of fmProg.funcs) {
        if (strEq(f.name, "hydrate")) { f.name = concat(comp, "_hydrate"); }
        else if (strEq(f.name, "get")) { f.name = concat(comp, "_get"); }
        else if (strEq(f.name, "post")) { f.name = concat(comp, "_post"); }

        if (f.isClient) {
            // Funções client recebem prefixo do componente e vão para lista separada
            f.name = concat(concat(comp, "_"), f.name);
            clientFuncs.push(f);
        } else {
            if (usaLex) { f.body = withLexCtx(f.body); }
            funcs.push(f);
        }
    }
    funcs.push(render);

    // 7. o import de std/web, quando o arquivo usa `Lex.`. O loader resolve os
    // imports do Program que voltamos daqui, então declará-lo aqui basta — a
    // página não escreve import nenhum, que é o ponto: o contexto é NATIVO do
    // formato, não uma biblioteca que se lembra de importar.
    let imports: Import[] = [];
    for (const im of fmProg.imports) { imports.push(im); }
    if (usaLex) {
        let usados: string[] = [];
        usados.push("LexCtx");
        usados.push("lexCtx");
        imports.push(new Import(usados, "web"));
    }

    const out: Program = new Program(imports, fmProg.enums, classes, funcs, []);
    out.externs = fmProg.externs;
    out.clientFuncs = clientFuncs;
    return out;
}
