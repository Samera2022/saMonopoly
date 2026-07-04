use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Script engine kinds
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScriptEngineKind {
    Lua,
    JavaScript,
    Wasm,
    Simple,
}

// ---------------------------------------------------------------------------
// Enhanced ScriptHost trait
// ---------------------------------------------------------------------------

pub trait ScriptHost {
    /// Run a full script in the given language.
    fn run(&self, kind: ScriptEngineKind, source: &str) -> Result<(), String>;

    /// Evaluate a single expression (with optional variable context) and return
    /// an integer result.
    fn eval_expression(&self, expr: &str, context: &HashMap<String, i64>) -> Result<i64, String>;

    /// Register a named function that can be called from scripts.
    fn register_function(&mut self, name: &str, func: Box<dyn Fn(&[i64]) -> i64>);
}

// ---------------------------------------------------------------------------
// DisabledScriptHost – stub for when scripting is turned off
// ---------------------------------------------------------------------------

pub struct DisabledScriptHost;

impl ScriptHost for DisabledScriptHost {
    fn run(&self, _kind: ScriptEngineKind, _source: &str) -> Result<(), String> {
        Err("script execution is not enabled yet".to_string())
    }

    fn eval_expression(
        &self,
        _expr: &str,
        _context: &HashMap<String, i64>,
    ) -> Result<i64, String> {
        Err("script execution is not enabled yet".to_string())
    }

    fn register_function(&mut self, _name: &str, _func: Box<dyn Fn(&[i64]) -> i64>) {
        // no-op
    }
}

// ---------------------------------------------------------------------------
// SimpleScriptHost – pure‑Rust evaluator that delegates to
//                    SimpleExpressionEvaluator
// ---------------------------------------------------------------------------

pub struct SimpleScriptHost {
    functions: HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
}

impl SimpleScriptHost {
    pub fn new() -> Self {
        Self {
            functions: HashMap::new(),
        }
    }
}

impl ScriptHost for SimpleScriptHost {
    fn run(&self, _kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        // For the simple host we just evaluate the source as an expression.
        let ctx = HashMap::new();
        SimpleExpressionEvaluator::evaluate(source, &ctx, &self.functions)?;
        Ok(())
    }

    fn eval_expression(
        &self,
        expr: &str,
        context: &HashMap<String, i64>,
    ) -> Result<i64, String> {
        SimpleExpressionEvaluator::evaluate(expr, context, &self.functions)
    }

    fn register_function(&mut self, name: &str, func: Box<dyn Fn(&[i64]) -> i64>) {
        self.functions.insert(name.to_string(), func);
    }
}

impl Default for SimpleScriptHost {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// JsScriptHost – pure‑Rust JavaScript‑flavored expression evaluator
//
// Supports a subset of JavaScript expression syntax:
//   - Arithmetic: +, -, *, /
//   - Comparisons: >, <, ==, >=, <=
//   - Ternary: cond ? a : b
//   - Function calls: name(args)
//   - Variable references: name or ${name}
//   - Comments: // line and /* block */
// ---------------------------------------------------------------------------

pub struct JsScriptHost {
    functions: HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
}

impl JsScriptHost {
    pub fn new() -> Self {
        Self {
            functions: HashMap::new(),
        }
    }
}

impl ScriptHost for JsScriptHost {
    fn run(&self, _kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        // Strip comments, then evaluate as a JS expression sequence.
        let cleaned = Self::strip_js_comments(source);
        // Support statement sequences separated by semicolons or newlines.
        let statements: Vec<&str> = cleaned
            .split([';', '\n'])
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();

        if statements.is_empty() {
            return Ok(());
        }

        let ctx = HashMap::new();
        // Evaluate all statements; only the last statement's result matters.
        for stmt in &statements {
            if *stmt == "return" {
                continue;
            }
            let _ = JsExpressionEvaluator::evaluate(stmt, &ctx, &self.functions)?;
        }
        Ok(())
    }

    fn eval_expression(
        &self,
        expr: &str,
        context: &HashMap<String, i64>,
    ) -> Result<i64, String> {
        let cleaned = Self::strip_js_comments(expr);
        JsExpressionEvaluator::evaluate(&cleaned, context, &self.functions)
    }

