// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Ren tekst (formål A3): avsnitt skilles med tom linje; linjer i et avsnitt slås sammen med mellomrom.
public enum PlainTextReader {
    public static func read(text: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var lines: [String] = []
        func flush() {
            let joined = TextSupport.collapseWhitespace(lines.joined(separator: " "))
            if !joined.isEmpty { paragraphs.append(Paragraph(style: "Normal", text: joined)) }
            lines = []
        }
        for line in normalizedLines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { lines.append(line) }
        }
        flush()
        return paragraphs
    }

    static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }
}

/// Markdown (formål A2). Bare blokkstrukturen tolkes; teksten i avsnittet står slik den er skrevet
/// (også `**` og lenker), fordi verktøyet ikke skal endre tekst. Unntaket er fotnotehenvisninger `[^id]`,
/// som tas ut av teksten og blir fotnoter, slik som i docx.
///
/// - `#`–`######` gir Heading 1–6 (over 3 blir Heading 3); `===`/`---` under en linje gir Heading 1/2
/// - `-`, `*`, `+` og `1.`/`1)` gir ett avsnitt per punkt med stilen «List Paragraph»
/// - `>` gir «Quote»; kodeblokker (```` ``` ```` eller `~~~`) gir «Code» med linjeskift bevart
/// - `[^id]: tekst` er fotnotedefinisjoner; tomme linjer, `---`/`***` og YAML-forside hoppes over
public enum MarkdownReader {
    public static func read(text: String) throws -> [Paragraph] {
        var lines = PlainTextReader.normalizedLines(text)
        // YAML-forside.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }

        // Fotnotedefinisjoner først, så henvisninger kan slås opp uansett rekkefølge.
        var notes: [String: String] = [:]
        var body: [String] = []
        var openNote: String?
        for line in lines {
            if let definition = footnoteDefinition(line) {
                notes[definition.id] = definition.text
                openNote = definition.id
            } else if let id = openNote, line.hasPrefix("    ") || line.hasPrefix("\t") {
                notes[id] = (notes[id] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                openNote = nil
                body.append(line)
            }
        }

        var paragraphs: [Paragraph] = []
        var buffer: [String] = []
        var style = "Normal"
        func flush() {
            defer { buffer = []; style = "Normal" }
            let raw = style == "Code" ? buffer.joined(separator: "\n") : TextSupport.collapseWhitespace(buffer.joined(separator: " "))
            let (text, refs) = style == "Code" ? (raw, []) : extractFootnoteReferences(raw)
            let clean = style == "Code" ? text : TextSupport.collapseWhitespace(text)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            paragraphs.append(Paragraph(style: style, text: clean, footnotes: refs.map { TextSupport.collapseWhitespace(notes[$0] ?? "") }))
        }

        var index = 0
        var fence: String?
        while index < body.count {
            let line = body[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if let open = fence {
                if trimmed.hasPrefix(open) { flush(); fence = nil } else { buffer.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
                style = "Code"
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if isRule(trimmed), buffer.isEmpty { continue }
            if let heading = atxHeading(trimmed) {
                flush()
                buffer = [heading.text]
                style = "Heading \(min(3, heading.level))"
                flush()
                continue
            }
            if !buffer.isEmpty, style == "Normal", buffer.count == 1, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                style = trimmed.first == "=" ? "Heading 1" : "Heading 2"
                flush()
                continue
            }
            if let item = listItem(line) {
                flush()
                buffer = [item]
                style = "List Paragraph"
                continue
            }
            if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if style != "Quote" { flush(); style = "Quote" }
                buffer.append(text)
                continue
            }
            if style == "Quote" || style.hasPrefix("Heading") { flush() }
            // Fortsettelseslinje i et listepunkt eller vanlig avsnitt.
            buffer.append(trimmed)
        }
        flush()
        return paragraphs
    }

    static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(2))
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        }
        return nil
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func footnoteDefinition(_ line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^"), let close = line.range(of: "]:") else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        guard !id.isEmpty, !id.contains("]") else { return nil }
        return (id, line[close.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// Tar ut `[^id]` i rekkefølge.
    static func extractFootnoteReferences(_ text: String) -> (String, [String]) {
        var out = ""
        var refs: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "[^") {
            guard let end = rest.range(of: "]", range: start.upperBound..<rest.endIndex) else { break }
            let id = String(rest[start.upperBound..<end.lowerBound])
            if id.isEmpty || id.contains(" ") {
                out += rest[..<end.upperBound]
            } else {
                out += rest[..<start.lowerBound]
                refs.append(id)
            }
            rest = rest[end.upperBound...]
        }
        out += rest
        return (out, refs)
    }
}
