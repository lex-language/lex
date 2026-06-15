// lexpkg.lex — driver do gerenciador de pacotes (Fase F6.8-C). A lógica está em
// pkgcmd.lex; aqui é só o ponto de entrada.
//
//   lexpkg init [nome] | add <spec> | remove <nome> | list
import { runPkg } from "./pkgcmd"

const av: string[] = args();
return runPkg(av, 1);
