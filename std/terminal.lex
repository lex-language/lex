// std/terminal.lex — logs coloridos no terminal, em lex.
//
// `Terminal` é GLOBAL: faz parte da prelude da linguagem, então está disponível
// em qualquer arquivo .lex sem precisar de `import`. Tudo é `static`: não
// instancia, é só chamar de qualquer lugar, como um logger global:
//
//   function main(): i32 {
//       Terminal.info("servidor subindo");
//       Terminal.log("conexões ativas", 2);          // imprime: conexões ativas 2
//       Terminal.warn("memória alta", 87, "%");       // imprime: memória alta 87 %
//       Terminal.error("falha no código", 500, true); // imprime: falha no código 500 true
//       return 0;
//   }
//
// Cada nível tem cor e rótulo. log/info/success/debug saem no stdout (fd 1);
// warn/error saem no stderr (fd 2) — assim dá pra redirecionar erros à parte.
//
// Estilo `console.log`: todo método aceita um número QUALQUER de argumentos de
// QUALQUER tipo (`...values: any[]`) e os concatena, separados por espaço. Cada
// valor é convertido para texto pelo seu tipo (string como está, número em
// decimal, bool como true/false) via `jsonAsStr` — o `any` é a mesma caixa
// marcada do `json`, então isso sai de graça.
//
// As cores são sequências ANSI. O byte ESC (0x1b) é montado em runtime com
// `alloc`/`poke8`, pois o lexer não tem o escape \x1b.

import { write, strlen } from "libc";

class Terminal {
    // ESC (27 = 0x1b) como string de 1 caractere — base das sequências ANSI
    private static esc(): string {
        const e: ptr = alloc(2);
        poke8(e, 0, 27);
        return e;
    }

    // escreve `s` seguida de \n no descritor fd (1 = stdout, 2 = stderr)
    private static emit(fd: i64, s: string) {
        const out: string = concat(s, "\n");
        write(fd, out, strlen(out));
    }

    // junta todos os valores num texto só, separados por espaço. Cada `any` é
    // convertido pelo seu tipo (string/num/bool) com jsonAsStr.
    private static joinAll(values: any[]): string {
        let out: string = "";
        let i: i64 = 0;
        while (i < len(values)) {
            if (i > 0) {
                out = concat(out, " ");
            }
            out = concat(out, jsonAsStr(values[i]));
            i = i + 1;
        }
        return out;
    }

    // "<cor><rótulo><reset> <corpo>"
    private static tagged(color: string, label: string, body: string): string {
        const e: string = Terminal.esc();
        return `${e}${color}${label}${e}[0m ${body}`;
    }

    // mensagem neutra (sem cor nem rótulo) → stdout
    static log(...values: any[]) {
        Terminal.emit(1, Terminal.joinAll(values));
    }

    // informação (ciano) → stdout
    static info(...values: any[]) {
        Terminal.emit(1, Terminal.tagged("[36m", "[info]", Terminal.joinAll(values)));
    }

    // sucesso (verde) → stdout
    static success(...values: any[]) {
        Terminal.emit(1, Terminal.tagged("[32m", "[ ok ]", Terminal.joinAll(values)));
    }

    // depuração (cinza) → stdout
    static debug(...values: any[]) {
        Terminal.emit(1, Terminal.tagged("[90m", "[debug]", Terminal.joinAll(values)));
    }

    // aviso (amarelo) → stderr
    static warn(...values: any[]) {
        Terminal.emit(2, Terminal.tagged("[33m", "[warn]", Terminal.joinAll(values)));
    }

    // erro (vermelho) → stderr
    static error(...values: any[]) {
        Terminal.emit(2, Terminal.tagged("[31m", "[error]", Terminal.joinAll(values)));
    }
}
