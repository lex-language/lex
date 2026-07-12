// Testes do núcleo do pkg manager (F6.8-C). Rode com:  lex test tests/
import { parseDep, normalizeGitUrl, newManifest, addDep, removeDep } from "../tools/pkg"
import { parseToml } from "../tools/toml"

describe("pkg: parse de spec de dependência", () => {
        test("registry (nome@req)", () => {
                expect(parseDep("", "cores@^1.2.0").name).toBe("cores");
                expect(parseDep("", "cores@^1.2.0").kind).toBe("registry");
                expect(parseDep("", "cores@^1.2.0").reqOrRef).toBe("^1.2.0");
                expect(parseDep("", "cores").reqOrRef).toBe("*");          // default
        });

        test("git direto (com e sem ref)", () => {
                expect(parseDep("", "github.com/u/repo").kind).toBe("git");
                expect(parseDep("", "github.com/u/repo").url).toBe("https://github.com/u/repo");
                expect(parseDep("", "github.com/u/repo").name).toBe("repo");
                expect(parseDep("", "github.com/u/repo@^1.0").reqOrRef).toBe("^1.0");
                expect(parseDep("", "github.com/u/repo@^1.0").url).toBe("https://github.com/u/repo");
        });

        test("git scp-like (git@host:...)", () => {
                expect(parseDep("", "git@github.com:u/repo.git").kind).toBe("git");
                expect(parseDep("", "git@github.com:u/repo.git").name).toBe("repo");
                expect(parseDep("", "git@github.com:u/repo.git").url).toBe("git@github.com:u/repo.git");
        });

        test("file: (local)", () => {
                expect(parseDep("", "file:../mylib").kind).toBe("file");
                expect(parseDep("", "file:../mylib").url).toBe("../mylib");
                expect(parseDep("", "file:../mylib").name).toBe("mylib");
        });

        test("dica de nome tem prioridade", () => {
                expect(parseDep("apelido", "cores").name).toBe("apelido");
        });
});

describe("pkg: normalização de URL", () => {
        test("prefixa https quando falta esquema", () => {
                expect(normalizeGitUrl("github.com/u/r")).toBe("https://github.com/u/r");
                expect(normalizeGitUrl("https://x/y")).toBe("https://x/y");
                expect(normalizeGitUrl("git@h:u/r")).toBe("git@h:u/r");
                expect(normalizeGitUrl("/abs/path")).toBe("/abs/path");
        });
});

describe("pkg: manifesto (lex.toml)", () => {
        test("newManifest", () => {
                const doc = parseToml(newManifest("foo"));
                expect(doc.table("package").getStr("name")).toBe("foo");
                expect(doc.table("package").getStr("version")).toBe("0.1.0");
        });

        test("addDep adiciona em [dependencies]", () => {
                const m = addDep(newManifest("foo"), "cores", "^1.2.0");
                expect(parseToml(m).table("dependencies").getStr("cores")).toBe("^1.2.0");
        });

        test("removeDep tira a dependência", () => {
                let m = addDep(newManifest("foo"), "cores", "^1.2.0");
                m = addDep(m, "http", "github.com/u/http");
                m = removeDep(m, "cores");
                const deps = parseToml(m).table("dependencies");
                expect(deps.has("cores")).toBe(false);
                expect(deps.getStr("http")).toBe("github.com/u/http");
        });
});
