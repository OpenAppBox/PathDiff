//
//  SyntaxHighlighter.swift
//  PathDiff
//

import Foundation

nonisolated enum SyntaxKind: UInt8, Sendable, Hashable {
    case keyword
    case type
    case string
    case number
    case comment
    case attribute
    case tag
    case property
    case preprocessor
}

/// A highlighted range of a line, in `Character` offsets (like change highlights).
nonisolated struct SyntaxSpan: Sendable, Hashable {
    let range: Range<Int>
    let kind: SyntaxKind
}

/// Per-line syntax spans for one document.
nonisolated struct SyntaxHighlights: Sendable {
    let languageName: String
    let lines: [[SyntaxSpan]]

    func spans(forLine number: Int?) -> [SyntaxSpan] {
        guard let number, number >= 1, number <= lines.count else { return [] }
        return lines[number - 1]
    }
}

/// Lexical description of a language: enough for a fast, line-oriented tokenizer that
/// carries block comments and multi-line strings across lines.
nonisolated struct SyntaxLanguage: Sendable {
    enum Style: Sendable {
        case code
        case markup
        case json
        case yaml
        case markdown
    }

    let name: String
    var style: Style = .code
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    var stringDelimiters: Set<Character> = ["\"", "'"]
    var multilineStrings: [String] = []
    var capitalizedWordsAreTypes = false
    /// `@Attribute` (Swift, Java, Kotlin, Python decorators, CSS at-rules).
    var attributePrefix: Character?
    /// `#include` style directives at the start of a line.
    var preprocessorPrefix: Character?
    /// `name:` is highlighted as a property (CSS declarations).
    var colonKeysAreProperties = false
    var caseInsensitiveKeywords = false

    /// Files above this size are shown without highlighting.
    static let maximumHighlightedBytes: Int64 = 3 * 1024 * 1024
    static let maximumHighlightedLineLength = 4_000

    static func detect(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return dockerfile
        case "makefile", "gnumakefile": return makefile
        case "podfile", "gemfile", "rakefile", "fastfile", "appfile": return ruby
        case "package.swift": return swift
        case ".gitignore", ".gitattributes", ".dockerignore", ".env": return shell
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return swift
        case "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "hh", "metal": return cFamily
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return javaScript
        case "java": return java
        case "kt", "kts": return kotlin
        case "go": return go
        case "rs": return rust
        case "py", "pyi", "pyw": return python
        case "rb", "rake", "gemspec", "podspec": return ruby
        case "php": return php
        case "cs": return cSharp
        case "sh", "bash", "zsh", "fish", "command": return shell
        case "sql": return sql
        case "dart": return dart
        case "scala", "sc": return scala
        case "lua": return lua
        case "gradle", "groovy": return groovy
        case "json", "jsonc", "json5", "geojson", "webmanifest": return json
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "properties", "editorconfig": return toml
        case "xml", "plist", "html", "htm", "xhtml", "svg", "storyboard", "xib", "entitlements", "vue", "csproj", "xcscheme", "xcprivacy": return markup
        case "css", "scss", "sass", "less": return css
        case "md", "markdown", "mdx": return markdown
        case "mk": return makefile
        default: return nil
        }
    }

    // MARK: Definitions

    static let swift = SyntaxLanguage(
        name: "Swift",
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet", "consuming", "borrowing", "sending"],
        types: ["Int", "String", "Bool", "Double", "Float", "Character", "Array", "Dictionary", "Set", "Optional", "Void", "Any", "AnyObject", "Never"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        multilineStrings: ["\"\"\""],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@",
        preprocessorPrefix: "#"
    )

    static let cFamily = SyntaxLanguage(
        name: "C / Objective-C / C++",
        keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false", "nullptr", "NULL", "nil", "YES", "NO", "self", "super", "id", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "try", "catch", "throw", "using", "constexpr", "noexcept", "explicit", "friend", "operator", "mutable", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "instancetype", "nonatomic", "atomic", "strong", "weak", "assign", "copy", "readonly", "readwrite", "nullable", "nonnull", "kernel", "device", "constant", "thread"],
        types: ["size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "NSString", "NSInteger", "NSUInteger", "CGFloat", "BOOL", "float2", "float3", "float4"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        capitalizedWordsAreTypes: true,
        attributePrefix: "@",
        preprocessorPrefix: "#"
    )

    static let javaScript = SyntaxLanguage(
        name: "JavaScript / TypeScript",
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "is", "keyof", "let", "module", "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"],
        types: ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint", "Promise", "Array", "Record", "Partial", "Map", "Set"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        multilineStrings: ["`"],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let java = SyntaxLanguage(
        name: "Java",
        keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "record", "return", "sealed", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "false", "try", "var", "void", "volatile", "while", "yield"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\""],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let kotlin = SyntaxLanguage(
        name: "Kotlin",
        keywords: ["abstract", "annotation", "as", "break", "by", "catch", "class", "companion", "const", "constructor", "continue", "crossinline", "data", "do", "else", "enum", "external", "false", "final", "finally", "for", "fun", "get", "if", "import", "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit", "null", "object", "open", "operator", "out", "override", "package", "private", "protected", "public", "reified", "return", "sealed", "set", "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "vararg", "when", "where", "while"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\""],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let go = SyntaxLanguage(
        name: "Go",
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"],
        types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        multilineStrings: ["`"],
        capitalizedWordsAreTypes: false
    )

    static let rust = SyntaxLanguage(
        name: "Rust",
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        capitalizedWordsAreTypes: true,
        preprocessorPrefix: "#"
    )

    static let python = SyntaxLanguage(
        name: "Python",
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
        types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type"],
        lineComments: ["#"],
        multilineStrings: ["\"\"\"", "'''"],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let ruby = SyntaxLanguage(
        name: "Ruby",
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "attr_reader", "attr_writer", "attr_accessor", "private", "protected", "public", "pod", "platform", "target", "use_frameworks!", "source", "gem", "lane"],
        lineComments: ["#"],
        capitalizedWordsAreTypes: true
    )

    static let php = SyntaxLanguage(
        name: "PHP",
        keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or", "print", "private", "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "this", "throw", "trait", "true", "try", "unset", "use", "var", "while", "yield"],
        lineComments: ["//", "#"],
        blockComment: ("/*", "*/"),
        capitalizedWordsAreTypes: true,
        caseInsensitiveKeywords: true
    )

    static let cSharp = SyntaxLanguage(
        name: "C#",
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "get", "goto", "if", "implicit", "in", "init", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "null", "object", "operator", "out", "override", "params", "partial", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "short", "sizeof", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "using", "var", "virtual", "void", "while", "yield"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        capitalizedWordsAreTypes: true,
        preprocessorPrefix: "#"
    )

    static let shell = SyntaxLanguage(
        name: "Shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "export", "local", "readonly", "set", "unset", "source", "echo", "cd", "true", "false", "shift", "eval", "exec", "trap"],
        lineComments: ["#"]
    )

    static let sql = SyntaxLanguage(
        name: "SQL",
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct", "null", "is", "in", "like", "between", "case", "when", "then", "else", "end", "default", "unique", "constraint", "begin", "commit", "rollback", "with", "exists", "true", "false"],
        types: ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "date", "timestamp", "real", "float", "double", "numeric", "decimal", "blob", "uuid", "json", "jsonb"],
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        caseInsensitiveKeywords: true
    )

    static let dart = SyntaxLanguage(
        name: "Dart",
        keywords: ["abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "dynamic", "else", "enum", "export", "extends", "extension", "factory", "false", "final", "finally", "for", "get", "if", "implements", "import", "in", "is", "late", "library", "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "typedef", "var", "void", "while", "with", "yield"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["'''", "\"\"\""],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let scala = SyntaxLanguage(
        name: "Scala",
        keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "enum", "extends", "false", "final", "finally", "for", "given", "if", "implicit", "import", "lazy", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed", "super", "then", "this", "throw", "trait", "true", "try", "type", "using", "val", "var", "while", "with", "yield"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\""],
        capitalizedWordsAreTypes: true,
        attributePrefix: "@"
    )

    static let lua = SyntaxLanguage(
        name: "Lua",
        keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"],
        lineComments: ["--"]
    )

    static let groovy = SyntaxLanguage(
        name: "Groovy / Gradle",
        keywords: ["def", "class", "if", "else", "for", "while", "return", "import", "true", "false", "null", "new", "plugins", "dependencies", "implementation", "api", "android", "repositories", "apply", "task", "ext", "val", "var", "id"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\"", "'''"],
        capitalizedWordsAreTypes: true
    )

    static let dockerfile = SyntaxLanguage(
        name: "Dockerfile",
        keywords: ["from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"],
        lineComments: ["#"],
        caseInsensitiveKeywords: true
    )

    static let makefile = SyntaxLanguage(
        name: "Makefile",
        keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "override", ".PHONY"],
        lineComments: ["#"]
    )

    static let json = SyntaxLanguage(name: "JSON", style: .json, keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""])
    static let yaml = SyntaxLanguage(name: "YAML", style: .yaml, keywords: ["true", "false", "null", "yes", "no", "on", "off", "~"], lineComments: ["#"])
    static let toml = SyntaxLanguage(name: "TOML / INI", style: .yaml, keywords: ["true", "false"], lineComments: ["#", ";"])
    static let markup = SyntaxLanguage(name: "XML / HTML", style: .markup, blockComment: ("<!--", "-->"))
    static let markdown = SyntaxLanguage(name: "Markdown", style: .markdown)

    static let css = SyntaxLanguage(
        name: "CSS",
        keywords: ["important", "inherit", "initial", "unset", "none", "auto", "and", "not", "only"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        attributePrefix: "@",
        colonKeysAreProperties: true
    )
}

