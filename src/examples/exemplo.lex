// exemplo.lex — um tour por (quase) toda a linguagem lex, num arquivo só.
//
// Roda de cima pra baixo imprimindo cada resultado com `log`. Reúne o que antes
// estava espalhado em vários exemplos: OOP (class/extends/vtable/static),
// arrays/strings/maps/JSON, erros forçados pelo compilador, funções como valor,
// threads + canais e memória crua com defer.
//
// Compilar e rodar:  lex examples/exemplo.lex --run
//
// A MESMA fonte cruza para outros alvos (o runtime é freestanding):
//   lex examples/exemplo.lex --target linux-x64   -o exemplo-linux
//   lex examples/exemplo.lex --target windows-x64 -o exemplo.exe
//   lex examples/exemplo.lex --target macos-arm64 -o exemplo-mac

// ===========================================================================
// 1. OOP: campos, construtor, herança, polimorfismo (vtable), private, static
//    + interface/implements (contrato de assinaturas checado em compilação)
// ===========================================================================

// uma interface só declara assinaturas (sem corpo). `implements` faz o
// compilador EXIGIR que a classe tenha cada método, público e com a mesma
// assinatura — próprio ou herdado. O nome da interface não é um tipo de valor.
interface Identificavel {
    papel(): string
    cartao(): string
}

class Pessoa implements Identificavel {
    nome: string
    private idade: i64

    constructor(nome: string, idade: i64) {
        this.nome = nome
        this.idade = idade
    }

    // sobrescrito pelas subclasses — dispatch dinâmico pela vtable do objeto
    papel(): string {
        return "pessoa"
    }

    aniversario() {
        this.idade = this.idade + 1
    }

    cartao(): string {
        return `${this.nome}, ${this.idade} anos — ${this.papel()}`
    }
}

class Aluno extends Pessoa {
    nota: i64

    constructor(nome: string, idade: i64, nota: i64) {
        super(nome, idade)
        this.nota = nota
    }

    papel(): string {
        return "aluno"
    }

    static escola(): string {
        return "Escola Lex"
    }
}

// ===========================================================================
// 2. Erros forçados pelo compilador: `: i64!`, fail, try, catch
// ===========================================================================

// 1 = divisão por zero. Quem chama é OBRIGADO a tratar (try propaga, catch trata).
function media(soma: i64, n: i64): i64! {
    if (n == 0) {
        fail 1;
    }
    return soma / n;
}

// ===========================================================================
// 3. Arrays tipados
// ===========================================================================

function somar(xs: i64[]): i64 {
    let total: i64 = 0;
    let i: i64 = 0;
    while (i < xs.len()) {
        total = total + xs[i];
        i = i + 1;
    }
    return total;
}

// ===========================================================================
// 4. Threads + canais: cada worker devolve o quadrado pelo canal compartilhado
// ===========================================================================

function worker(x: i64, out: Channel<i64>) {
    out.send(x * x);
}

// async fn: chamá-la lança uma thread e devolve Future<i64>; await espera (join)
async function quadrado(x: i64): i64 {
    return x * x;
}

// ===========================================================================
// 5. Memória crua: alloc + defer/free + poke/peek
// ===========================================================================

function checksum(): i64 {
    const buf: ptr = alloc(16);
    defer buf.free();            // liberado em qualquer saída da função

    buf.poke32(0, 1000);
    buf.poke32(4, 300);
    buf.poke8(8, 37);
    return buf.peek32(0) + buf.peek32(4) + buf.peek8(8);   // 1337
}

// ===========================================================================
// 6. Funções como valor: recebe uma função e a aplica (ver arrow no main)
// ===========================================================================

function aplicar(f: (i64) => i64, x: i64): i64 {
    return f(x);
}

// ===========================================================================
// 7. Genéricos (type erasure): uma pilha e uma função que servem p/ qualquer tipo
// ===========================================================================

class Pilha<T> {
    items: T[]
    constructor() { this.items = [] }
    push(x: T) { this.items.push(x) }
    pop(): T { return this.items.pop() }
    size(): i64 { return this.items.len() }
}

function maior<T>(a: T, b: T): T {
    if (a > b) { return a; }
    return b;
}

// --- OOP + polimorfismo ---
const ana = new Aluno("Ana", 17, 9);
ana.aniversario();                    // mexe no campo privado herdado
Terminal.log(ana.cartao());                    // Ana, 18 anos — aluno
Terminal.log(`escola: ${Aluno.escola()}`);     // método estático, sem objeto

// --- arrays + strings ---
const notas: i64[] = [7, 8, 10, 6, 9];
Terminal.log(`total: ${somar(notas)}`);        // total: 40

const nomes: string[] = ["ana", "bia", "caio"];
Terminal.log(nomes.join(", "));                // ana, bia, caio
Terminal.log("  Olá Mundo  ".trim().toLower().replace(" ", "-"));  // olá-mundo

// --- erros: caminho feliz e fallback ---
const m: i64 = try media(somar(notas), notas.len());
Terminal.log(`média: ${m}`);                   // média: 8
const seguro: i64 = media(10, 0) catch 0;
Terminal.log(`media(10,0) -> ${seguro}`);      // 0 (o compilador proíbe ignorar o erro)