    fn register_function(&mut self, name: &str, func: Box<dyn Fn(&[i64]) -> i64>) {
        self.functions.insert(name.to_string(), func);
    }
}

impl JsScriptHost {
    /// Strip JavaScript‑style comments from source code.
    fn strip_js_comments(source: &str) -> String {
        let mut result = String::with_capacity(source.len());
        let chars: Vec<char> = source.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            if i + 1 < chars.len() {
                if chars[i] == '/' && chars[i + 1] == '/' {
                    // Line comment: skip to end of line
                    i += 2;
                    while i < chars.len() && chars[i] != '\n' {
                        i += 1;
                    }
                    continue;
                }
                if chars[i] == '/' && chars[i + 1] == '*' {
                    // Block comment: skip to */
                    i += 2;
                    while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                        i += 1;
                    }
                    i += 2; // skip */
                    continue;
                }
            }
            result.push(chars[i]);
            i += 1;
        }
        result
    }
}

impl Default for JsScriptHost {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// WasmScriptHost – stub for WASM-based scripting
// ---------------------------------------------------------------------------

#[derive(Default)]
pub struct WasmScriptHost;

impl WasmScriptHost {
    pub fn new() -> Self {
        Self
    }
}

impl ScriptHost for WasmScriptHost {
    fn run(&self, _kind: ScriptEngineKind, source: &str) -> Result<(), String> {
        // WASM modules are not executed inline; this is a placeholder
        // for when WASM runtime integration is added.
        if source.is_empty() {
            return Err("empty WASM module".to_string());
        }
        Err("WASM script execution requires a WASM runtime (wasmtime/wasmer)".to_string())
    }

    fn eval_expression(
        &self,
        _expr: &str,
        _context: &HashMap<String, i64>,
    ) -> Result<i64, String> {
        Err("WASM does not support inline expression evaluation".to_string())
    }

    fn register_function(&mut self, _name: &str, _func: Box<dyn Fn(&[i64]) -> i64>) {
        // Would register host functions for WASM imports
    }
}

// ---------------------------------------------------------------------------
// ScriptSandbox (kept for backward compatibility)
// ---------------------------------------------------------------------------

pub struct ScriptSandbox;

impl ScriptSandbox {
    pub fn execute(
        host: &dyn ScriptHost,
        kind: ScriptEngineKind,
        source: &str,
    ) -> Result<(), String> {
        host.run(kind, source)
    }
}

// ===========================================================================
// JsExpressionEvaluator – pure‑Rust JS‑flavored expression parser
// ===========================================================================

/// A JavaScript‑style expression evaluator that does **not** depend on any
/// external JS engine. It supports:
///
/// - Integer literals (decimal)
/// - Variable references via bare identifiers or `${name}`
/// - Arithmetic: `+`, `-`, `*`, `/` (with correct precedence)
/// - Parenthesised sub‑expressions
/// - Comparisons: `>`, `<`, `==`, `>=`, `<=` (returns 1 for true, 0 for false)
/// - Ternary conditional: `cond ? thenExpr : elseExpr`
/// - Function calls: `name(arg1, arg2, ...)`
pub struct JsExpressionEvaluator;

// ---- tokens ---------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum JsToken {
    Number(i64),
    Ident(String),
    Plus,
    Minus,
    Star,
    Slash,
    LParen,
    RParen,
    Greater,
    Less,
    EqualEqual,
    GreaterEqual,
    LessEqual,
    Comma,
    Question,
    Colon,
    DollarBrace, // ${
    Eof,
}

// ---- tokeniser ------------------------------------------------------------

struct JsLexer {
    chars: Vec<char>,
    pos: usize,
}

