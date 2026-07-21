// tool.test.lex — Testes para a sintaxe `tool function`
//
// Verifica que o parser reconhece e trata corretamente funções marcadas
// com o keyword `tool`.

import { lexSrc, Token, Tok } from "../compiler/lexer"
import { Parser, Func, parseModuleStr } from "../compiler/parser"

// ══════════════════════════════════════════════════════════════════════════════
// TESTES DE LEXER
// ══════════════════════════════════════════════════════════════════════════════

fn testToolKeyword() {
    Terminal.log("Testing 'tool' keyword lexing...")

    const src: string = "tool function"
    const toks: Token[] = lexSrc(src)

    // Deve ter: Tool, Function, Eof
    if (toks.len() < 2) {
        Terminal.log("FAIL: Expected at least 2 tokens")
        return
    }

    if (toks[0].kind != Tok.Tool) {
        Terminal.log("FAIL: First token should be Tok.Tool")
        return
    }

    if (toks[1].kind != Tok.Function) {
        Terminal.log("FAIL: Second token should be Tok.Function")
        return
    }

    Terminal.log("PASS: 'tool' keyword lexed correctly")
}

// ══════════════════════════════════════════════════════════════════════════════
// TESTES DE PARSER
// ══════════════════════════════════════════════════════════════════════════════

fn testToolFunctionParsing() {
    Terminal.log("Testing 'tool function' parsing...")

    const src: string = `
tool function add(a: i64, b: i64): i64 {
    return a + b
}
`
    const p: Parser = new Parser(lexSrc(src))
    const prog: Program = p.parseModule()

    if (prog.funcs.len() == 0) {
        Terminal.log("FAIL: No functions parsed")
        return
    }

    const f: Func = prog.funcs[0]

    if (!strEq(f.name, "add")) {
        Terminal.log(`FAIL: Expected function name 'add', got '${f.name}'`)
        return
    }

    if (!f.isTool) {
        Terminal.log("FAIL: Function should be marked as tool")
        return
    }

    Terminal.log("PASS: 'tool function' parsed correctly")
}

fn testRegularFunctionNotTool() {
    Terminal.log("Testing regular function is not marked as tool...")

    const src: string = `
function multiply(a: i64, b: i64): i64 {
    return a * b
}
`
    const p: Parser = new Parser(lexSrc(src))
    const prog: Program = p.parseModule()

    if (prog.funcs.len() == 0) {
        Terminal.log("FAIL: No functions parsed")
        return
    }

    const f: Func = prog.funcs[0]

    if (f.isTool) {
        Terminal.log("FAIL: Regular function should not be marked as tool")
        return
    }

    Terminal.log("PASS: Regular function not marked as tool")
}

fn testAsyncToolFunction() {
    Terminal.log("Testing 'tool async function' parsing...")

    const src: string = `
tool async function fetchData(url: string): string! {
    return ""
}
`
    const p: Parser = new Parser(lexSrc(src))
    const prog: Program = p.parseModule()

    if (prog.funcs.len() == 0) {
        Terminal.log("FAIL: No functions parsed")
        return
    }

    const f: Func = prog.funcs[0]

    if (!f.isTool) {
        Terminal.log("FAIL: Function should be marked as tool")
        return
    }

    if (!f.isAsync) {
        Terminal.log("FAIL: Function should be marked as async")
        return
    }

    Terminal.log("PASS: 'tool async function' parsed correctly")
}

fn testMultipleToolFunctions() {
    Terminal.log("Testing multiple tool functions...")

    const src: string = `
tool function read(path: string): string {
    return ""
}

function helper(): void {
}

tool function write(path: string, content: string): void {
}
`
    const p: Parser = new Parser(lexSrc(src))
    const prog: Program = p.parseModule()

    if (prog.funcs.len() != 3) {
        Terminal.log(`FAIL: Expected 3 functions, got ${prog.funcs.len()}`)
        return
    }

    // Contar tools
    let toolCount: i64 = 0
    for (const f of prog.funcs) {
        if (f.isTool) { toolCount = toolCount + 1; }
    }

    if (toolCount != 2) {
        Terminal.log(`FAIL: Expected 2 tool functions, got ${toolCount}`)
        return
    }

    Terminal.log("PASS: Multiple tool functions parsed correctly")
}

// ══════════════════════════════════════════════════════════════════════════════
// MAIN
// ══════════════════════════════════════════════════════════════════════════════

Terminal.log("=== Tool Function Tests ===")
Terminal.log("")

testToolKeyword()
testToolFunctionParsing()
testRegularFunctionNotTool()
testAsyncToolFunction()
testMultipleToolFunctions()

Terminal.log("")
Terminal.log("All tests completed!")
