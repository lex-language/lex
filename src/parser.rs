//! Parser de descida recursiva: tokens -> AST.

use crate::ast::*;
use crate::diag::{self, Source};
use crate::lexer::Lexed;
use crate::token::{Token, TplPart};

pub struct Parser<'a> {
    tokens: Vec<Token>,
    /// Span (início, fim em chars no fonte) de cada token, paralelo a `tokens`.
    spans: Vec<(usize, usize)>,
    pos: usize,
    /// Span do último token consumido (para erros logo após um advance).
    last_span: (usize, usize),
    /// Arrow functions içadas para o topo do programa (lambda lifting).
    lambdas: Vec<Function>,
    /// Distingue lambdas de arquivos diferentes (módulos importados).
    module_id: usize,
    /// Fonte de onde os tokens vieram, para renderizar os erros.
    src: &'a Source,
}

impl<'a> Parser<'a> {
    pub fn new(
        tokens: Vec<Token>,
        spans: Vec<(usize, usize)>,
        module_id: usize,
        src: &'a Source,
    ) -> Self {
        Parser { tokens, spans, pos: 0, last_span: (0, 0), lambdas: Vec::new(), module_id, src }
    }

    /// Início (em chars no fonte) do próximo token — para abrir um `Span`.
    fn here_lo(&self) -> usize {
        self.spans[self.next_pos()].0
    }

    /// Monta um `Span` deste módulo de `lo` até o fim do último token consumido.
    fn span_from(&self, lo: usize) -> Span {
        Span { lo, hi: self.last_span.1, module: self.module_id }
    }

    /// `Span` cobrindo só o próximo token (ex.: o nome numa declaração).
    fn span_here(&self) -> Span {
        let (lo, hi) = self.spans[self.next_pos()];
        Span { lo, hi, module: self.module_id }
    }

    /// Erro fatal apontando o próximo token (ainda não consumido).
    fn fail_here(&self, msg: &str, hint: Option<&str>) -> ! {
        diag::fatal(self.src, self.spans[self.next_pos()], msg, hint)
    }

    /// Erro fatal apontando o último token consumido.
    fn fail_last(&self, msg: &str, hint: Option<&str>) -> ! {
        diag::fatal(self.src, self.last_span, msg, hint)
    }

    /// Índice do próximo token que não é quebra de linha (o Eof segura).
    fn next_pos(&self) -> usize {
        let mut i = self.pos;
        while self.tokens[i] == Token::Newline {
            i += 1;
        }
        i
    }

    /// Quebras de linha são invisíveis para peek/advance; só importam como
    /// terminador de statement (ver `expect_terminator`/`newline_before`).
    fn peek(&self) -> &Token {
        &self.tokens[self.next_pos()]
    }

    /// Espia n tokens à frente, ignorando quebras de linha (o Eof segura).
    fn peek_ahead(&self, n: usize) -> &Token {
        let mut i = self.next_pos();
        for _ in 0..n {
            if self.tokens[i] == Token::Eof {
                break;
            }
            i += 1;
            while self.tokens[i] == Token::Newline {
                i += 1;
            }
        }
        &self.tokens[i]
    }

    /// Há quebra de linha entre o último token consumido e o próximo?
    fn newline_before(&self) -> bool {
        self.tokens[self.pos..self.next_pos()].contains(&Token::Newline)
    }

    fn advance(&mut self) -> Token {
        self.pos = self.next_pos();
        let t = self.tokens[self.pos].clone();
        self.last_span = self.spans[self.pos];
        self.pos += 1;
        t
    }

    fn expect(&mut self, expected: Token) {
        if *self.peek() == expected {
            self.advance();
        } else {
            self.fail_here(
                &format!(
                    "expected {}, found {}",
                    expected.describe(),
                    self.peek().describe()
                ),
                None,
            );
        }
    }

    /// Fim de statement: ';' explícito, quebra de linha, '}' ou fim do
    /// arquivo — o ponto e vírgula é opcional.
    fn expect_terminator(&mut self) {
        if *self.peek() == Token::Semicolon {
            self.advance();
            return;
        }
        if self.newline_before() || *self.peek() == Token::RBrace || *self.peek() == Token::Eof {
            return;
        }
        self.fail_here(
            &format!(
                "expected ';' or a newline after the statement, found {}",
                self.peek().describe()
            ),
            Some("each statement ends at a newline; the ';' is optional"),
        );
    }

    fn parse_program(&mut self) -> Program {
        let mut imports = Vec::new();
        let mut structs = Vec::new();
        let mut interfaces = Vec::new();
        let mut classes = Vec::new();
        let mut enums = Vec::new();
        let mut functions = Vec::new();
        // Statements escritos no topo do arquivo (fora de qualquer função):
        // viram o corpo de um `main` sintetizado. É isso que torna a
        // `function main` opcional — dá pra escrever o arquivo como um script.
        let mut main_body: Vec<Stmt> = Vec::new();
        while *self.peek() != Token::Eof {
            match self.peek() {
                Token::Semicolon => {
                    self.advance();
                }
                Token::Import => imports.push(self.parse_import()),
                Token::Type => structs.push(self.parse_struct_def()),
                Token::Interface => interfaces.push(self.parse_interface()),
                Token::Class => classes.push(self.parse_class()),
                Token::Enum => enums.push(self.parse_enum()),
                Token::Declare => functions.push(self.parse_declare()),
                Token::Function | Token::Async => functions.push(self.parse_function()),
                // qualquer outra coisa no topo é um statement de script
                _ => main_body.push(self.parse_stmt()),
            }
        }
        // arrow functions viram funções de topo, como as outras
        functions.append(&mut self.lambdas);

        let has_main = functions.iter().any(|f| f.name == "main");

        if self.module_id == 0 {
            // Arquivo de entrada: os statements de topo formam o `main`.
            if has_main && !main_body.is_empty() {
                diag::fatal_plain(
                    "this file defines 'main' and also has top-level statements — use one \
                     or the other (move the statements into main, or drop the explicit main)",
                );
            }
            if !has_main {
                // Sem `main` explícito: sintetiza um a partir dos statements de
                // topo (vazio → um main que só retorna 0). Falível se algum
                // statement usa `try`/`fail`, para o embrulho tratar o erro.
                let fallible = stmts_need_fallible(&main_body);
                functions.push(Function {
                    name: "main".to_string(),
                    is_async: false,
                    type_params: Vec::new(),
                    params: Vec::new(),
                    ret_type: Type::I32,
                    fallible,
                    external: false,
                    body: main_body,
                    span: Span::DUMMY,
                    ret_inferred: false,
                });
            }
        } else if !main_body.is_empty() {
            // Módulo importado: não há ordem de inicialização, então não
            // rodamos código de topo — só declarações são exportáveis.
            diag::fatal_plain(
                "top-level statements are only allowed in the entry file; an imported \
                 module must contain only declarations (import/type/class/function)",
            );
        }

        Program { imports, structs, interfaces, classes, enums, functions }
    }

