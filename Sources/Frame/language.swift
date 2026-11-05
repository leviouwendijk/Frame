import enum Grammar.Grammar

public enum Frame {
    /// A single grammar drives native recognition and Tree-sitter export.
    public static func language() throws -> Grammar.Language {
        let identifier = Grammar.Expression.symbol(.terminal("identifier"))
        let value = Grammar.Expression.symbol(.production("value"))
        let object = Grammar.Expression.symbol(.production("object"))
        let entry = Grammar.Expression.sequence([
            .field("name", identifier),
            .choice([
                .sequence([.literal("="), .field("value", value), .literal(";")]),
                .sequence([.field("value", object), .optional(.literal(";"))])
            ])
        ])
        let arrayItems = Grammar.Expression.sequence([
            .field("element", value),
            .optional(.sequence([
                .literal(","),
                .optional(.symbol(.production("array_items")))
            ]))
        ])
        return try Grammar.Language(
            name: "frame",
            start: "document",
            productions: [
                .init(name: "document", expression: .repeat0(.symbol(.production("entry")))),
                .init(name: "entry", expression: entry),
                .init(name: "value", expression: .choice([
                    .symbol(.terminal("quoted")),
                    .symbol(.terminal("number")),
                    object,
                    .symbol(.production("array")),
                    .symbol(.production("reference"))
                ])),
                .init(name: "object", expression: .sequence([
                    .literal("{"),
                    .repeat0(.symbol(.production("entry"))),
                    .literal("}")
                ])),
                .init(name: "array", expression: .sequence([
                    .literal("["),
                    .optional(.symbol(.production("array_items"))),
                    .literal("]")
                ])),
                .init(name: "array_items", expression: arrayItems),
                .init(name: "reference", expression: .sequence([
                    identifier,
                    .repeat0(.sequence([.literal("."), identifier]))
                ]))
            ],
            terminals: [
                .init(name: "quoted", pattern: .regex(#""([^"\\]|\\.)*""#), role: "string"),
                .init(name: "number", pattern: .regex(#"-?(0|[1-9][0-9]*)(\.[0-9]+)?"#), role: "number"),
                .init(name: "identifier", pattern: .regex(#"[\p{L}_][\p{L}\p{N}_-]*"#), role: "variable")
            ],
            extras: [
                .pattern(#"[ \t\r\n]+"#),
                .pattern(#"//[^\r\n]*"#),
                .pattern(#"#[^\r\n]*"#),
                .pattern(#"/\*([^*]|\*+[^*/])*\*+/"#)
            ]
        )
    }
}
