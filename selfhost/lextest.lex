// lextest.lex — runner de testes em lex (Fase C), espelha `lex test`.
//
//   lextest <arquivo.test.lex>...
//
// Para cada arquivo: mescla o harness `std/test.lex` (describe/test/expect/
// testReport) + o arquivo (e seus imports) num Program só, anexa um
// `return testReport()` ao main (os `describe(...)` de topo viram o corpo do
// main), compila p/ binário nativo e roda. O exit code do binário = placar do
// harness (0 = tudo passou). Soma as falhas no fim.
import { ModuleLoader } from "./modloader"
import { compileProgramToIR } from "./codegen"
import { Expr, Program, ReturnStmt, Call } from "./parser"

// arquivo de teste -> exit code do binário (placar), ou -1 se o clang falhar.
fn runTestFile(entry: string): i64 {
    const ml: ModuleLoader = new ModuleLoader();
    ml.load("std/test.lex");          // o harness (describe/test/expect/testReport/Expect)
    ml.load(entry);                   // o arquivo de teste + seus imports relativos
    const prog: Program = ml.toProgram();
    // os describe(...) de topo já estão em prog.main; fecha com return testReport()
    let noArgs: Expr[] = [];
    prog.main.push(new ReturnStmt(true, new Call("testReport", noArgs)));

    const bin: string = "/tmp/lextest_bin";
    const ll: string = "/tmp/lextest_bin.ll";
    writeFile(ll, compileProgramToIR(prog));
    const rc: i64 = system(`clang -Wno-override-module -o ${bin} ${ll} src/runtime.c -lpthread`);
    if (rc != 0) { return -1; }
    return system(bin) / 256;         // WEXITSTATUS
}

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
