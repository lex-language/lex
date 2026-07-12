// lexfmt.lex — driver do formatador (Fase F6.7), espelha o subcomando `lex fmt`.
//
//   lexfmt <arquivo.lex>...        reescreve cada arquivo formatado (in-place)
//   lexfmt --check <arquivo>...    só confere; sai 1 se algo mudaria
//
// Sai 2 em erro de I/O; 0 caso ok.
import { formatSource } from "./fmt"

fn hasSuffix(s: string, suf: string): bool {
    const sl: i64 = len(s);
    const fl: i64 = len(suf);
    if (fl > sl) { return false; }
    return strEq(substring(s, sl - fl, sl), suf);
}

const av: string[] = args();
let check: bool = false;
let files: string[] = [];
let i: i64 = 1;                             // av[0] = nome do programa
while (i < av.len()) {
    const a: string = av[i];
    if (strEq(a, "--check")) { check = true; }
    else { files.push(a); }
    i = i + 1;
}
if (files.len() == 0) {
    Terminal.log("uso: lexfmt [--check] <arquivo.lex>...");
    return 1;
}

let changed: i64 = 0;
for (const f of files) {
    if (!hasSuffix(f, ".lex")) {
        Terminal.log(`lexfmt: pulando '${f}' (não é .lex)`);
    } else {
        const src: string = readFile(f);
        const formatted: string = formatSource(src);
        if (!strEq(formatted, src)) {
            changed = changed + 1;
            if (check) {
                Terminal.log(`would reformat ${f}`);
            } else {
                writeFile(f, formatted);
                Terminal.log(`formatted ${f}`);
            }
        }
    }
}

if (check && changed > 0) { return 1; }
return 0;
