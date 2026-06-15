// pkgcmd.lex — despacho dos comandos de pacote (MÓDULO, só declarações).
// `runPkg(av, base)`: av[base] é o subcomando (init/add/remove/list). O driver é
// lexpkg.lex (base=1) ou `lex pkg ...` no lexcli (base=2). Só manifesto (sem rede).
import { newManifest, addDep, removeDep, parseDep } from "./pkg"
import { parseToml } from "./toml"

fn runPkg(av: string[], base: i64): i64 {
    if (av.len() <= base) {
        Terminal.log("uso: pkg <init|add|remove|list> ...");
        return 1;
    }
    const cmd: string = av[base];

    if (strEq(cmd, "init")) {
        let name: string = "app";
        if (av.len() > base + 1) { name = av[base + 1]; }
        writeFile("lex.toml", newManifest(name));
        Terminal.log(`criado lex.toml (${name} 0.1.0)`);
        return 0;
    }
    if (strEq(cmd, "add")) {
        if (av.len() <= base + 1) { Terminal.log("uso: pkg add <spec>"); return 1; }
        const dep = parseDep("", av[base + 1]);
        writeFile("lex.toml", addDep(readFile("lex.toml"), dep.name, dep.canonical));
        Terminal.log(`add ${dep.name} = ${dep.canonical}  (manifesto; fetch via git é TODO)`);
        return 0;
    }
    if (strEq(cmd, "remove")) {
        if (av.len() <= base + 1) { Terminal.log("uso: pkg remove <nome>"); return 1; }
        writeFile("lex.toml", removeDep(readFile("lex.toml"), av[base + 1]));
        Terminal.log(`removido ${av[base + 1]}`);
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
    Terminal.log(`pkg: comando desconhecido '${cmd}'`);
    return 1;
}
