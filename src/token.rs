//! Tokens produzidos pelo lexer.

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // palavras-chave (sintaxe TypeScript-like)
    Function,
    Declare,
    Import,
    From,
    Const,
    Let,
    Return,
    If,
    Else,
    While,
    For,
    Break,
    Continue,
    Match,
    Type,
    Try,
    Catch,
    Fail,
    Spawn,
    Class,
    Extends,
    Interface,
    Implements,
    Enum,
    New,
    Static,
    Private,
    Super,
    True,
    False,
    Defer,
    Async,
    Await,

    // identificadores e literais
    Ident(String),
    Int(i64),
    /// Literal de ponto flutuante: `3.14`, `1.0`, `2e10`.
    Float(f64),
    Str(String),
    /// Template literal: `texto ${expr} texto` — as interpolações chegam
    /// já lexadas; o parser monta as expressões.
    Template(Vec<TplPart>),

    // pontuação
    LParen,    // (
    RParen,    // )
    LBrace,    // {
    RBrace,    // }
    LBracket,  // [
    RBracket,  // ]
    Colon,     // :
    Semicolon, // ;
    Comma,     // ,
    Dot,       // .
    DotDot,    // ..  (faixa em padrão de match: `1..10`)
    DotDotDot, // ...  (parâmetro variádico: `...args: T[]`)
    Arrow,     // ->
    FatArrow,  // =>  (arrow functions e tipos de função)
    Eq,        // =
    Bang,      // !  (marca função falível)

    // operadores
    Plus,  // +
    Minus, // -
    Star,  // *
    Slash, // /
    Percent, // %
    EqEq,  // ==
    Neq,   // !=
    Lt,    // <
    Gt,    // >
    Le,    // <=
    Ge,    // >=
    AmpAmp,   // &&
    PipePipe, // ||
    Amp,      // &  (bitwise and)
    Pipe,     // |  (bitwise or)
    Caret,    // ^  (bitwise xor)
    Tilde,    // ~  (bitwise not)
    Shl,      // <<
    Shr,      // >>
    // atribuição composta: +=, -=, *=, /=, %=
    PlusEq,
    MinusEq,
    StarEq,
    SlashEq,
    PercentEq,
    // incremento/decremento: ++, --
    PlusPlus,
    MinusMinus,

    /// Quebra de linha — o parser a trata como terminador de statement
    /// (o ';' é opcional) e a ignora onde um statement não pode terminar.
    Newline,

    Eof,
}

impl Token {
    /// Descrição amigável para mensagens de erro ("esperava ')', encontrei
    /// o identificador 'foo'"), no lugar do Debug do enum.
    pub fn describe(&self) -> String {
        match self {
            Token::Function => "'function'".into(),
            Token::Declare => "'declare'".into(),
            Token::Import => "'import'".into(),
            Token::From => "'from'".into(),
            Token::Const => "'const'".into(),
            Token::Let => "'let'".into(),
            Token::Return => "'return'".into(),
            Token::If => "'if'".into(),
            Token::Else => "'else'".into(),
            Token::While => "'while'".into(),
            Token::For => "'for'".into(),
            Token::Break => "'break'".into(),
            Token::Continue => "'continue'".into(),
            Token::Match => "'match'".into(),
            Token::Type => "'type'".into(),
            Token::Try => "'try'".into(),
            Token::Catch => "'catch'".into(),
            Token::Fail => "'fail'".into(),
            Token::Spawn => "'spawn'".into(),
            Token::Class => "'class'".into(),
            Token::Extends => "'extends'".into(),
            Token::Interface => "'interface'".into(),
            Token::Enum => "'enum'".into(),
            Token::Implements => "'implements'".into(),
            Token::New => "'new'".into(),
            Token::Static => "'static'".into(),
            Token::Private => "'private'".into(),
            Token::Super => "'super'".into(),
            Token::True => "'true'".into(),
            Token::False => "'false'".into(),
            Token::Defer => "'defer'".into(),
            Token::Async => "'async'".into(),
            Token::Await => "'await'".into(),
            Token::Ident(s) => format!("identifier '{}'", s),
            Token::Int(n) => format!("number {}", n),
            Token::Float(f) => format!("number {}", f),
            Token::Str(s) => format!("string \"{}\"", s),
            Token::Template(_) => "a template literal".into(),
            Token::LParen => "'('".into(),
            Token::RParen => "')'".into(),
            Token::LBrace => "'{'".into(),
            Token::RBrace => "'}'".into(),
            Token::LBracket => "'['".into(),
            Token::RBracket => "']'".into(),
            Token::Colon => "':'".into(),
            Token::Semicolon => "';'".into(),
            Token::Comma => "','".into(),
            Token::Dot => "'.'".into(),
            Token::DotDot => "'..'".into(),
            Token::DotDotDot => "'...'".into(),
            Token::Arrow => "'->'".into(),
            Token::FatArrow => "'=>'".into(),
            Token::Eq => "'='".into(),
            Token::Bang => "'!'".into(),
            Token::Plus => "'+'".into(),
            Token::Minus => "'-'".into(),
            Token::Star => "'*'".into(),
            Token::Slash => "'/'".into(),
            Token::Percent => "'%'".into(),
            Token::EqEq => "'=='".into(),
            Token::Neq => "'!='".into(),
            Token::Lt => "'<'".into(),
            Token::Gt => "'>'".into(),
            Token::Le => "'<='".into(),
            Token::Ge => "'>='".into(),
            Token::AmpAmp => "'&&'".into(),
            Token::PipePipe => "'||'".into(),
            Token::Amp => "'&'".into(),
            Token::Pipe => "'|'".into(),
            Token::Caret => "'^'".into(),
            Token::Tilde => "'~'".into(),
            Token::Shl => "'<<'".into(),
            Token::Shr => "'>>'".into(),
            Token::PlusEq => "'+='".into(),
            Token::MinusEq => "'-='".into(),
            Token::StarEq => "'*='".into(),
            Token::SlashEq => "'/='".into(),
            Token::PercentEq => "'%='".into(),
            Token::PlusPlus => "'++'".into(),
            Token::MinusMinus => "'--'".into(),
            Token::Newline => "a newline".into(),
            Token::Eof => "end of file".into(),
        }
    }
}

/// Um pedaço de template literal: texto fixo ou os tokens de um `${...}`.
#[derive(Debug, Clone, PartialEq)]
pub enum TplPart {
    Lit(String),
    Expr(Vec<Token>),
}
