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
    // `system` devolve o WAIT STATUS, não o exit code. Morte por SINAL fica nos 7
    // bits baixos — e como `status / 256` dava 0 pra um SIGSEGV(11), um binário de
    // teste que CRASHAVA era reportado como sucesso. Detectamos o sinal primeiro.
    const st: i64 = system(bin);
    const sig: i64 = st & 127;
    if (sig != 0) {
        Terminal.log(`erro: o binário de teste morreu com o sinal ${sig}`);
        return 1;
    }
    return st / 256;                  // WEXITSTATUS (placar do harness)
}
