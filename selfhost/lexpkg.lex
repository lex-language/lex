// lexpkg.lex — driver do gerenciador de pacotes (Fase F6.8-C), espelha `lex`
// (subcomandos de pacote). Por ora cobre as operações de MANIFESTO (sem rede):
//   lexpkg init [nome]      cria lex.toml
//   lexpkg add <spec>       adiciona dep ao lex.toml (fetch via git ainda TODO)
//   lexpkg remove <nome>    tira a dep do lex.toml
//   lexpkg list             lista pacote + dependências
import { newManifest, addDep, removeDep, parseDep } from "./pkg"
import { parseToml } from "./toml"

const av: string[] = args();
if (av.len() < 2) {
    Terminal.log("uso: lexpkg <init|add|remove|list> ...");
    return 1;
}
const cmd: string = av[1];

if (strEq(cmd, "init")) {
    let name: string = "app";
    if (av.len() >= 3) { name = av[2]; }
    writeFile("lex.toml", newManifest(name));
    Terminal.log(`criado lex.toml (${name} 0.1.0)`);
    return 0;
}

if (strEq(cmd, "add")) {
    if (av.len() < 3) { Terminal.log("uso: lexpkg add <spec>"); return 1; }
    const dep = parseDep("", av[2]);
    writeFile("lex.toml", addDep(readFile("lex.toml"), dep.name, dep.canonical));
    Terminal.log(`add ${dep.name} = ${dep.canonical}  (manifesto; fetch via git é TODO)`);
    return 0;
}

if (strEq(cmd, "remove")) {
    if (av.len() < 3) { Terminal.log("uso: lexpkg remove <nome>"); return 1; }
    writeFile("lex.toml", removeDep(readFile("lex.toml"), av[2]));
    Terminal.log(`removido ${av[2]}`);
    return 0;
}

if (strEq(cmd, "list")) {
    const doc = parseToml(readFile("lex.toml"));
    const pkg = doc.table("package");
    Terminal.log(`${pkg.getStr("name")} ${pkg.getStr("version")}`);
    for (const p of doc.table("dependencies").pairs) {
        Terminal.log(`  ${p.key} = ${p.value.str}`);
    }
    return 0;
}

Terminal.log(`lexpkg: comando desconhecido '${cmd}'`);
return 1;