/// Tokenizes documents into per-line syntax spans.
nonisolated enum SyntaxHighlighter {
    private enum State: Equatable {
        case normal
        case blockComment
        case multilineString(String)
        case markupTag
        case fencedCode
    }

    static func highlight(_ document: TextDocument, language: SyntaxLanguage) -> SyntaxHighlights {
        var state = State.normal
        var result: [[SyntaxSpan]] = []
        result.reserveCapacity(document.lines.count)
        for line in document.lines {
            guard line.utf8.count <= SyntaxLanguage.maximumHighlightedLineLength else {
                result.append([])
                continue
            }
            let characters = Array(line)
            var spans: [SyntaxSpan] = []
            switch language.style {
            case .code: tokenizeCode(characters, language, &state, &spans)
            case .markup: tokenizeMarkup(characters, language, &state, &spans)
            case .json: tokenizeJSON(characters, language, &state, &spans)
            case .yaml: tokenizeYAML(characters, language, &spans)
            case .markdown: tokenizeMarkdown(characters, &state, &spans)
            }
            result.append(spans)
        }
        return SyntaxHighlights(languageName: language.name, lines: result)
    }

    // MARK: Helpers

    private static func matches(_ characters: [Character], at index: Int, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var offset = index
        for character in token {
            guard offset < characters.count, characters[offset] == character else { return false }
            offset += 1
        }
        return true
    }

    /// Index just past `token`, searching from `index`, or `nil`.
    private static func find(_ token: String, in characters: [Character], from index: Int) -> Int? {
        var position = index
        let count = token.count
        while position + count <= characters.count {
            if matches(characters, at: position, token) { return position + count }
            position += 1
        }
        return nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func append(_ spans: inout [SyntaxSpan], _ start: Int, _ end: Int, _ kind: SyntaxKind) {
        guard end > start else { return }
        spans.append(SyntaxSpan(range: start..<end, kind: kind))
    }

    /// Scans a quoted string starting at `start` (the opening quote); returns the end index.
    private static func scanString(_ characters: [Character], from start: Int, quote: Character) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == quote { return index + 1 }
            index += 1
        }
        return characters.count
    }

    private static func scanNumber(_ characters: [Character], from start: Int) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character.isNumber || character.isLetter || character == "_" || character == "." {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    // MARK: Code

    private static func tokenizeCode(_ c: [Character], _ language: SyntaxLanguage, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        var index = 0
        if case .blockComment = state, let close = language.blockComment?.close {
            if let end = find(close, in: c, from: 0) {
                append(&spans, 0, end, .comment)
                index = end
                state = .normal
            } else {
                append(&spans, 0, c.count, .comment)
                return
            }
        } else if case .multilineString(let delimiter) = state {
            if let end = find(delimiter, in: c, from: 0) {
                append(&spans, 0, end, .string)
                index = end
                state = .normal
            } else {
                append(&spans, 0, c.count, .string)
                return
            }
        }

        // Directives such as `#include` or `#if`.
        if let prefix = language.preprocessorPrefix, index == 0 {
            let first = c.firstIndex { !$0.isWhitespace }
            if let first, c[first] == prefix, first + 1 < c.count, c[first + 1].isLetter {
                var end = first + 1
                while end < c.count, isIdentifierPart(c[end]) { end += 1 }
                append(&spans, first, end, .preprocessor)
                index = end
            }
        }

        var previousSignificant: Character?
        while index < c.count {
            let character = c[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if language.lineComments.contains(where: { matches(c, at: index, $0) }) {
                append(&spans, index, c.count, .comment)
                return
            }
            if let block = language.blockComment, matches(c, at: index, block.open) {
                if let end = find(block.close, in: c, from: index + block.open.count) {
                    append(&spans, index, end, .comment)
                    index = end
                    continue
                }
                append(&spans, index, c.count, .comment)
                state = .blockComment
                return
            }
            if let delimiter = language.multilineStrings.first(where: { matches(c, at: index, $0) }) {
                if let end = find(delimiter, in: c, from: index + delimiter.count) {
                    append(&spans, index, end, .string)
                    index = end
                    continue
                }
                append(&spans, index, c.count, .string)
                state = .multilineString(delimiter)
                return
            }
            if language.stringDelimiters.contains(character) {
                let end = scanString(c, from: index, quote: character)
                append(&spans, index, end, .string)
                index = end
                previousSignificant = character
                continue
            }
            if character.isNumber || (character == "." && index + 1 < c.count && c[index + 1].isNumber && !(previousSignificant.map(isIdentifierPart) ?? false)) {
                let end = scanNumber(c, from: index)
                append(&spans, index, end, .number)
                index = end
                previousSignificant = "0"
                continue
            }
            if let prefix = language.attributePrefix, character == prefix, index + 1 < c.count, isIdentifierStart(c[index + 1]) {
                var end = index + 1
                while end < c.count, isIdentifierPart(c[end]) || c[end] == "." { end += 1 }
                append(&spans, index, end, .attribute)
                index = end
                continue
            }
            if isIdentifierStart(character) {
                var end = index + 1
                while end < c.count, isIdentifierPart(c[end]) || (c[end] == "-" && language.colonKeysAreProperties) { end += 1 }
                if end < c.count, c[end] == "?" || c[end] == "!", language.keywords.contains(String(c[index...end])) { end += 1 }
                let word = String(c[index..<end])
                let lookup = language.caseInsensitiveKeywords ? word.lowercased() : word
                if language.colonKeysAreProperties, nextNonSpace(c, from: end) == ":" {
                    append(&spans, index, end, .property)
                } else if language.keywords.contains(lookup) {
                    append(&spans, index, end, .keyword)
                } else if language.types.contains(lookup) || (language.capitalizedWordsAreTypes && character.isUppercase && Self.looksLikeTypeName(word)) {
                    append(&spans, index, end, .type)
                }
                index = end
                previousSignificant = "a"
                continue
            }
            previousSignificant = character
            index += 1
        }
    }

    /// `Widget`, `URL`, `UUID` — but not `MAX_SIZE` style constants or single letters.
    private static func looksLikeTypeName(_ word: String) -> Bool {
        word.contains(where: \.isLowercase) || (word.count > 1 && !word.contains("_"))
    }

    private static func nextNonSpace(_ characters: [Character], from index: Int) -> Character? {
        var position = index
        while position < characters.count, characters[position] == " " || characters[position] == "\t" { position += 1 }
        return position < characters.count ? characters[position] : nil
    }

    // MARK: Markup

    private static func tokenizeMarkup(_ c: [Character], _ language: SyntaxLanguage, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        var index = 0
        while index < c.count {
            switch state {
            case .blockComment:
                if let end = find("-->", in: c, from: index) {
                    append(&spans, index, end, .comment)
                    index = end
                    state = .normal
                } else {
                    append(&spans, index, c.count, .comment)
                    return
                }
            case .markupTag:
                let character = c[index]
                if character == ">" || (character == "/" && index + 1 < c.count && c[index + 1] == ">") || (character == "?" && index + 1 < c.count && c[index + 1] == ">") {
                    let end = character == ">" ? index + 1 : index + 2
                    append(&spans, index, end, .tag)
                    index = end
                    state = .normal
                } else if character == "\"" || character == "'" {
                    let end = scanString(c, from: index, quote: character)
                    append(&spans, index, end, .string)
                    index = end
                } else if isIdentifierStart(character) {
                    var end = index + 1
                    while end < c.count, isIdentifierPart(c[end]) || c[end] == "-" || c[end] == ":" || c[end] == "." { end += 1 }
                    append(&spans, index, end, .attribute)
                    index = end
                } else {
                    index += 1
                }
            default:
                if matches(c, at: index, "<!--") {
                    state = .blockComment
                    continue
                }
                if c[index] == "<", index + 1 < c.count, c[index + 1] == "/" || c[index + 1] == "!" || c[index + 1] == "?" || isIdentifierStart(c[index + 1]) {
                    var end = index + 1
                    if c[end] == "/" || c[end] == "!" || c[end] == "?" { end += 1 }
                    while end < c.count, isIdentifierPart(c[end]) || c[end] == "-" || c[end] == ":" || c[end] == "." { end += 1 }
                    append(&spans, index, end, .tag)
                    index = end
                    state = .markupTag
                } else if c[index] == "&", let semicolon = c[index...].prefix(10).firstIndex(of: ";") {
                    append(&spans, index, semicolon + 1, .number)
                    index = semicolon + 1
                } else {
                    index += 1
                }
            }
        }
    }

    // MARK: JSON, YAML, Markdown

    private static func tokenizeJSON(_ c: [Character], _ language: SyntaxLanguage, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        var index = 0
        if state == .blockComment {
            guard let end = find("*/", in: c, from: 0) else {
                append(&spans, 0, c.count, .comment)
                return
            }
            append(&spans, 0, end, .comment)
            index = end
            state = .normal
        }
        while index < c.count {
            let character = c[index]
            if matches(c, at: index, "//") {
                append(&spans, index, c.count, .comment)
                return
            }
            if matches(c, at: index, "/*") {
                guard let end = find("*/", in: c, from: index + 2) else {
                    append(&spans, index, c.count, .comment)
                    state = .blockComment
                    return
                }
                append(&spans, index, end, .comment)
                index = end
            } else if character == "\"" {
                let end = scanString(c, from: index, quote: "\"")
                append(&spans, index, end, nextNonSpace(c, from: end) == ":" ? .property : .string)
                index = end
            } else if character.isNumber || character == "-" {
                let end = scanNumber(c, from: index)
                append(&spans, index, end, .number)
                index = end
            } else if character.isLetter {
                var end = index + 1
                while end < c.count, c[end].isLetter { end += 1 }
                if language.keywords.contains(String(c[index..<end])) { append(&spans, index, end, .keyword) }
                index = end
            } else {
                index += 1
            }
        }
    }

    private static func tokenizeYAML(_ c: [Character], _ language: SyntaxLanguage, _ spans: inout [SyntaxSpan]) {
        guard let first = c.firstIndex(where: { !$0.isWhitespace }) else { return }
        var index = first
        if c[index] == "#" || c[index] == ";" {
            append(&spans, index, c.count, .comment)
            return
        }
        if c[index] == "[" {   // TOML/INI section header
            append(&spans, index, c.count, .tag)
            return
        }
        if c[index] == "-" { index += 1 }
        while index < c.count, c[index] == " " { index += 1 }
        // `key:` or `key =`
        var keyEnd = index
        while keyEnd < c.count, c[keyEnd] != ":" && c[keyEnd] != "=" && c[keyEnd] != "#" && c[keyEnd] != "\"" && c[keyEnd] != "'" { keyEnd += 1 }
        if keyEnd < c.count, c[keyEnd] == ":" || c[keyEnd] == "=", keyEnd > index {
            append(&spans, index, keyEnd, .property)
            index = keyEnd + 1
        }
        while index < c.count {
            let character = c[index]
            if character == "#", index == 0 || c[index - 1] == " " {
                append(&spans, index, c.count, .comment)
                return
            }
            if character == "\"" || character == "'" {
                let end = scanString(c, from: index, quote: character)
                append(&spans, index, end, .string)
                index = end
            } else if character.isNumber {
                let end = scanNumber(c, from: index)
                append(&spans, index, end, .number)
                index = end
            } else if character == "&" || character == "*" || character == "!" {
                var end = index + 1
                while end < c.count, !c[end].isWhitespace { end += 1 }
                append(&spans, index, end, .attribute)
                index = end
            } else if character.isLetter || character == "~" {
                var end = index + 1
                while end < c.count, c[end].isLetter { end += 1 }
                if language.keywords.contains(String(c[index..<end]).lowercased()), end == c.count || c[end].isWhitespace || c[end] == "," {
                    append(&spans, index, end, .keyword)
                }
                index = end
            } else {
                index += 1
            }
        }
    }

    private static func tokenizeMarkdown(_ c: [Character], _ state: inout State, _ spans: inout [SyntaxSpan]) {
        let trimmed = c.drop { $0 == " " }
        if matches(Array(trimmed), at: 0, "```") || matches(Array(trimmed), at: 0, "~~~") {
            append(&spans, 0, c.count, .string)
            state = state == .fencedCode ? .normal : .fencedCode
            return
        }
        if state == .fencedCode {
            append(&spans, 0, c.count, .string)
            return
        }
        if trimmed.first == "#" {
            append(&spans, 0, c.count, .keyword)
            return
        }
        if trimmed.first == ">" {
            append(&spans, 0, c.count, .comment)
            return
        }
        var index = 0
        while index < c.count {
            if c[index] == "`" {
                let end = scanString(c, from: index, quote: "`")
                append(&spans, index, end, .string)
                index = end
            } else if c[index] == "[", let close = c[index...].firstIndex(of: "]"), close + 1 < c.count, c[close + 1] == "(" {
                let end = c[close...].firstIndex(of: ")").map { $0 + 1 } ?? c.count
                append(&spans, index, close + 1, .attribute)
                append(&spans, close + 1, end, .type)
                index = end
            } else {
                index += 1
            }
        }
    }
}
