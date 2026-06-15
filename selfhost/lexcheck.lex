// lexcheck.lex — driver do `lex check --json` self-hostado (Fase E, slice). A
// lógica está em checker.lex; aqui é só o dispatch.
//
//   lexcheck [--json] <arquivo.lex>
//
// Detecta variável indefinida (o caso do smoke do LSP). Sai 1 se houver diagnóstico.
import { runCheck } from "./checker"

const av: string[] = args();
let path: string = "";
let i: i64 = 1;
while (i < av.len()) {
    if (strEq(av[i], "--json")) { i = i + 1; }     // sempre JSON; ignora a flag
    else { path = av[i]; i = i + 1; }
}
if (strEq(path, "")) {
    Terminal.log("uso: lexcheck [--json] <arquivo.lex>");
    return 1;
}
return runCheck(path);
