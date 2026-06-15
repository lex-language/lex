// lextest.lex — driver do runner de testes (Fase C). A lógica está em
// testrunner.lex; aqui é só o dispatch.
//
//   lextest <arquivo.test.lex>...
import { runTestFile } from "./testrunner"

const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lextest <arquivo.test.lex>...");
    return 1;
}
let failed: i64 = 0;
let i: i64 = 1;
while (i < av.len()) {
    const f: string = av[i];
    Terminal.log(concat("── ", f));
    const code: i64 = runTestFile(f);
    if (code < 0) { Terminal.log("  ✖ falha ao compilar"); failed = failed + 1; }
    else if (code != 0) { Terminal.log("  ✖ testes falharam"); failed = failed + 1; }
    i = i + 1;
}
if (failed == 0) { Terminal.log("✓ tudo passou"); }
return failed;
