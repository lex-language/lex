// lexc.lex — o compilador do lex, escrito EM lex (driver self-hosted).
//
//   lexc <entrada.lex> [saida]
//
// Pipeline: lê o fonte → lexer → parser → codegen (LLVM IR textual) → escreve
// um .ll → chama o clang pra montar+linkar o executável nativo. Tudo dirigido
// pelo próprio lex (args/system/readFile/writeFile são builtins de host).
//
// Subset suportado: ver selfhost/codegen.lex. Compila programas com funções
// i64, if/while, aritmética/comparações e chamadas; `main(): i32` vira o
// exit code.
import { compileToIR } from "./codegen"

const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lexc <entrada.lex> [saida]");
    return 1;
}

const path: string = av[1];
let outBin: string = "a.out";
if (av.len() >= 3) { outBin = av[2]; }

const src: string = readFile(path);
if (len(src) == 0) {
    Terminal.log(`erro: nao consegui ler '${path}'`);
    return 1;
}

const ir: string = compileToIR(src);
const llPath: string = concat(outBin, ".ll");
writeFile(llPath, ir);

const cmd: string = `clang -Wno-override-module -o ${outBin} ${llPath}`;
const rc: i64 = system(cmd);
if (rc != 0) {
    Terminal.log(`erro: clang falhou (rc=${rc})`);
    return 1;
}

Terminal.log(`ok: ${path} -> ${outBin}`);