    /// `enum Nome { A, B, C }` — variantes separadas por vírgula, ';' ou quebra
    /// de linha. Cada uma vira uma constante inteira na ordem (0, 1, 2…).
    fn parse_enum(&mut self) -> EnumDef {
        self.expect(Token::Enum);
        let span = self.span_here();
        let name = self.parse_ident();
        self.expect(Token::LBrace);
        let mut variants = Vec::new();
        while *self.peek() != Token::RBrace {
            if matches!(self.peek(), Token::Semicolon | Token::Comma) {
                self.advance();
                continue;
            }
            variants.push(self.parse_ident());
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RBrace);
        if *self.peek() == Token::Semicolon {
            self.advance();
        }
        EnumDef { name, variants, span }
    }

    /// `class Nome extends Pai { campo: tipo  constructor(...) {...}  m() {...} }`
    /// Membros aceitam os modificadores `private` e `static` (métodos).
    fn parse_class(&mut self) -> ClassDef {
        self.expect(Token::Class);
        let span = self.span_here();
        let name = self.parse_ident();
        let type_params = self.parse_type_params();
        let parent = if *self.peek() == Token::Extends {
            self.advance();
            Some(self.parse_ident())
        } else {
            None
        };
        // `implements A, B` (depois do `extends`, se houver): lista de interfaces.
        let mut implements = Vec::new();
        if *self.peek() == Token::Implements {
            self.advance();
            loop {
                implements.push(self.parse_ident());
                if *self.peek() == Token::Comma {
                    self.advance();
                } else {
                    break;
                }
            }
        }
        self.expect(Token::LBrace);

        let mut fields = Vec::new();
        let mut statics = Vec::new();
        let mut methods = Vec::new();
        while *self.peek() != Token::RBrace {
            if *self.peek() == Token::Semicolon {
                self.advance();
                continue;
            }
            let mut private = false;
            let mut is_static = false;
            loop {
                match self.peek() {
                    Token::Private => {
                        self.advance();
                        private = true;
                    }
                    Token::Static => {
                        self.advance();
                        is_static = true;
                    }
                    _ => break,
                }
            }
            let mspan = self.span_here();
            let mname = self.parse_ident();

            // `nome(` é método (ou constructor); `nome:` é campo
            if *self.peek() == Token::LParen {
                self.advance();
                let mut params = Vec::new();
                let mut seen_default = false;
                while *self.peek() != Token::RParen {
                    params.push(self.parse_param(&mut seen_default, true));
                    if *self.peek() == Token::Comma {
                        self.advance();
                    }
                }
                self.expect(Token::RParen);

                let ret_type = if *self.peek() == Token::Colon {
                    self.advance();
                    self.parse_type()
                } else {
                    Type::Void
                };
                let fallible = if *self.peek() == Token::Bang {
                    self.advance();
                    true
                } else {
                    false
                };
                let body = self.parse_block();
                methods.push(Method {
                    name: mname,
                    params,
                    ret_type,
                    fallible,
                    private,
                    is_static,
                    body,
                    span: mspan,
                });
            } else {
                self.expect(Token::Colon);
                let ty = self.parse_type();
                if is_static {
                    // campo static exige inicializador: `static n: i64 = 0`
                    if *self.peek() != Token::Eq {
                        self.fail_here(
                            &format!(
                                "class '{}': static field '{}' needs an initializer, e.g. \
                                 'static {}: ... = <value>'",
                                name, mname, mname
                            ),
                            None,
                        );
                    }
                    self.advance(); // '='
                    let init = self.parse_expr();
                    self.expect_terminator();
                    statics.push(StaticField { name: mname, ty, private, init, span: mspan });
                } else {
                    self.expect_terminator();
                    fields.push(ClassField { name: mname, ty, private, span: mspan });
                }
            }
        }
        self.expect(Token::RBrace);
        if *self.peek() == Token::Semicolon {
            self.advance();
        }
        ClassDef { name, type_params, parent, implements, fields, statics, methods, span }
    }

    /// `interface Nome { metodo(args): tipo  outro(): tipo! }` — só assinaturas,
    /// sem corpo. Separador é vírgula, ';' ou quebra de linha. Não aceita
    /// `private`/`static` (todo método de interface é público e de instância)
    /// nem corpo `{ ... }`.
    fn parse_interface(&mut self) -> InterfaceDef {
        self.expect(Token::Interface);
        let span = self.span_here();
        let name = self.parse_ident();
        self.expect(Token::LBrace);

        let mut methods = Vec::new();
        while *self.peek() != Token::RBrace {
            if *self.peek() == Token::Semicolon || *self.peek() == Token::Comma {
                self.advance();
                continue;
            }
            if matches!(self.peek(), Token::Private | Token::Static) {
                self.fail_here(
                    &format!(
                        "interface '{}': methods cannot be 'private' or 'static'",
                        name
                    ),
                    Some("an interface only declares public instance signatures"),
                );
            }
            let mspan = self.span_here();
            let mname = self.parse_ident();
            self.expect(Token::LParen);
            let mut params = Vec::new();
            let mut seen_default = false;
            while *self.peek() != Token::RParen {
                // assinaturas não carregam valores default (allow_default = false)
                params.push(self.parse_param(&mut seen_default, false));
                if *self.peek() == Token::Comma {
                    self.advance();
                }
            }
            self.expect(Token::RParen);

            let ret_type = if *self.peek() == Token::Colon {
                self.advance();
                self.parse_type()
            } else {
                Type::Void
            };
            let fallible = if *self.peek() == Token::Bang {
                self.advance();
                true
            } else {
                false
            };

            if *self.peek() == Token::LBrace {
                self.fail_here(
                    &format!(
                        "interface '{}': method '{}' must not have a body",
                        name, mname
                    ),
                    Some("declare only the signature, e.g.: falar(): string"),
                );
            }
            self.expect_terminator();
            methods.push(InterfaceMethod { name: mname, params, ret_type, fallible, span: mspan });
        }
        self.expect(Token::RBrace);
        if *self.peek() == Token::Semicolon {
            self.advance();
        }
        InterfaceDef { name, methods, span }
    }