impl JsLexer {
    fn new(input: &str) -> Self {
        Self {
            chars: input.chars().collect(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.chars.get(self.pos).copied();
        self.pos += 1;
        ch
    }

    fn skip_whitespace(&mut self) {
        while let Some(ch) = self.peek() {
            if ch.is_ascii_whitespace() {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn next_token(&mut self) -> JsToken {
        self.skip_whitespace();
        let Some(ch) = self.peek() else {
            return JsToken::Eof;
        };

        // Number
        if ch.is_ascii_digit() {
            let mut num = 0i64;
            while let Some(d) = self.peek() {
                if d.is_ascii_digit() {
                    num = num * 10 + (d as i64 - '0' as i64);
                    self.advance();
                } else {
                    break;
                }
            }
            return JsToken::Number(num);
        }

        // Handle $ specially: ${...} for variable references
        if ch == '$' {
            self.advance();
            if self.peek() == Some('{') {
                self.advance(); // consume {
                return JsToken::DollarBrace;
            }
            // standalone $ — treat as an identifier
            let mut ident = String::from("$");
            while let Some(c) = self.peek() {
                if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
                    ident.push(c);
                    self.advance();
                } else {
                    break;
                }
            }
            return JsToken::Ident(ident);
        }

        // Identifiers and keywords
        if ch.is_ascii_alphabetic() || ch == '_' {
            let mut ident = String::new();
            while let Some(c) = self.peek() {
                if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
                    ident.push(c);
                    self.advance();
                } else {
                    break;
                }
            }
            return JsToken::Ident(ident);
        }

        // Operators and punctuation
        match ch {
            '+' => {
                self.advance();
                JsToken::Plus
            }
            '-' => {
                self.advance();
                JsToken::Minus
            }
            '*' => {
                self.advance();
                JsToken::Star
            }
            '/' => {
                self.advance();
                JsToken::Slash
            }
            '(' => {
                self.advance();
                JsToken::LParen
            }
            ')' => {
                self.advance();
                JsToken::RParen
            }
            ',' => {
                self.advance();
                JsToken::Comma
            }
            '?' => {
                self.advance();
                JsToken::Question
            }
            ':' => {
                self.advance();
                JsToken::Colon
            }
            '>' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    JsToken::GreaterEqual
                } else {
                    JsToken::Greater
                }
            }
            '<' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    JsToken::LessEqual
                } else {
                    JsToken::Less
                }
            }
            '=' => {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    JsToken::EqualEqual
                } else {
                    JsToken::Eof
                }
            }
            '}' => {
                // Skip closing brace (from ${...} syntax) and continue
                self.advance();
                self.next_token()
            }
            _ => JsToken::Eof,
        }
    }
}

// ---- recursive‑descent parser --------------------------------------------

struct JsParser<'a> {
    lexer: JsLexer,
    curr: JsToken,
    vars: &'a HashMap<String, i64>,
    funcs: &'a HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
}

impl<'a> JsParser<'a> {
    fn new(
        input: &str,
        vars: &'a HashMap<String, i64>,
        funcs: &'a HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
    ) -> Self {
        let mut lexer = JsLexer::new(input);
        let curr = lexer.next_token();
        Self {
            lexer,
            curr,
            vars,
            funcs,
        }
    }

    fn advance(&mut self) {
        self.curr = self.lexer.next_token();
    }

    // ---- public entry point -----------------------------------------------

    fn parse(&mut self) -> Result<i64, String> {
        let val = self.parse_ternary()?;
        if !matches!(self.curr, JsToken::Eof) {
            return Err(format!("unexpected token {:?} after expression", self.curr));
        }
        Ok(val)
    }

    // ---- precedence hierarchy ---------------------------------------------

    // ternary ::= comparison ( "?" ternary ":" ternary )?
    fn parse_ternary(&mut self) -> Result<i64, String> {
        let cond = self.parse_comparison()?;
        if self.curr == JsToken::Question {
            self.advance(); // consume '?'
            let true_val = self.parse_ternary()?;
            if self.curr != JsToken::Colon {
                return Err(format!("expected ':', got {:?}", self.curr));
            }
            self.advance(); // consume ':'
            let false_val = self.parse_ternary()?;
            return Ok(if cond != 0 { true_val } else { false_val });
        }
        Ok(cond)
    }