// --- map: dicionário string -> valor ---
let estoque: Map<i64> = { "maçã": 12, "pera": 7 };
estoque.mapSet("uva", 30);
Terminal.log(estoque.mapGet("uva"));           // 30

// --- threads + canais (fan-in: a ordem varia, a soma não) ---
const c: Channel<i64> = channel();
spawn worker(2, c);
spawn worker(3, c);
spawn worker(4, c);
let soma: i64 = 0;
let k: i64 = 0;
while (k < 3) {
    soma = soma + c.recv();           // 4 + 9 + 16
    k = k + 1;
}
Terminal.log(`canais: ${soma}`);               // canais: 29

// --- async / await (Future sobre threads reais) ---
const f1: Future<i64> = quadrado(6);           // dispara em paralelo
const f2: Future<i64> = quadrado(7);
Terminal.log(`async: ${await f1 + await f2}`); // async: 85 (36 + 49)

// --- função como valor + arrow function inline ---
Terminal.log(aplicar((x: i64) => x + 1, 41));  // 42

// --- memória crua ---
Terminal.log(`checksum: ${checksum()}`);       // checksum: 1337

// --- JSON: literal de objeto + montar/serializar ---
// o literal já nasce json (cada valor é embrulhado: string→jsonStr etc.);
// depois dá pra continuar mutando com jsonSet.
const resp: json = {
    escola: Aluno.escola(),
};
resp.jsonSet("media", jsonNum(m));
resp.jsonSet("ok", jsonBool(1));
Terminal.log(resp.jsonStringify());            // {"escola":"Escola Lex","media":8,"ok":true}

// ===========================================================================
// 9. Operadores: lógicos (curto-circuito), bitwise, comparação e compostos
// ===========================================================================
Terminal.log(`and/or: ${(2 > 1) && (3 < 4)} ${(1 > 9) || (5 == 5)}`); // true true
Terminal.log(`bitwise: ${6 & 3} ${1 << 4} ${255 >> 1} ${5 ^ 1}`);     // 2 16 127 4
Terminal.log(`mod/le/ge: ${17 % 5} ${3 <= 3} ${4 >= 9}`);             // 2 true false
let cont: i64 = 10;
cont += 5;  cont *= 2;  cont--;                 // composto + decremento
Terminal.log(`compostos: ${cont}`);            // 29

// ===========================================================================
// 10. for, for...of, break/continue e match
// ===========================================================================
let soma_pares: i64 = 0;
for (let i: i64 = 0; i < 100; i++) {
    if (i % 2 == 1) { continue; }              // pula ímpares
    if (i > 8) { break; }                       // para em 8
    soma_pares += i;
}
Terminal.log(`for/break/continue: ${soma_pares}`);   // 20 (0+2+4+6+8)

const linguas: string[] = ["lex", "rust", "zig"];
for (const lang of linguas) {
    // match como EXPRESSÃO: o valor do braço que casar
    const papel: string = match (lang) {
        "lex" => "a nossa",
        "rust" => "o compilador",
        outra => outra,                     // binding: casa tudo
    };
    Terminal.log(`${lang}: ${papel}`);
}

// match com GUARDA (if) e FAIXA (a..b)
for (const n of [3, 17, 90]) {
    const tam: string = match (n) {
        x if x < 10 => "pequeno",           // guarda
        10..50 => "médio",                  // faixa [10, 50)
        _ => "grande",
    };
    Terminal.log(`${n} é ${tam}`);
}

// ===========================================================================
// 11. Ponto flutuante (f64) + math
// ===========================================================================
const raio: f64 = 2.0;
const area: f64 = 3.14159 * raio * raio;
Terminal.log(`área do círculo: ${area}`);      // 12.56636
Terminal.log(`sqrt(2) = ${sqrt(2.0)}`);        // 1.414214
Terminal.log(`pow(2,10) = ${pow(2.0, 10.0)}`); // 1024.0
Terminal.log(`min/max = ${min(3, 9)} ${max(2.5, 1.5)}`);  // 3 2.5
Terminal.log(`7 / 2 (float) = ${7.0 / 2.0}`);  // 3.5

// ===========================================================================
// 12. Genéricos: args de tipo reificados (o tipo concreto sobrevive)
// ===========================================================================
const p: Pilha<i64> = new Pilha<i64>();
p.push(10);
p.push(20);
p.push(30);
Terminal.log(`pilha topo: ${p.pop()}`);        // 30
Terminal.log(`pilha tamanho: ${p.size()}`);    // 2
Terminal.log(`max genérico: ${maior(3, 9)}`);  // 9

// o tipo concreto de T sobrevive: string e f32 saem certos no ${}
const cofre: Pilha<string> = new Pilha<string>();
cofre.push("segredo");
Terminal.log(`cofre: ${cofre.pop()}`);         // segredo (não vira número!)

// ===========================================================================
// 13. f32 (distinto de f64; promove para f64 nos cálculos/saída)
// ===========================================================================
const meio: f32 = 0.5;
const tres: f32 = meio * 6.0;
Terminal.log(`f32: ${meio} * 6 = ${tres}`);    // 0.5 * 6 = 3.0