    /// `type Nome = { campo: tipo, ... }` — separadores podem ser vírgula
    /// ou só quebra de linha (whitespace é ignorado pelo lexer).
    fn parse_struct_def(&mut self) -> StructDef {
        self.expect(Token::Type);
        let span = self.span_here();
        let name = self.parse_ident();
        self.expect(Token::Eq);
        self.expect(Token::LBrace);
        let mut fields = Vec::new();
        while *self.peek() != Token::RBrace {
            let fname = self.parse_ident();
            self.expect(Token::Colon);
            let ty = self.parse_type();
            fields.push((fname, ty));
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RBrace);
        if *self.peek() == Token::Semicolon {
            self.advance();
        }
        StructDef { name, fields, span }
    }

    /// `import { a, b } from "módulo";` — estilo TypeScript. A resolução
    /// do módulo acontece no driver (main.rs).
    fn parse_import(&mut self) -> ImportDecl {
        self.expect(Token::Import);
        self.expect(Token::LBrace);
        let mut names = Vec::new();
        while *self.peek() != Token::RBrace {
            names.push(self.parse_ident());
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RBrace);
        self.expect(Token::From);
        let module = match self.advance() {
            Token::Str(s) => s,
            t => self.fail_last(
                &format!("expected the module path in quotes, found {}", t.describe()),
                Some("e.g.: import { abrir } from \"./arquivos\""),
            ),
        };
        self.expect_terminator();
        ImportDecl { names, module }
    }

    /// Um parâmetro `nome: tipo`, com valor default opcional (`= expr`) quando
    /// `allow_default`. Defaults têm de ser finais: parâmetro obrigatório
    /// depois de um opcional é erro. `seen_default` é o estado compartilhado
    /// do loop de parâmetros que detecta essa ordem.
    fn parse_param(&mut self, seen_default: &mut bool, allow_default: bool) -> Param {
        // `...nome: T[]` — parâmetro variádico (rest). As demais regras (último,
        // único, tipo array, sem default) são validadas no sema.
        let variadic = if *self.peek() == Token::DotDotDot {
            self.advance();
            true
        } else {
            false
        };
        let pname = self.parse_ident();
        self.expect(Token::Colon);
        let ty = self.parse_type();
        let default = if *self.peek() == Token::Eq {
            if !allow_default {
                self.fail_here(
                    "default values are not allowed here",
                    Some("only 'function' and class method parameters can have defaults"),
                );
            }
            if variadic {
                self.fail_here(
                    &format!("variadic parameter '{}' cannot have a default value", pname),
                    Some("a '...' parameter already defaults to an empty array"),
                );
            }
            self.advance();
            *seen_default = true;
            Some(self.parse_expr())
        } else {
            if *seen_default && !variadic {
                self.fail_last(
                    &format!("required parameter '{}' comes after an optional one", pname),
                    Some("once a parameter has a default, every parameter after it needs one too"),
                );
            }
            None
        };
        Param { name: pname, ty, default, variadic }
    }

    fn parse_function(&mut self) -> Function {
        // `async fn ...` — chamá-la lança uma thread e devolve um Future<T>
        let is_async = if *self.peek() == Token::Async {
            self.advance();
            true
        } else {
            false
        };
        self.expect(Token::Function);
        let span = self.span_here();
        let name = self.parse_ident();
        let type_params = self.parse_type_params();
        self.expect(Token::LParen);

        let mut params = Vec::new();
        let mut seen_default = false;
        while *self.peek() != Token::RParen {
            params.push(self.parse_param(&mut seen_default, true));
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RParen);

        // tipo de retorno no estilo TypeScript: `function f(...): i64`.
        // Sem anotação, o tipo é INFERIDO do corpo (sema); `ret_type` fica como
        // Void provisório e `ret_inferred = true` sinaliza a inferência.
        let annotated = *self.peek() == Token::Colon;
        let ret_type = if annotated {
            self.advance();
            self.parse_type()
        } else {
            Type::Void
        };

        // `: i64!` marca a função como falível (pode usar `fail`).
        let fallible = if *self.peek() == Token::Bang {
            self.advance();
            true
        } else {
            false
        };

        let body = self.parse_block();

        Function {
            name,
            is_async,
            type_params,
            params,
            ret_type,
            fallible,
            external: false,
            body,
            span,
            ret_inferred: !annotated,
        }
    }

    /// `declare function nome(args): tipo;` — ambient declaration (como num
    /// .d.ts): assinatura sem corpo; o símbolo vem da libc ou de um .c.
    fn parse_declare(&mut self) -> Function {
        self.expect(Token::Declare);
        self.expect(Token::Function);
        let span = self.span_here();
        let name = self.parse_ident();

        self.expect(Token::LParen);
        let mut params = Vec::new();
        let mut seen_default = false;
        while *self.peek() != Token::RParen {
            params.push(self.parse_param(&mut seen_default, false));
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RParen);

        let ret_type = if *self.peek() == Token::Colon {
            self.advance();
            self.parse_type()
        } else {
            Type::Void
        };
        if *self.peek() == Token::Bang {
            self.fail_here(
                &format!("declare function '{}' cannot be fallible ('!')", name),
                Some("C functions signal errors through their return value"),
            );
        }
        self.expect_terminator();

        Function {
            name,
            is_async: false,
            type_params: Vec::new(),
            params,
            ret_type,
            fallible: false,
            external: true,
            body: Vec::new(),
            span,
            ret_inferred: false,
        }
    }

