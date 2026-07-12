// lexi.lex — o INTERPRETADOR do lex como ferramenta de CLI. Roda um .lex
// executando a AST direto, SEM clang e SEM LLVM.
//
//   lexi <arquivo.lex>      # executa; exit code = retorno do main
import { interpret } from "./interp"

const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lexi <arquivo.lex>");
    return 1;
}
const src: string = readFile(av[1]);
if (len(src) == 0) {
    Terminal.log(`erro: nao consegui ler '${av[1]}'`);
    return 1;
}
return interpret(src);
