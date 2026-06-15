// Demo: o lexer-em-lex tokenizando um arquivo .lex real do disco.
//   ./target/debug/lex selfhost/lex_dump.lex --run
import { lexSrc, Token, Tok } from "./lexer"

const path: string = "examples/exemplo.lex";
const src: string = readFile(path);
const toks: Token[] = lexSrc(src);

let idents: i64 = 0;
let kw: i64 = 0;
let nums: i64 = 0;
let strs: i64 = 0;
let tmpls: i64 = 0;
for (const t of toks) {
    if (t.kind == Tok.Ident) { idents = idents + 1; }
    if (t.kind == Tok.Int || t.kind == Tok.Float) { nums = nums + 1; }
    if (t.kind == Tok.Str) { strs = strs + 1; }
    if (t.kind == Tok.Template) { tmpls = tmpls + 1; }
    // palavra-chave = não-Ident, não-literal, não-pontuação; aproximação:
    if (t.kind <= Tok.Await) { kw = kw + 1; }
}

Terminal.log(`arquivo:  ${path}`);
Terminal.log(`bytes:    ${len(src)}`);
Terminal.log(`tokens:   ${toks.len()}`);
Terminal.log(`keywords: ${kw}`);
Terminal.log(`idents:   ${idents}`);
Terminal.log(`números:  ${nums}`);
Terminal.log(`strings:  ${strs}`);
Terminal.log(`templates:${tmpls}`);