    /// Bloco entre chaves: `{ stmt* }`. Ponto e vírgula solto é ignorado.
    fn parse_block(&mut self) -> Vec<Stmt> {
        self.expect(Token::LBrace);
        let mut body = Vec::new();
        while *self.peek() != Token::RBrace {
            if *self.peek() == Token::Semicolon {
                self.advance();
                continue;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);
        body
    }

    fn parse_ident(&mut self) -> String {
        match self.advance() {
            Token::Ident(s) => s,
            t => self.fail_last(
                &format!("expected an identifier, found {}", t.describe()),
                None,
            ),
        }
    }

    /// Fecha um `<...>` de tipo genérico. Trata `>>` e `>=` colados (de tipos
    /// aninhados como `Map<Map<i64>>`): consome um `>` e devolve o restante
    /// (`>` ou `=`) ao fluxo, reescrevendo o token no lugar.
    fn expect_type_gt(&mut self) {
        let p = self.next_pos();
        match self.tokens[p] {
            Token::Gt => {
                self.advance();
            }
            Token::Shr => {
                self.tokens[p] = Token::Gt; // sobra um '>' para o nível externo
                self.last_span = self.spans[p];
            }
            Token::Ge => {
                self.tokens[p] = Token::Eq; // sobra um '=' para o statement
                self.last_span = self.spans[p];
            }
            _ => self.fail_here(
                &format!("expected '>', found {}", self.peek().describe()),
                Some("close the generic with '>'"),
            ),
        }
    }

    /// Parâmetros de tipo de uma declaração: `<T>`, `<T, U>` ou nada.
    fn parse_type_params(&mut self) -> Vec<String> {
        let mut params = Vec::new();
        if *self.peek() == Token::Lt {
            self.advance();
            loop {
                params.push(self.parse_ident());
                if *self.peek() == Token::Comma {
                    self.advance();
                } else {
                    break;
                }
            }
            self.expect_type_gt();
        }
        params
    }

    /// Lookahead read-only: a partir de um `<`, isto é uma lista de argumentos
    /// de tipo seguida de `(` (uma chamada genérica `f<i64>(...)`), e não uma
    /// comparação `f < x`? Aceita só tokens "de tipo" (idents, `,`, `[]`, `<>`)
    /// e exige um `(` logo após o `>` de fecho. Trata `<<`/`>>` colados.
    fn is_generic_call_ahead(&self) -> bool {
        let mut i = self.next_pos();
        if self.tokens[i] != Token::Lt {
            return false;
        }
        i += 1;
        let mut depth = 1i32;
        let n = self.tokens.len();
        while depth > 0 {
            while i < n && self.tokens[i] == Token::Newline {
                i += 1;
            }
            if i >= n {
                return false;
            }
            match &self.tokens[i] {
                Token::Lt => depth += 1,
                Token::Shl => depth += 2,
                Token::Gt => depth -= 1,
                Token::Shr => {
                    if depth >= 2 {
                        depth -= 2;
                    } else {
                        return false;
                    }
                }
                // tokens permitidos dentro de uma lista de tipos
                Token::Ident(_) | Token::Comma | Token::LBracket | Token::RBracket => {}
                // qualquer outra coisa: não são argumentos de tipo
                _ => return false,
            }
            i += 1;
        }
        // depois do `>` de fecho, uma chamada genérica tem um `(`
        while i < n && self.tokens[i] == Token::Newline {
            i += 1;
        }
        matches!(self.tokens.get(i), Some(Token::LParen))
    }

    /// Lê argumentos de tipo `<i64, string>` num uso e os devolve (reificados na
    /// `Type`). Usado em `new Box<i64>(...)`, `id<i64>(x)` e anotações `Box<i64>`.
    fn parse_type_arg_list(&mut self) -> Vec<Type> {
        self.expect(Token::Lt);
        let mut args = Vec::new();
        loop {
            args.push(self.parse_type());
            if *self.peek() == Token::Comma {
                self.advance();
            } else {
                break;
            }
        }
        self.expect_type_gt();
        args
    }

    fn parse_type(&mut self) -> Type {
        // tipo de função: `(i64) => i64` ou `(x: i64) => i64` (estilo TS)
        if *self.peek() == Token::LParen {
            self.advance();
            let mut params = Vec::new();
            while *self.peek() != Token::RParen {
                // nome de parâmetro é opcional no tipo: `(x: i64)` ou `(i64)`
                if matches!(self.peek(), Token::Ident(_)) && *self.peek_ahead(1) == Token::Colon {
                    self.advance();
                    self.advance();
                }
                params.push(self.parse_type());
                if *self.peek() == Token::Comma {
                    self.advance();
                }
            }
            self.expect(Token::RParen);
            self.expect(Token::FatArrow);
            let ret = self.parse_type();
            return Type::Fn(params, Box::new(ret));
        }

        let name = self.parse_ident();
        let mut ty = match name.as_str() {
            "i32" => Type::I32,
            "i64" => Type::I64,
            "i8" => Type::I8,
            "f64" | "float" => Type::F64,
            "f32" => Type::F32,
            "bool" => Type::Bool,
            "ptr" => Type::Ptr,
            "void" => Type::Void,
            // aliases: uma string e um componente renderizado são ponteiros
            "string" => Type::Ptr,
            "Component" => Type::Ptr,
            // valor JSON dinâmico
            "json" | "Json" => Type::Json,
            // valor de qualquer tipo (boxed) — ver Type::Any
            "any" => Type::Any,
            // dicionário tipado: `Map<T>`
            "Map" => {
                self.expect(Token::Lt);
                let inner = self.parse_type();
                self.expect_type_gt();
                Type::Map(Box::new(inner))
            }
            // canal entre threads: `Channel<T>`
            "Channel" => {
                self.expect(Token::Lt);
                let inner = self.parse_type();
                self.expect_type_gt();
                Type::Chan(Box::new(inner))
            }
            // resultado pendente de uma async fn: `Future<T>`
            "Future" => {
                self.expect(Token::Lt);
                let inner = self.parse_type();
                self.expect_type_gt();
                Type::Future(Box::new(inner))
            }
            // qualquer outro nome é um struct/classe (ou um parâmetro de tipo).
            // Argumentos genéricos (`Box<i64>`) são reificados na Type.
            _ => {
                let args = if *self.peek() == Token::Lt {
                    self.parse_type_arg_list()
                } else {
                    Vec::new()
                };
                Type::Named(name, args)
            }
        };
        // sufixo `[]`: array, encadeável (`i64[][]` = array de array de i64)
        while *self.peek() == Token::LBracket && *self.peek_ahead(1) == Token::RBracket {
            self.advance();
            self.advance();
            ty = Type::Array(Box::new(ty));
        }
        ty
    }

    /// Um statement com posição: delega para `parse_stmt_kind` e embrulha o
    /// resultado num `Stmt` com o span do trecho consumido.
    fn parse_stmt(&mut self) -> Stmt {
        let lo = self.here_lo();
        let kind = self.parse_stmt_kind();
        Stmt { kind, span: self.span_from(lo) }
    }

    fn parse_stmt_kind(&mut self) -> StmtKind {
        match self.peek() {
            Token::Const | Token::Let => {
                let s = self.parse_let_decl();
                self.expect_terminator();
                s
            }
            // reatribuição: `x = expr;` (só Ident seguido de '=')
            Token::Ident(_) if *self.peek_ahead(1) == Token::Eq => {
                let name = self.parse_ident();
                self.expect(Token::Eq);
                let value = self.parse_expr();
                self.expect_terminator();
                StmtKind::Assign { name, value }
            }
            Token::While => {
                self.advance();
                let cond = self.parse_expr();
                let body = self.parse_block();
                StmtKind::While { cond, body }
            }
            Token::For => self.parse_for(),
            Token::Break => {
                self.advance();
                self.expect_terminator();
                StmtKind::Break
            }
            Token::Continue => {
                self.advance();
                self.expect_terminator();
                StmtKind::Continue
            }
            Token::Return => {
                self.advance();
                // `return` vazio (função void) ou `return expr` — quebra de
                // linha logo após o return encerra o statement (estilo Go)
                let value = if *self.peek() == Token::Semicolon
                    || *self.peek() == Token::RBrace
                    || self.newline_before()
                {
                    None
                } else {
                    Some(self.parse_expr())
                };
                self.expect_terminator();
                StmtKind::Return(value)
            }
            Token::Fail => {
                self.advance();
                let code = self.parse_expr();
                self.expect_terminator();
                StmtKind::Fail(code)
            }
            Token::Defer => {
                self.advance();
                // o corpo do defer é um único statement (tipicamente uma
                // chamada, ex.: defer free(p); defer close(fd))
                let inner = self.parse_stmt();
                StmtKind::Defer(Box::new(inner))
            }
            Token::If => {
                self.advance();
                let cond = self.parse_expr();
                let then_body = self.parse_block();
                let else_body = if *self.peek() == Token::Else {
                    self.advance();
                    // `else if`: o else é um único statement-if (encadeia a
                    // cadeia recursivamente, sem exigir um bloco `{`).
                    if *self.peek() == Token::If {
                        vec![self.parse_stmt()]
                    } else {
                        self.parse_block()
                    }
                } else {
                    Vec::new()
                };
                StmtKind::If { cond, then_body, else_body }
            }
            _ => {
                let e = self.parse_expr();
                let s = self.finish_stmt_expr(e);
                self.expect_terminator();
                s
            }
        }
    }

    /// `const`/`let nome[: tipo] = expr` — NÃO consome o terminador (o
    /// chamador decide). Reusado pelo statement comum e pelo init de um `for`.
    fn parse_let_decl(&mut self) -> StmtKind {
        let mutable = matches!(self.advance(), Token::Let);
        let name = self.parse_ident();
        let ty = if *self.peek() == Token::Colon {
            self.advance();
            Some(self.parse_type())
        } else {
            None
        };
        self.expect(Token::Eq);
        let value = self.parse_expr();
        StmtKind::Let { name, ty, value, mutable }
    }

    /// Dado um lvalue/expr já parseado, detecta `=`, atribuição composta
    /// (`+=`, …) e `++`/`--`, devolvendo o Stmt apropriado. NÃO consome o
    /// terminador. Reusado pelo statement comum, pelo `for` e pelos braços
    /// de `match`.
    fn finish_stmt_expr(&mut self, e: Expr) -> StmtKind {
        if *self.peek() == Token::Eq {
            self.advance();
            let value = self.parse_expr();
            return self.make_assign(e, value);
        }
        let compound = match self.peek() {
            Token::PlusEq => Some(BinOp::Add),
            Token::MinusEq => Some(BinOp::Sub),
            Token::StarEq => Some(BinOp::Mul),
            Token::SlashEq => Some(BinOp::Div),
            Token::PercentEq => Some(BinOp::Mod),
            _ => None,
        };
        if let Some(op) = compound {
            self.advance();
            let rhs = self.parse_expr();
            let value = Expr::Binary {
                op,
                lhs: Box::new(e.clone()),
                rhs: Box::new(rhs),
            };
            return self.make_assign(e, value);
        }
        let step = match self.peek() {
            Token::PlusPlus => Some(BinOp::Add),
            Token::MinusMinus => Some(BinOp::Sub),
            _ => None,
        };
        if let Some(op) = step {
            self.advance();
            let value = Expr::Binary {
                op,
                lhs: Box::new(e.clone()),
                rhs: Box::new(Expr::Int(1)),
            };
            return self.make_assign(e, value);
        }
        StmtKind::Expr(e)
    }

    /// Monta o statement de atribuição certo para um lvalue (variável, campo
    /// ou índice). Reusado por `=`, pelos compostos (`+=`, …) e por `++`/`--`.
    fn make_assign(&self, lvalue: Expr, value: Expr) -> StmtKind {
        match lvalue {
            Expr::Field { base, field } => StmtKind::FieldAssign { base: *base, field, value },
            Expr::Index { base, index } => StmtKind::IndexAssign { base: *base, index: *index, value },
            Expr::Var(name) => StmtKind::Assign { name, value },
            _ => self.fail_last(
                "the left-hand side of an assignment must be a variable, a field or an index",
                Some("e.g.: x = 1, object.field = 1 or arr[0] = 1"),
            ),
        }
    }

    /// `for (...)`: detecta `for...of` (`const x of iterável`) ou cai no estilo
    /// C (`init; cond; update`, cada parte opcional).
    fn parse_for(&mut self) -> StmtKind {
        self.expect(Token::For);
        self.expect(Token::LParen);

        // for...of: `for (const|let nome of iterável)` — 'of' é contextual
        let is_forof = matches!(self.peek(), Token::Const | Token::Let)
            && matches!(self.peek_ahead(1), Token::Ident(_))
            && matches!(self.peek_ahead(2), Token::Ident(s) if s.as_str() == "of");
        if is_forof {
            let mutable = matches!(self.advance(), Token::Let);
            let name = self.parse_ident();
            self.advance(); // consome o 'of'
            let iterable = self.parse_expr();
            self.expect(Token::RParen);
            let body = self.parse_block();
            return StmtKind::ForOf { name, mutable, iterable, body };
        }

        // estilo C: for (init; cond; update). init/update são statements com
        // posição própria (embrulham o StmtKind do let/expr no span do trecho).
        let init = if *self.peek() == Token::Semicolon {
            None
        } else {
            let lo = self.here_lo();
            let kind = if matches!(self.peek(), Token::Const | Token::Let) {
                self.parse_let_decl()
            } else {
                let e = self.parse_expr();
                self.finish_stmt_expr(e)
            };
            Some(Box::new(Stmt { kind, span: self.span_from(lo) }))
        };
        self.expect(Token::Semicolon);

        let cond = if *self.peek() == Token::Semicolon {
            None
        } else {
            Some(self.parse_expr())
        };
        self.expect(Token::Semicolon);

        let update = if *self.peek() == Token::RParen {
            None
        } else {
            let lo = self.here_lo();
            let e = self.parse_expr();
            let kind = self.finish_stmt_expr(e);
            Some(Box::new(Stmt { kind, span: self.span_from(lo) }))
        };
        self.expect(Token::RParen);

        let body = self.parse_block();
        StmtKind::For { init, cond, update, body }
    }

    /// `match (expr) { padrão [if guarda] => corpo, ... }` — uma EXPRESSÃO (o
    /// `match` token já foi consumido). Braços separados por vírgula (opcional)
    /// ou quebra; o valor é o do corpo que casar.
    fn parse_match(&mut self) -> Expr {
        self.expect(Token::LParen);
        let scrutinee = self.parse_expr();
        self.expect(Token::RParen);
        self.expect(Token::LBrace);

        let mut arms = Vec::new();
        while *self.peek() != Token::RBrace {
            if *self.peek() == Token::Comma || *self.peek() == Token::Semicolon {
                self.advance();
                continue;
            }
            let pattern = self.parse_pattern();
            // guarda opcional: `padrão if cond =>`
            let guard = if *self.peek() == Token::If {
                self.advance();
                Some(self.parse_expr())
            } else {
                None
            };
            self.expect(Token::FatArrow);
            let body = self.parse_arm_body();
            arms.push(MatchArm { pattern, guard, body });
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RBrace);
        Expr::Match { scrutinee: Box::new(scrutinee), arms }
    }

    /// Lê um inteiro com sinal opcional (`5`, `-3`) — usado nos padrões.
    fn parse_signed_int(&mut self) -> i64 {
        let neg = if *self.peek() == Token::Minus {
            self.advance();
            true
        } else {
            false
        };
        match self.advance() {
            Token::Int(n) => if neg { -n } else { n },
            t => self.fail_last(
                &format!("expected a number in pattern, found {}", t.describe()),
                None,
            ),
        }
    }

    /// Padrão de um braço: literal (inteiro com sinal, bool, string), faixa
    /// `lo..hi` (`[lo, hi)`), `_` (curinga) ou um identificador (binding).
    fn parse_pattern(&mut self) -> Pattern {
        match self.peek() {
            Token::Int(_) | Token::Minus => {
                let lo = self.parse_signed_int();
                if *self.peek() == Token::DotDot {
                    self.advance();
                    let hi = self.parse_signed_int();
                    Pattern::Range(lo, hi)
                } else {
                    Pattern::Int(lo)
                }
            }
            Token::True => {
                self.advance();
                Pattern::Bool(true)
            }
            Token::False => {
                self.advance();
                Pattern::Bool(false)
            }
            Token::Str(_) => match self.advance() {
                Token::Str(s) => Pattern::Str(s),
                _ => unreachable!(),
            },
            // `{ campo1, campo2 }` — destructuring de struct/objeto
            Token::LBrace => {
                self.advance();
                let mut names = Vec::new();
                while *self.peek() != Token::RBrace {
                    names.push(self.parse_ident());
                    if *self.peek() == Token::Comma {
                        self.advance();
                    }
                }
                self.expect(Token::RBrace);
                Pattern::Destructure(names)
            }
            Token::Ident(name) if name.as_str() == "_" => {
                self.advance();
                Pattern::Wildcard
            }
            // `Enum.Variante` — padrão de constante de enum
            Token::Ident(_) if *self.peek_ahead(1) == Token::Dot => {
                let enum_name = self.parse_ident();
                self.expect(Token::Dot);
                let variant = self.parse_ident();
                Pattern::EnumVariant { enum_name, variant }
            }
            // `Classe nome` (dois identificadores) — padrão de tipo: casa pelo
            // tipo de runtime do objeto e liga `nome`. `nome` pode ser `_`.
            Token::Ident(_) if matches!(self.peek_ahead(1), Token::Ident(_)) => {
                let class = self.parse_ident();
                let bind = self.parse_ident();
                Pattern::Type { class, bind }
            }
            Token::Ident(_) => Pattern::Binding(self.parse_ident()),
            _ => self.fail_here(
                "invalid pattern in match",
                Some("use a literal (1, \"x\", true), a range (1..10), '_', or a name to bind"),
            ),
        }
    }

    /// Corpo de um braço de `match`: um bloco `{ ... }` ou um único statement
    /// (sem exigir ';' — a vírgula/quebra separa os braços).
    fn parse_arm_body(&mut self) -> Vec<Stmt> {
        if *self.peek() == Token::LBrace {
            return self.parse_block();
        }
        let lo = self.here_lo();
        let kind = match self.peek() {
            Token::Return => {
                self.advance();
                let value = if matches!(self.peek(), Token::Comma | Token::RBrace)
                    || self.newline_before()
                {
                    None
                } else {
                    Some(self.parse_expr())
                };
                StmtKind::Return(value)
            }
            Token::Fail => {
                self.advance();
                StmtKind::Fail(self.parse_expr())
            }
            Token::Break => {
                self.advance();
                StmtKind::Break
            }
            Token::Continue => {
                self.advance();
                StmtKind::Continue
            }
            Token::Const | Token::Let => self.parse_let_decl(),
            _ => {
                let e = self.parse_expr();
                self.finish_stmt_expr(e)
            }
        };
        vec![Stmt { kind, span: self.span_from(lo) }]
    }

    // expr := catch
    fn parse_expr(&mut self) -> Expr {
        self.parse_catch()
    }

    // catch := or ("catch" catch)?   — associa à direita:
    // `f() catch g() catch 0` = `f() catch (g() catch 0)`
    fn parse_catch(&mut self) -> Expr {
        let lhs = self.parse_or();
        if *self.peek() == Token::Catch {
            self.advance();
            // forma em bloco: `catch { ... }` ou `catch e { ... }`
            let handler = if *self.peek() == Token::LBrace {
                CatchHandler::Block { name: None, body: self.parse_block() }
            } else if matches!(self.peek(), Token::Ident(_))
                && *self.peek_ahead(1) == Token::LBrace
            {
                let name = self.parse_ident();
                CatchHandler::Block { name: Some(name), body: self.parse_block() }
            } else {
                // forma de valor: `catch fallback` (associa à direita)
                CatchHandler::Fallback(Box::new(self.parse_catch()))
            };
            return Expr::Catch {
                lhs: Box::new(lhs),
                handler,
            };
        }
        lhs
    }

    // Escada de precedência (do mais frouxo ao mais forte):
    //   or → and → bitor → bitxor → bitand → eq → rel → shift → add → mul →
    //   unary → postfix. Cada nível é associativo à esquerda.

    // or := and ("||" and)*
    fn parse_or(&mut self) -> Expr {
        let mut left = self.parse_and();
        while *self.peek() == Token::PipePipe {
            self.advance();
            let right = self.parse_and();
            left = Expr::Binary { op: BinOp::Or, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // and := bitor ("&&" bitor)*
    fn parse_and(&mut self) -> Expr {
        let mut left = self.parse_bitor();
        while *self.peek() == Token::AmpAmp {
            self.advance();
            let right = self.parse_bitor();
            left = Expr::Binary { op: BinOp::And, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // bitor := bitxor ("|" bitxor)*
    fn parse_bitor(&mut self) -> Expr {
        let mut left = self.parse_bitxor();
        while *self.peek() == Token::Pipe {
            self.advance();
            let right = self.parse_bitxor();
            left = Expr::Binary { op: BinOp::BitOr, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // bitxor := bitand ("^" bitand)*
    fn parse_bitxor(&mut self) -> Expr {
        let mut left = self.parse_bitand();
        while *self.peek() == Token::Caret {
            self.advance();
            let right = self.parse_bitand();
            left = Expr::Binary { op: BinOp::BitXor, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // bitand := eq ("&" eq)*
    fn parse_bitand(&mut self) -> Expr {
        let mut left = self.parse_eq();
        while *self.peek() == Token::Amp {
            self.advance();
            let right = self.parse_eq();
            left = Expr::Binary { op: BinOp::BitAnd, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // eq := rel (("==" | "!=") rel)*
    fn parse_eq(&mut self) -> Expr {
        let mut left = self.parse_rel();
        loop {
            let op = match self.peek() {
                Token::EqEq => BinOp::Eq,
                Token::Neq => BinOp::Ne,
                _ => break,
            };
            self.advance();
            let right = self.parse_rel();
            left = Expr::Binary { op, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // rel := shift (("<" | ">" | "<=" | ">=") shift)*
    fn parse_rel(&mut self) -> Expr {
        let mut left = self.parse_shift();
        loop {
            let op = match self.peek() {
                Token::Lt => BinOp::Lt,
                Token::Gt => BinOp::Gt,
                Token::Le => BinOp::Le,
                Token::Ge => BinOp::Ge,
                _ => break,
            };
            self.advance();
            let right = self.parse_shift();
            left = Expr::Binary { op, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // shift := add (("<<" | ">>") add)*
    fn parse_shift(&mut self) -> Expr {
        let mut left = self.parse_add();
        loop {
            let op = match self.peek() {
                Token::Shl => BinOp::Shl,
                Token::Shr => BinOp::Shr,
                _ => break,
            };
            self.advance();
            let right = self.parse_add();
            left = Expr::Binary { op, lhs: Box::new(left), rhs: Box::new(right) };
        }
        left
    }

    // add := mul (("+" | "-") mul)*
    fn parse_add(&mut self) -> Expr {
        let mut left = self.parse_mul();
        loop {
            let op = match self.peek() {
                Token::Plus => BinOp::Add,
                Token::Minus => BinOp::Sub,
                _ => break,
            };
            self.advance();
            let right = self.parse_mul();
            left = Expr::Binary {
                op,
                lhs: Box::new(left),
                rhs: Box::new(right),
            };
        }
        left
    }

    // mul := unary (("*" | "/" | "%") unary)*
    fn parse_mul(&mut self) -> Expr {
        let mut left = self.parse_unary();
        loop {
            let op = match self.peek() {
                Token::Star => BinOp::Mul,
                Token::Slash => BinOp::Div,
                Token::Percent => BinOp::Mod,
                _ => break,
            };
            self.advance();
            let right = self.parse_unary();
            left = Expr::Binary {
                op,
                lhs: Box::new(left),
                rhs: Box::new(right),
            };
        }
        left
    }

    // unary := ("!" | "-" | "~") unary | postfix
    fn parse_unary(&mut self) -> Expr {
        let op = match self.peek() {
            Token::Bang => UnOp::Not,
            Token::Minus => UnOp::Neg,
            Token::Tilde => UnOp::BitNot,
            _ => return self.parse_postfix(),
        };
        self.advance();
        let operand = self.parse_unary();
        Expr::Unary { op, operand: Box::new(operand) }
    }

    // postfix := primary ("." IDENT ("(" args ")")? | "[" expr "]")*
    // `base.nome` é campo; `base.nome(args)` é método; `base[i]` é índice.
    fn parse_postfix(&mut self) -> Expr {
        let mut e = self.parse_primary();
        loop {
            if *self.peek() == Token::Dot {
                self.advance();
                let field = self.parse_ident();
                // o '(' precisa estar na mesma linha (mesma regra das chamadas)
                if *self.peek() == Token::LParen && !self.newline_before() {
                    let args = self.parse_call_args();
                    e = Expr::MethodCall { base: Box::new(e), method: field, args };
                } else {
                    e = Expr::Field { base: Box::new(e), field };
                }
            } else if *self.peek() == Token::LBracket && !self.newline_before() {
                // `base[i]` — o '[' precisa estar na mesma linha, senão um
                // `[...]` na linha de baixo seria um array literal novo
                self.advance();
                let index = self.parse_expr();
                self.expect(Token::RBracket);
                e = Expr::Index { base: Box::new(e), index: Box::new(index) };
            } else {
                break;
            }
        }
        e
    }

    // primary := INT | "(" expr ")" | IDENT | IDENT "(" args ")"
    //          | "try" primary | "spawn" IDENT "(" args ")"
    fn parse_primary(&mut self) -> Expr {
        match self.advance() {
            Token::Int(n) => Expr::Int(n),
            Token::Float(f) => Expr::Float(f),
            Token::True => Expr::Bool(true),
            Token::False => Expr::Bool(false),
            Token::Str(s) => Expr::Str(s),
            Token::Template(parts) => {
                let tpl_span = self.last_span;
                let mut tpl = Vec::new();
                for p in parts {
                    match p {
                        TplPart::Lit(s) => tpl.push(TemplatePart::Lit(s)),
                        TplPart::Expr(mut toks) => {
                            // cada `${...}` é parseado por um sub-parser;
                            // as lambdas içadas continuam no parser de fora.
                            // (os erros apontam para o template inteiro)
                            toks.push(Token::Eof);
                            let spans = vec![tpl_span; toks.len()];
                            let mut sub = Parser::new(toks, spans, self.module_id, self.src);
                            sub.lambdas = std::mem::take(&mut self.lambdas);
                            let e = sub.parse_expr();
                            if *sub.peek() != Token::Eof {
                                sub.fail_here("extra content in template interpolation", None);
                            }
                            self.lambdas = sub.lambdas;
                            tpl.push(TemplatePart::Expr(e));
                        }
                    }
                }
                Expr::Template(tpl)
            }
            Token::LParen => {
                // arrow function? `()` vazio ou `(nome: tipo, ...)`
                let is_lambda = *self.peek() == Token::RParen
                    || (matches!(self.peek(), Token::Ident(_))
                        && *self.peek_ahead(1) == Token::Colon);
                if is_lambda {
                    return self.parse_lambda();
                }
                let e = self.parse_expr();
                self.expect(Token::RParen);
                e
            }
            // `{ ... }`: chave string (ou vazio) → map literal; chave
            // identificadora → struct literal. `{ "a": 1 }` vs `{ a: 1 }`.
            Token::LBrace => {
                let is_map =
                    matches!(self.peek(), Token::Str(_)) || *self.peek() == Token::RBrace;
                if is_map {
                    let mut entries = Vec::new();
                    while *self.peek() != Token::RBrace {
                        let key = match self.advance() {
                            Token::Str(s) => s,
                            t => self.fail_last(
                                &format!("a map key must be a string, found {}", t.describe()),
                                Some("use a string key: { \"key\": value }"),
                            ),
                        };
                        self.expect(Token::Colon);
                        let value = self.parse_expr();
                        entries.push((key, value));
                        if *self.peek() == Token::Comma {
                            self.advance();
                        }
                    }
                    self.expect(Token::RBrace);
                    Expr::MapLit(entries)
                } else {
                    let mut fields = Vec::new();
                    while *self.peek() != Token::RBrace {
                        let fname = self.parse_ident();
                        self.expect(Token::Colon);
                        let value = self.parse_expr();
                        fields.push((fname, value));
                        if *self.peek() == Token::Comma {
                            self.advance();
                        }
                    }
                    self.expect(Token::RBrace);
                    Expr::StructLit { fields }
                }
            }
            // array literal: `[a, b, c]` ou `[]`
            Token::LBracket => {
                let mut elems = Vec::new();
                while *self.peek() != Token::RBracket {
                    elems.push(self.parse_expr());
                    if *self.peek() == Token::Comma {
                        self.advance();
                    }
                }
                self.expect(Token::RBracket);
                Expr::ArrayLit(elems)
            }
            Token::Try => Expr::Try(Box::new(self.parse_postfix())),
            Token::Await => Expr::Await(Box::new(self.parse_postfix())),
            // o token `match` já foi consumido pelo advance() acima
            Token::Match => self.parse_match(),
            Token::Spawn => {
                let first = self.parse_ident();
                // `spawn obj.metodo(args)`: o método roda na thread com `obj`
                // como `this`. `spawn f(args)`: função de topo.
                if *self.peek() == Token::Dot {
                    self.advance();
                    let method = self.parse_ident();
                    let args = self.parse_call_args();
                    Expr::Spawn {
                        name: method,
                        receiver: Some(Box::new(Expr::Var(first))),
                        args,
                    }
                } else {
                    let args = self.parse_call_args();
                    Expr::Spawn { name: first, receiver: None, args }
                }
            }
            // `new Classe(args)` — instanciação. `new Box<i64>(...)` reifica os
            // argumentos de tipo (usados na inferência; o codegen os ignora).
            Token::New => {
                let class = self.parse_ident();
                let type_args = if *self.peek() == Token::Lt {
                    self.parse_type_arg_list()
                } else {
                    Vec::new()
                };
                let args = self.parse_call_args();
                Expr::New { class, type_args, args }
            }
            // `super(args)` ou `super.metodo(args)`
            Token::Super => {
                if *self.peek() == Token::Dot {
                    self.advance();
                    let method = self.parse_ident();
                    let args = self.parse_call_args();
                    Expr::SuperCall { method: Some(method), args }
                } else {
                    let args = self.parse_call_args();
                    Expr::SuperCall { method: None, args }
                }
            }
            Token::Ident(name) => {
                // o '(' da chamada precisa estar na mesma linha do nome,
                // senão `foo` + `(expr)` na linha seguinte virariam chamada
                if *self.peek() == Token::LParen && !self.newline_before() {
                    let args = self.parse_call_args();
                    Expr::Call { name, type_args: Vec::new(), args }
                } else if *self.peek() == Token::Lt && self.is_generic_call_ahead() {
                    // chamada com argumentos de tipo: `f<i64>(args)`. O lookahead
                    // garante que é `< tipos > (` e não uma comparação `f < x`.
                    let type_args = self.parse_type_arg_list();
                    let args = self.parse_call_args();
                    Expr::Call { name, type_args, args }
                } else {
                    Expr::Var(name)
                }
            }
            t => self.fail_last(
                &format!("unexpected token in an expression: {}", t.describe()),
                None,
            ),
        }
    }

    /// Arrow function (o `(` já foi consumido): `(x: i64) => expr`
    /// ou `(x: i64): i64 => { ... }`. Sem captura: o corpo só enxerga os
    /// próprios parâmetros. É içada para uma função de topo `__lambda_N`.
    fn parse_lambda(&mut self) -> Expr {
        let mut params = Vec::new();
        let mut seen_default = false;
        while *self.peek() != Token::RParen {
            params.push(self.parse_param(&mut seen_default, false));
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RParen);

        // tipo de retorno opcional; sem anotação, assume i64
        let ret_type = if *self.peek() == Token::Colon {
            self.advance();
            self.parse_type()
        } else {
            Type::I64
        };

        self.expect(Token::FatArrow);

        // corpo: bloco ou expressão única (vira `return expr;`)
        let body = if *self.peek() == Token::LBrace {
            self.parse_block()
        } else {
            let lo = self.here_lo();
            let kind = StmtKind::Return(Some(self.parse_expr()));
            vec![Stmt { kind, span: self.span_from(lo) }]
        };

        let name = format!("__lambda_{}_{}", self.module_id, self.lambdas.len());
        // variáveis livres do corpo: candidatas a captura (filtradas depois)
        let captures = lambda_free_vars(&params, &body);
        let lspan = body.first().map(|s| s.span).unwrap_or(Span::DUMMY);
        self.lambdas.push(Function {
            name: name.clone(),
            is_async: false,
            type_params: Vec::new(),
            params,
            ret_type,
            fallible: false,
            external: false,
            body,
            span: lspan,
            ret_inferred: false,
        });
        // a expressão avalia para a closure (no codegen, um "box" fn+capturas)
        Expr::Closure { name, captures }
    }

    /// Argumentos de chamada: `( expr, expr, ... )`.
    fn parse_call_args(&mut self) -> Vec<Expr> {
        self.expect(Token::LParen);
        let mut args = Vec::new();
        while *self.peek() != Token::RParen {
            args.push(self.parse_expr());
            if *self.peek() == Token::Comma {
                self.advance();
            }
        }
        self.expect(Token::RParen);
        args
    }
}

pub fn parse(lexed: Lexed, module_id: usize, src: &Source) -> Program {
    Parser::new(lexed.tokens, lexed.spans, module_id, src).parse_program()
}
