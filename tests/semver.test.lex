// Testes do semver-em-lex (F6.8-B). Rode com:  lex test selfhost
import { semverCmp, semverMatches, semverPickBest } from "../selfhost/semver"

describe("semver: comparação", () => {
        test("cmp", () => {
                expect(semverCmp("1.2.3", "1.2.3")).toBe(0);
                expect(semverCmp("1.2.3", "1.3.0")).toBe(-1);
                expect(semverCmp("2.0.0", "1.9.9")).toBe(1);
                expect(semverCmp("v1.0.0", "1.0.0")).toBe(0);     // 'v' opcional
                expect(semverCmp("1.2", "1.2.0")).toBe(0);        // partes ausentes = 0
        });
});

describe("semver: requisitos", () => {
        test("caret ^", () => {
                expect(semverMatches("^1.2.0", "1.2.0")).toBe(true);
                expect(semverMatches("^1.2.0", "1.9.9")).toBe(true);
                expect(semverMatches("^1.2.0", "2.0.0")).toBe(false);
                expect(semverMatches("^1.2.0", "1.1.0")).toBe(false);
                expect(semverMatches("^0.2.3", "0.2.9")).toBe(true);   // major 0: trava no minor
                expect(semverMatches("^0.2.3", "0.3.0")).toBe(false);
        });

        test("tilde ~", () => {
                expect(semverMatches("~1.2.0", "1.2.9")).toBe(true);
                expect(semverMatches("~1.2.0", "1.3.0")).toBe(false);
        });

        test("comparadores e *", () => {
                expect(semverMatches(">=1.0.0", "2.5.0")).toBe(true);
                expect(semverMatches(">=1.0.0", "0.9.0")).toBe(false);
                expect(semverMatches("<2.0.0", "1.9.0")).toBe(true);
                expect(semverMatches("=1.2.3", "1.2.3")).toBe(true);
                expect(semverMatches("*", "9.9.9")).toBe(true);
                expect(semverMatches("1.2.0", "1.5.0")).toBe(true);    // bare = caret
                expect(semverMatches("1.2.0", "2.0.0")).toBe(false);
        });
});

describe("semver: escolher a maior que casa", () => {
        test("pickBest", () => {
                const vs: string[] = ["1.0.0", "1.2.0", "1.5.0", "2.0.0", "0.9.0"];
                expect(semverPickBest("^1.0.0", vs)).toBe("1.5.0");
                expect(semverPickBest(">=2.0.0", vs)).toBe("2.0.0");
                expect(semverPickBest("^3.0.0", vs)).toBe("");          // nenhuma casa
        });
});
