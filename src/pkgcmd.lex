// pkgcmd.lex — despacho dos comandos de pacote (MÓDULO, só declarações).
// `runPkg(av, base)`: av[base] é o subcomando (init/add/remove/list). O driver é
// Chamado por `lex pkg ...` (base=2). Só manifesto (sem rede).
import { newManifest, addDep, removeDep, parseDep, DepSpec } from "./pkg"
import { parseToml, serializeToml, TomlDoc, TomlSection } from "./toml"
import { semverPickBest } from "./semver"

// ── rede via git (captura saída por arquivo temporário) ──────────────────────
fn pkgTrim(s: string): string {
    const n: i64 = len(s);
    let a: i64 = 0;
    while (a < n && (peek8(s, a) == 32 || peek8(s, a) == 9 || peek8(s, a) == 13 || peek8(s, a) == 10)) { a = a + 1; }
    let b: i64 = n;
    while (b > a && (peek8(s, b - 1) == 32 || peek8(s, b - 1) == 9 || peek8(s, b - 1) == 13 || peek8(s, b - 1) == 10)) { b = b - 1; }
    return substring(s, a, b);
}
fn captureCmd(cmd: string): string {
    system(`${cmd} > /tmp/lex_pkg_cap 2>/dev/null`);
    return readFile("/tmp/lex_pkg_cap");
}
fn indexOfSub(hay: string, needle: string): i64 {
    const hn: i64 = len(hay);
    const nn: i64 = len(needle);
    let i: i64 = 0;
    while (i + nn <= hn) {
        if (strEq(substring(hay, i, i + nn), needle)) { return i; }
        i = i + 1;
    }
    return -1;
}
// tags de `git ls-remote --tags --refs <url>` (linhas "<sha>\trefs/tags/<tag>").
fn gitTags(url: string): string[] {
    const raw: string = captureCmd(`git ls-remote --tags --refs ${url}`);
    let tags: string[] = [];
    const marker: string = "refs/tags/";
    const n: i64 = len(raw);
    let start: i64 = 0;
    let i: i64 = 0;
    while (i <= n) {
        if (i == n || peek8(raw, i) == 10) {
            const line: string = substring(raw, start, i);
            const idx: i64 = indexOfSub(line, marker);
            if (idx >= 0) { tags.push(substring(line, idx + len(marker), len(line))); }
            start = i + 1;
        }
        i = i + 1;
    }
    return tags;
}

// grava/atualiza a entrada [[package]] no lex.lock.
fn writeLock(name: string, version: string, url: string, commit: string) {
    const doc: TomlDoc = parseToml(readFile("lex.lock"));
    let sec: TomlSection = doc.addArrayTable("package");
    let found: bool = false;
    for (const s of doc.arrayTables("package")) {
        if (strEq(s.getStr("name"), name)) { sec = s; found = true; }
    }
    if (found) {
        // já existe: tira a duplicada recém-criada (a última)
        doc.sections.pop();
    }
    sec.setStr("name", name);
    sec.setStr("version", version);
    sec.setStr("source", "git");
    sec.setStr("resolved", url);
    sec.setStr("commit", commit);
    writeFile("lex.lock", serializeToml(doc));
}

// clona o repo git em lex_modules/<name>, escolhe a tag por semver, grava o lock.
// Devolve 0 se ok.
fn pkgFetchGit(name: string, url: string, reqOrRef: string): i64 {
    const dest: string = concat("lex_modules/", name);
    system(`rm -rf ${dest}`);
    let branchArg: string = "";
    let version: string = "0.0.0";
    if (!strEq(reqOrRef, "") && !strEq(reqOrRef, "*")) {
        const best: string = semverPickBest(reqOrRef, gitTags(url));
        if (!strEq(best, "")) { branchArg = concat("--branch ", best); version = best; }
        else { branchArg = concat("--branch ", reqOrRef); version = reqOrRef; }
    }
    const rc: i64 = system(`git clone --depth 1 ${branchArg} ${url} ${dest} > /dev/null 2>&1`);
    if (rc != 0) { Terminal.log(`erro: git clone falhou (${url})`); return 1; }
    const commit: string = pkgTrim(captureCmd(`git -C ${dest} rev-parse HEAD`));
    system(`rm -rf ${dest}/.git`);
    writeLock(name, version, url, commit);
    Terminal.log(`fetch ${name} @ ${version} (${commit})`);
    return 0;
}

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
        Terminal.log(`add ${dep.name} = ${dep.canonical}`);
        if (strEq(dep.kind, "git")) { return pkgFetchGit(dep.name, dep.url, dep.reqOrRef); }
        return 0;
    }
    if (strEq(cmd, "install")) {
        const doc = parseToml(readFile("lex.toml"));
        for (const p of doc.table("dependencies").pairs) {
            const dep = parseDep(p.key, p.value.str);
            if (strEq(dep.kind, "git")) { pkgFetchGit(dep.name, dep.url, dep.reqOrRef); }
        }
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