    // comparison ::= addition ( ( ">" | "<" | "==" | ">=" | "<=" ) addition )*
    fn parse_comparison(&mut self) -> Result<i64, String> {
        let mut left = self.parse_addition()?;
        loop {
            match &self.curr {
                JsToken::Greater => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left > right { 1 } else { 0 };
                }
                JsToken::Less => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left < right { 1 } else { 0 };
                }
                JsToken::EqualEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left == right { 1 } else { 0 };
                }
                JsToken::GreaterEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left >= right { 1 } else { 0 };
                }
                JsToken::LessEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left <= right { 1 } else { 0 };
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // addition ::= term ( ( "+" | "-" ) term )*
    fn parse_addition(&mut self) -> Result<i64, String> {
        let mut left = self.parse_term()?;
        loop {
            match &self.curr {
                JsToken::Plus => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = left.wrapping_add(right);
                }
                JsToken::Minus => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = left.wrapping_sub(right);
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // term ::= factor ( ( "*" | "/" ) factor )*
    fn parse_term(&mut self) -> Result<i64, String> {
        let mut left = self.parse_factor()?;
        loop {
            match &self.curr {
                JsToken::Star => {
                    self.advance();
                    let right = self.parse_factor()?;
                    left = left.wrapping_mul(right);
                }
                JsToken::Slash => {
                    self.advance();
                    let right = self.parse_factor()?;
                    if right == 0 {
                        return Err("division by zero".to_string());
                    }
                    left = left.wrapping_div(right);
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // factor ::= number
    //          | "(" expr ")"
    //          | ident "(" args? ")"
    //          | ident
    //          | "${" ident "}"
    //          | "-" factor   (unary minus)
    fn parse_factor(&mut self) -> Result<i64, String> {
        match &self.curr.clone() {
            JsToken::Number(n) => {
                let val = *n;
                self.advance();
                Ok(val)
            }
            JsToken::LParen => {
                self.advance(); // consume '('
                let val = self.parse_ternary()?;
                if self.curr != JsToken::RParen {
                    return Err(format!("expected ')', got {:?}", self.curr));
                }
                self.advance(); // consume ')'
                Ok(val)
            }
            JsToken::DollarBrace => {
                // ${ident} variable reference
                self.advance(); // consume DollarBrace, get ident
                if let JsToken::Ident(name) = &self.curr.clone() {
                    let name = name.clone();
                    self.advance(); // consume ident
                    if let Some(&val) = self.vars.get(&name) {
                        Ok(val)
                    } else {
                        Err(format!("unknown variable '{}'", name))
                    }
                } else {
                    Err(format!(
                        "expected identifier after '${{', got {:?}",
                        self.curr
                    ))
                }
            }
            JsToken::Ident(name) => {
                let name = name.clone();
                self.advance(); // consume ident
                if self.curr == JsToken::LParen {
                    // function call
                    self.advance(); // consume '('
                    let mut args = Vec::new();
                    if self.curr != JsToken::RParen {
                        args.push(self.parse_comparison()?);
                        while self.curr == JsToken::Comma {
                            self.advance(); // consume ','
                            args.push(self.parse_comparison()?);
                        }
                    }
                    if self.curr != JsToken::RParen {
                        return Err(format!(
                            "expected ')' in function call, got {:?}",
                            self.curr
                        ));
                    }
                    self.advance(); // consume ')'
                    if let Some(func) = self.funcs.get(&name) {
                        Ok(func(&args))
                    } else {
                        Err(format!("unknown function '{}'", name))
                    }
                } else {
                    // Plain identifier — variable lookup
                    if let Some(&val) = self.vars.get(&name) {
                        Ok(val)
                    } else {
                        Err(format!("unknown variable '{}'", name))
                    }
                }
            }
            JsToken::Minus => {
                // Unary minus
                self.advance();
                let val = self.parse_factor()?;
                Ok(val.wrapping_neg())
            }
            _ => Err(format!("unexpected token {:?}", self.curr)),
        }
    }
}

impl JsExpressionEvaluator {
    /// Evaluate a JavaScript‑flavored expression string with the given
    /// variable context and registered functions.
    pub fn evaluate(
        expr: &str,
        vars: &HashMap<String, i64>,
        funcs: &HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
    ) -> Result<i64, String> {
        let mut parser = JsParser::new(expr, vars, funcs);
        parser.parse()
    }

    /// Convenience variant without custom functions.
    pub fn evaluate_simple(expr: &str, vars: &HashMap<String, i64>) -> Result<i64, String> {
        let funcs: HashMap<String, Box<dyn Fn(&[i64]) -> i64>> = HashMap::new();
        Self::evaluate(expr, vars, &funcs)
    }
}

// ===========================================================================
// SimpleExpressionEvaluator – pure‑Rust recursive‑descent parser
// ===========================================================================

/// A minimal expression evaluator that does **not** depend on any external
/// scripting engine.  It supports:
///
/// - Integer literals
/// - Variable references via `{name}` placeholders
/// - Arithmetic: `+`, `-`, `*`, `/` (with correct precedence)
/// - Parenthesised sub‑expressions
/// - Comparisons: `>`, `<`, `==`, `>=`, `<=` (returns 1 for true, 0 for false)
/// - Ternary‑style conditional: `if a then b else c`
/// - Function calls: `name(arg1, arg2, ...)`
pub struct SimpleExpressionEvaluator;

// ---- tokens ---------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Number(i64),
    Ident(String),
    Plus,
    Minus,
    Star,
    Slash,
    LParen,
    RParen,
    Greater,
    Less,
    EqualEqual,
    GreaterEqual,
    LessEqual,
    Comma,
    If,
    Then,
    Else,
    Eof,
}

// ---- tokeniser ------------------------------------------------------------

struct Lexer {
    chars: Vec<char>,
    pos: usize,
}

impl Lexer {
    fn new(input: &str) -> Self {
        Self {
            chars: input.chars().collect(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.chars.get(self.pos).copied();
        self.pos += 1;
        ch
    }

    fn skip_whitespace(&mut self) {
        while let Some(ch) = self.peek() {
            if ch.is_ascii_whitespace() {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn next_token(&mut self) -> Token {
        self.skip_whitespace();
        let Some(ch) = self.peek() else {
            return Token::Eof;
        };

        // Number
        if ch.is_ascii_digit()
            || (ch == '-'
                && {
                    let next = self.chars.get(self.pos + 1).copied();
                    next.is_some_and(|n| n.is_ascii_digit())
                })
        {
            let mut sign = 1i64;
            if ch == '-' {
                sign = -1;
                self.advance();
            }
            let mut num = 0i64;
            while let Some(d) = self.peek() {
                if d.is_ascii_digit() {
                    num = num * 10 + (d as i64 - '0' as i64);
                    self.advance();
                } else {
                    break;
                }
            }
            return Token::Number(sign * num);
        }

        // Identifiers and keywords
        if ch.is_ascii_alphabetic() || ch == '_' {
            let mut ident = String::new();
            while let Some(c) = self.peek() {
                if c.is_ascii_alphanumeric() || c == '_' {
                    ident.push(c);
                    self.advance();
                } else {
                    break;
                }
            }
            match ident.as_str() {
                "if" => Token::If,
                "then" => Token::Then,
                "else" => Token::Else,
                _ => Token::Ident(ident),
            }
        } else {
            // Single/multi‑character operators
            match ch {
                '+' => {
                    self.advance();
                    Token::Plus
                }
                '-' => {
                    self.advance();
                    Token::Minus
                }
                '*' => {
                    self.advance();
                    Token::Star
                }
                '/' => {
                    self.advance();
                    Token::Slash
                }
                '(' => {
                    self.advance();
                    Token::LParen
                }
                ')' => {
                    self.advance();
                    Token::RParen
                }
                ',' => {
                    self.advance();
                    Token::Comma
                }
                '>' => {
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        Token::GreaterEqual
                    } else {
                        Token::Greater
                    }
                }
                '<' => {
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        Token::LessEqual
                    } else {
                        Token::Less
                    }
                }
                '=' => {
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        Token::EqualEqual
                    } else {
                        Token::Eof
                    }
                }
                _ => Token::Eof,
            }
        }
    }
}

// ---- recursive‑descent parser --------------------------------------------

struct Parser<'a> {
    lexer: Lexer,
    curr: Token,
    vars: &'a HashMap<String, i64>,
    funcs: &'a HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
}

impl<'a> Parser<'a> {
    fn new(
        input: &str,
        vars: &'a HashMap<String, i64>,
        funcs: &'a HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
    ) -> Self {
        let mut lexer = Lexer::new(input);
        let curr = lexer.next_token();
        Self {
            lexer,
            curr,
            vars,
            funcs,
        }
    }

    fn advance(&mut self) {
        self.curr = self.lexer.next_token();
    }

    // ---- public entry point -----------------------------------------------

    fn parse(&mut self) -> Result<i64, String> {
        let val = self.parse_conditional()?;
        if !matches!(self.curr, Token::Eof) {
            return Err(format!("unexpected token {:?} after expression", self.curr));
        }
        Ok(val)
    }

    // ---- precedence hierarchy ---------------------------------------------

    fn parse_conditional(&mut self) -> Result<i64, String> {
        // Check if this starts with an 'if' keyword
        if self.curr == Token::If {
            // if comparison then conditional else conditional
            self.advance(); // consume 'if'
            let cond = self.parse_comparison()?;
            if self.curr != Token::Then {
                return Err(format!("expected 'then', got {:?}", self.curr));
            }
            self.advance(); // consume 'then'
            let true_val = self.parse_conditional()?;
            if self.curr != Token::Else {
                return Err(format!("expected 'else', got {:?}", self.curr));
            }
            self.advance(); // consume 'else'
            let false_val = self.parse_conditional()?;
            return Ok(if cond != 0 { true_val } else { false_val });
        }
        self.parse_comparison()
    }

    // comparison ::= addition ( ( ">" | "<" | "==" | ">=" | "<=" ) addition )*
    fn parse_comparison(&mut self) -> Result<i64, String> {
        let mut left = self.parse_addition()?;
        loop {
            match &self.curr {
                Token::Greater => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left > right { 1 } else { 0 };
                }
                Token::Less => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left < right { 1 } else { 0 };
                }
                Token::EqualEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left == right { 1 } else { 0 };
                }
                Token::GreaterEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left >= right { 1 } else { 0 };
                }
                Token::LessEqual => {
                    self.advance();
                    let right = self.parse_addition()?;
                    left = if left <= right { 1 } else { 0 };
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // addition ::= term ( ( "+" | "-" ) term )*
    fn parse_addition(&mut self) -> Result<i64, String> {
        let mut left = self.parse_term()?;
        loop {
            match &self.curr {
                Token::Plus => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = left.wrapping_add(right);
                }
                Token::Minus => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = left.wrapping_sub(right);
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // term ::= factor ( ( "*" | "/" ) factor )*
    fn parse_term(&mut self) -> Result<i64, String> {
        let mut left = self.parse_factor()?;
        loop {
            match &self.curr {
                Token::Star => {
                    self.advance();
                    let right = self.parse_factor()?;
                    left = left.wrapping_mul(right);
                }
                Token::Slash => {
                    self.advance();
                    let right = self.parse_factor()?;
                    if right == 0 {
                        return Err("division by zero".to_string());
                    }
                    left = left.wrapping_div(right);
                }
                _ => break,
            }
        }
        Ok(left)
    }

    // factor ::= number
    //          | "(" expr ")"
    //          | ident "(" args? ")"
    //          | ident
    //          | "{" ident "}"   (variable reference)
    fn parse_factor(&mut self) -> Result<i64, String> {
        match &self.curr.clone() {
            Token::Number(n) => {
                let val = *n;
                self.advance();
                Ok(val)
            }
            Token::LParen => {
                self.advance(); // consume '('
                let val = self.parse_comparison()?;
                if self.curr != Token::RParen {
                    return Err(format!("expected ')', got {:?}", self.curr));
                }
                self.advance(); // consume ')'
                Ok(val)
            }
            Token::If => {
                // if comparison then conditional else conditional
                self.advance(); // consume 'if'
                let cond = self.parse_comparison()?;
                if self.curr != Token::Then {
                    return Err(format!("expected 'then', got {:?}", self.curr));
                }
                self.advance(); // consume 'then'
                let true_val = self.parse_conditional()?;
                if self.curr != Token::Else {
                    return Err(format!("expected 'else', got {:?}", self.curr));
                }
                self.advance(); // consume 'else'
                let false_val = self.parse_conditional()?;
                Ok(if cond != 0 { true_val } else { false_val })
            }
            Token::Ident(name) => {
                let name = name.clone();
                self.advance(); // consume ident
                if self.curr == Token::LParen {
                    // function call
                    self.advance(); // consume '('
                    let mut args = Vec::new();
                    if self.curr != Token::RParen {
                        args.push(self.parse_comparison()?);
                        while self.curr == Token::Comma {
                            self.advance(); // consume ','
                            args.push(self.parse_comparison()?);
                        }
                    }
                    if self.curr != Token::RParen {
                        return Err(format!(
                            "expected ')' in function call, got {:?}",
                            self.curr
                        ));
                    }
                    self.advance(); // consume ')'
                    if let Some(func) = self.funcs.get(&name) {
                        Ok(func(&args))
                    } else {
                        Err(format!("unknown function '{}'", name))
                    }
                } else {
                    // Plain identifier — variable lookup
                    if let Some(&val) = self.vars.get(&name) {
                        Ok(val)
                    } else {
                        Err(format!("unknown variable '{}'", name))
                    }
                }
            }
            Token::Minus => {
                // Unary minus
                self.advance();
                let val = self.parse_factor()?;
                Ok(val.wrapping_neg())
            }
            _ => Err(format!("unexpected token {:?}", self.curr)),
        }
    }
}

impl SimpleExpressionEvaluator {
    /// Evaluate an expression string with the given variable context and
    /// registered functions.
    ///
    /// Variables are referenced as `{variable_name}` in the expression string.
    /// They are substituted (inlined) **before** parsing so the parser only
    /// ever sees plain integers and identifiers.
    pub fn evaluate(
        expr: &str,
        vars: &HashMap<String, i64>,
        funcs: &HashMap<String, Box<dyn Fn(&[i64]) -> i64>>,
    ) -> Result<i64, String> {
        // ---- 1. substitute {var} placeholders --------------------------------
        let mut resolved = expr.to_string();
        // Sort keys by length (longest first) to handle overlapping names correctly
        let mut keys: Vec<&String> = vars.keys().collect();
        keys.sort_by_key(|k| std::cmp::Reverse(k.len()));
        for key in &keys {
            if let Some(val) = vars.get(*key) {
                let placeholder = format!("{{{}}}", key);
                resolved = resolved.replace(&placeholder, &val.to_string());
            }
        }

        // ---- 2. parse & evaluate --------------------------------------------
        let mut parser = Parser::new(&resolved, vars, funcs);
        parser.parse()
    }

    /// Convenience variant without custom functions.
    pub fn evaluate_simple(expr: &str, vars: &HashMap<String, i64>) -> Result<i64, String> {
        let funcs: HashMap<String, Box<dyn Fn(&[i64]) -> i64>> = HashMap::new();
        Self::evaluate(expr, vars, &funcs)
    }
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ---- SimpleExpressionEvaluator tests ------------------------------------

    #[test]
    fn test_simple_arithmetic() {
        let vars = HashMap::new();
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("3 + 5", &vars).unwrap(),
            8
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("10 - 4", &vars).unwrap(),
            6
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("6 * 7", &vars).unwrap(),
            42
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("20 / 4", &vars).unwrap(),
            5
        );
    }

    #[test]
    fn test_simple_operator_precedence() {
        let vars = HashMap::new();
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("2 + 3 * 4", &vars).unwrap(),
            14
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("(2 + 3) * 4", &vars).unwrap(),
            20
        );
    }

    #[test]
    fn test_simple_variable_substitution() {
        let mut vars = HashMap::new();
        vars.insert("money".to_string(), 100);
        vars.insert("turns".to_string(), 5);
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("{money} + {turns}", &vars).unwrap(),
            105
        );
    }

    #[test]
    fn test_simple_if_then_else() {
        let vars = HashMap::new();
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("if 5 > 3 then 10 else 20", &vars)
                .unwrap(),
            10
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate_simple("if 3 > 5 then 10 else 20", &vars)
                .unwrap(),
            20
        );
    }

    #[test]
    fn test_simple_function_call() {
        let mut funcs: HashMap<String, Box<dyn Fn(&[i64]) -> i64>> = HashMap::new();
        funcs.insert("double".to_string(), Box::new(|args| args[0] * 2));
        funcs.insert("add".to_string(), Box::new(|args| args[0] + args[1]));

        let vars = HashMap::new();
        assert_eq!(
            SimpleExpressionEvaluator::evaluate("double(21)", &vars, &funcs).unwrap(),
            42
        );
        assert_eq!(
            SimpleExpressionEvaluator::evaluate("add(10, 20)", &vars, &funcs).unwrap(),
            30
        );
    }

    // ---- JsExpressionEvaluator tests ----------------------------------------

    #[test]
    fn test_js_arithmetic() {
        let vars = HashMap::new();
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("3 + 5", &vars).unwrap(),
            8
        );
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("10 - 4", &vars).unwrap(),
            6
        );
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("6 * 7", &vars).unwrap(),
            42
        );
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("20 / 4", &vars).unwrap(),
            5
        );
    }

    #[test]
    fn test_js_ternary() {
        let vars = HashMap::new();
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("5 > 3 ? 10 : 20", &vars).unwrap(),
            10
        );
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("3 > 5 ? 10 : 20", &vars).unwrap(),
            20
        );
    }

    #[test]
    fn test_js_nested_ternary() {
        let vars = HashMap::new();
        let result = JsExpressionEvaluator::evaluate_simple(
            "10 > 5 ? (2 > 1 ? 100 : 200) : 300",
            &vars,
        )
        .unwrap();
        assert_eq!(result, 100);
    }

    #[test]
    fn test_js_variable_lookup() {
        let mut vars = HashMap::new();
        vars.insert("money".to_string(), 100);
        vars.insert("turns".to_string(), 5);
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("money + turns", &vars).unwrap(),
            105
        );
    }

    #[test]
    fn test_js_dollar_brace_variable() {
        let mut vars = HashMap::new();
        vars.insert("money".to_string(), 100);
        assert_eq!(
            JsExpressionEvaluator::evaluate_simple("${money} + 5", &vars).unwrap(),
            105
        );
    }

    #[test]
    fn test_js_function_call() {
        let mut funcs: HashMap<String, Box<dyn Fn(&[i64]) -> i64>> = HashMap::new();
        funcs.insert("double".to_string(), Box::new(|args| args[0] * 2));
        funcs.insert("add".to_string(), Box::new(|args| args[0] + args[1]));

        let vars = HashMap::new();
        assert_eq!(
            JsExpressionEvaluator::evaluate("double(21)", &vars, &funcs).unwrap(),
            42
        );
        assert_eq!(
            JsExpressionEvaluator::evaluate("add(10, 20)", &vars, &funcs).unwrap(),
            30
        );
    }

    #[test]
    fn test_js_strip_line_comments() {
        let cleaned = JsScriptHost::strip_js_comments("10 + 20 // add");
        assert_eq!(cleaned.trim(), "10 + 20");
    }

    #[test]
    fn test_js_strip_block_comments() {
        let cleaned = JsScriptHost::strip_js_comments("10 + /* comment */ 20");
        assert_eq!(cleaned.trim(), "10 +  20");
    }

    #[test]
    fn test_js_script_host_eval() {
        let host = JsScriptHost::new();
        let mut ctx = HashMap::new();
        ctx.insert("x".to_string(), 10);
        let result = host.eval_expression("x + 5", &ctx).unwrap();
        assert_eq!(result, 15);
    }

    #[test]
    fn test_js_script_host_run() {
        let host = JsScriptHost::new();
        let mut ctx = HashMap::new();
        ctx.insert("x".to_string(), 10);
        let result = host.eval_expression("x > 5 ? 100 : 0", &ctx).unwrap();
        assert_eq!(result, 100);
    }

    // ---- WasmScriptHost tests ----------------------------------------------

    #[test]
    fn test_wasm_host_returns_error() {
        let host = WasmScriptHost::new();
        let result = host.run(ScriptEngineKind::Wasm, "dummy");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("WASM runtime"));
    }

    // ---- ScriptSandbox backward compat -------------------------------------

    #[test]
    fn test_sandbox_disabled() {
        let host = DisabledScriptHost;
        let result = ScriptSandbox::execute(&host, ScriptEngineKind::Simple, "1+1");
        assert!(result.is_err());
    }

    #[test]
    fn test_sandbox_simple() {
        let host = SimpleScriptHost::new();
        let result = ScriptSandbox::execute(&host, ScriptEngineKind::Simple, "2+2");
        assert!(result.is_ok());
    }
}
