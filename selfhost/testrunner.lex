// testrunner.lex — núcleo do runner de testes (MÓDULO, só declarações).
// Mescla o harness std/test.lex + o arquivo de teste num Program, anexa
// `return testReport()` ao main, compila e roda; devolve o exit code (placar).
import { ModuleLoader, findStd, findRuntime } from "./modloader"
import { compileProgramToIR } from "./codegen"
import { Expr, Program, ReturnStmt, Call } from "./parser"

fn runTestFile(entry: string): i64 {
    const ml: ModuleLoader = new ModuleLoader();
    ml.load(findStd("test.lex"));     // harness (acha o std/ subindo diretórios)
    ml.load(entry);                   // o arquivo de teste + seus imports relativos
    const prog: Program = ml.toProgram();
    let noArgs: Expr[] = [];
    prog.main.push(new ReturnStmt(true, new Call("testReport", noArgs)));

    const bin: string = "/tmp/lextest_bin";
    const ll: string = "/tmp/lextest_bin.ll";
    writeFile(ll, compileProgramToIR(prog));
    const rc: i64 = system(`clang -Wno-override-module -o ${bin} ${ll} ${findRuntime()} -lpthread`);
    if (rc != 0) { return -1; }
    return system(bin) / 256;         // WEXITSTATUS (placar do harness)
}
