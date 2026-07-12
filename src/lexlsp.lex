// lexlsp.lex — driver do Language Server (Fase F6.9). A lógica está em
// lspserver.lex; aqui é só o ponto de entrada.
//
//   lexlsp        (fala LSP por stdio)
import { runLsp } from "./lspserver"

return runLsp();
