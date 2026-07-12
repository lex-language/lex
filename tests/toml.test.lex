// Testes do TOML-em-lex (F6.8-A). Rode com:  lex test tests/
import { parseToml, serializeToml } from "../src/toml"

const MANIFEST: string = "[package]\nname = \"myapp\"\nversion = \"0.2.0\"\nmain = \"src/index.lex\"\n\n[dependencies]\ncores = \"^1.2.0\"\nhttp = \"github.com/lex/http\"\n";

const LOCKFILE: string = "[[package]]\nname = \"cores\"\nversion = \"1.2.3\"\nsource = \"registry\"\ncommit = \"abc123\"\ndependencies = [\"base\", \"util\"]\n\n[[package]]\nname = \"base\"\nversion = \"0.1.0\"\nsource = \"git\"\ncommit = \"def\"\ndependencies = []\n";

describe("toml: manifesto (lex.toml)", () => {
        test("tabela [package]", () => {
                const doc = parseToml(MANIFEST);
                expect(doc.table("package").getStr("name")).toBe("myapp");
                expect(doc.table("package").getStr("version")).toBe("0.2.0");
                expect(doc.table("package").getStr("main")).toBe("src/index.lex");
                expect(doc.table("package").has("description")).toBe(false);
        });

        test("tabela [dependencies]", () => {
                const doc = parseToml(MANIFEST);
                expect(doc.table("dependencies").getStr("cores")).toBe("^1.2.0");
                expect(doc.table("dependencies").getStr("http")).toBe("github.com/lex/http");
        });
});

describe("toml: lockfile (array-de-tabelas + listas)", () => {
        test("[[package]] múltiplos", () => {
                const doc = parseToml(LOCKFILE);
                const pkgs = doc.arrayTables("package");
                expect(pkgs.len()).toBe(2);
                expect(pkgs[0].getStr("name")).toBe("cores");
                expect(pkgs[0].getStr("commit")).toBe("abc123");
                expect(pkgs[1].getStr("source")).toBe("git");
        });

        test("lista de dependências", () => {
                const doc = parseToml(LOCKFILE);
                const pkgs = doc.arrayTables("package");
                const deps0 = pkgs[0].getList("dependencies");
                expect(deps0.len()).toBe(2);
                expect(deps0[0]).toBe("base");
                expect(deps0[1]).toBe("util");
                expect(pkgs[1].getList("dependencies").len()).toBe(0);
        });
});

describe("toml: round-trip", () => {
        test("parse -> serialize -> parse preserva valores", () => {
                const out = serializeToml(parseToml(MANIFEST));
                const doc2 = parseToml(out);
                expect(doc2.table("package").getStr("name")).toBe("myapp");
                expect(doc2.table("dependencies").getStr("cores")).toBe("^1.2.0");
        });
});
