// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Leser RTF (formål A4, PDD_dokumentverktoy_2026-11-18).
///
/// Egen leser, fordi RTF-import i `NSAttributedString` ikke finnes på Linux. Port av `tools/rtf_ref.py` i PDD-mappen:
/// - `\par`, `\sect`, `\page` og `\row` avslutter et avsnitt; `\line` og `\cell` blir mellomrom, `\tab` tab
/// - stilen kommer fra `\sN` og stilarket (`{\stylesheet …}`), så «heading 1» gir «Heading 1»
/// - `\uN` gir tegnet og hopper over `\ucN` erstatningstegn; `\'hh` leses som Windows-1252
/// - `{\*\footnote …}` blir en fotnote på avsnittet den står i
/// - tabeller over fonter, farger, info, bilder, topp- og bunntekst og feltinstruksjoner hoppes over
public enum RTFReader {
    static let unreadable = DocumentToolsError("unreadable-rtf", "Filen er ikke en lesbar RTF-fil.")

    private static let skipped: Set<String> = [
        "fonttbl", "colortbl", "info", "pict", "object", "header", "headerl", "headerr", "headerf", "footer", "footerl",
        "footerr", "footerf", "fldinst", "listtable", "listoverridetable", "rsidtbl", "generator", "xmlnstbl", "themedata",
        "colorschememapping", "latentstyles", "datastore", "mmathPr", "pgdsctbl", "revtbl", "filetbl", "bkmkstart", "bkmkend",
        "pntext", "pntxta", "pntxtb", "listtext", "shppict", "nonshppict", "operator", "author",
    ]

    private enum Destination { case text, skip, stylesheet, footnote }

    private struct GroupState {
        var destination: Destination = .text
        var unicodeSkip = 1
        var style = 0
        var starred = false
    }

    private struct StyleDefinition { var index = 0; var name = ""; var depth: Int; var isParagraphStyle = true }
    private struct Note { var text = ""; var depth: Int }

    public static func read(data: Data) throws -> [Paragraph] {
        let bytes = [UInt8](data)
        var start = 0
        while start < bytes.count, [0xEF, 0xBB, 0xBF, 0x20, 0x0D, 0x0A, 0x09].contains(bytes[start]) { start += 1 }
        guard bytes.count - start >= 5, Array(bytes[start..<(start + 5)]) == Array("{\\rtf".utf8) else { throw unreadable }

        var styles: [Int: String] = [:]
        var paragraphs: [Paragraph] = []
        var stack: [GroupState] = []
        var state = GroupState()
        var text = ""
        var paragraphStyle = 0
        var notes: [String] = []
        var note: Note?
        var styleDefinition: StyleDefinition?
        var pendingSkip = 0

        func emit(_ character: Character) {
            if pendingSkip > 0 { pendingSkip -= 1; return }
            switch state.destination {
            case .skip: return
            case .stylesheet: styleDefinition?.name.append(character)
            case .footnote: note?.text.append(character)
            case .text: text.append(character)
            }
        }

        func endParagraph() {
            let collapsed = TextSupport.collapseWhitespace(text)
            if !collapsed.isEmpty {
                let name = styles[paragraphStyle] ?? "Normal"
                paragraphs.append(Paragraph(style: TextSupport.canonicalStyleName(name), text: collapsed,
                                            footnotes: notes.map(TextSupport.collapseWhitespace)))
            }
            text = ""
            notes = []
            paragraphStyle = state.style
        }

        func controlWord(_ word: String, _ number: Int?) {
            if state.starred {
                state.starred = false // \* gjelder bare kontrollordet rett etter
                if word != "footnote" { state.destination = .skip; return }
            }
            if skipped.contains(word) { state.destination = .skip; return }
            switch word {
            case "stylesheet":
                state.destination = .stylesheet
                return
            case "footnote":
                state.destination = .footnote
                note = Note(depth: stack.count)
                return
            default: break
            }
            if state.destination == .stylesheet, styleDefinition != nil {
                switch word {
                case "s": styleDefinition?.index = number ?? 0
                case "cs", "ds", "ts", "tsrowd": styleDefinition?.isParagraphStyle = false
                default: break
                }
                return
            }
            switch word {
            case "uc": state.unicodeSkip = number ?? 1
            case "u":
                if let number {
                    let value = number < 0 ? number + 65_536 : number
                    if let scalar = Unicode.Scalar(UInt32(value)) { emit(Character(scalar)) }
                    pendingSkip = state.unicodeSkip
                }
            case "par", "sect", "page":
                if state.destination == .text { endParagraph() } else if state.destination == .footnote { emit(" ") }
            case "row": if state.destination == .text { endParagraph() }
            case "line", "cell": emit(" ")
            case "tab": emit("\t")
            case "pard": state.style = 0; paragraphStyle = 0
            case "s":
                if state.destination == .text { state.style = number ?? 0; paragraphStyle = number ?? 0 }
            case "emdash": emit("\u{2014}")
            case "endash": emit("\u{2013}")
            case "lquote": emit("\u{2018}")
            case "rquote": emit("\u{2019}")
            case "ldblquote": emit("\u{201C}")
            case "rdblquote": emit("\u{201D}")
            case "bullet": emit("\u{2022}")
            default: break
            }
        }

        var i = start
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(state)
                state.starred = false
                if state.destination == .stylesheet, styleDefinition == nil { styleDefinition = StyleDefinition(depth: stack.count) }
                i += 1
            case UInt8(ascii: "}"):
                if state.destination == .footnote, let open = note, open.depth == stack.count {
                    notes.append(open.text)
                    note = nil
                }
                if let definition = styleDefinition, definition.depth == stack.count {
                    var name = definition.name.trimmingCharacters(in: .whitespaces)
                    while name.hasSuffix(";") { name.removeLast() }
                    name = name.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, definition.isParagraphStyle, styles[definition.index] == nil { styles[definition.index] = name }
                    styleDefinition = nil
                }
                if let previous = stack.popLast() { state = previous }
                i += 1
            case 0x0D, 0x0A:
                i += 1
            case UInt8(ascii: "\\"):
                guard i + 1 < bytes.count else { i += 1; break }
                let next = bytes[i + 1]
                if isLetter(next) {
                    var j = i + 1
                    while j < bytes.count, isLetter(bytes[j]), j - i <= 32 { j += 1 }
                    let word = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    var number: Int?
                    var k = j
                    if k < bytes.count, bytes[k] == UInt8(ascii: "-") || isDigit(bytes[k]) {
                        var m = k + 1
                        while m < bytes.count, isDigit(bytes[m]), m - k <= 10 { m += 1 }
                        number = Int(String(decoding: bytes[k..<m], as: UTF8.self))
                        k = m
                    }
                    if k < bytes.count, bytes[k] == UInt8(ascii: " ") { k += 1 }
                    i = k
                    controlWord(word, number)
                } else if next == UInt8(ascii: "'") {
                    if i + 3 < bytes.count, let value = UInt8(String(decoding: bytes[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                        emit(windows1252(value))
                        i += 4
                    } else {
                        i += 2
                    }
                } else {
                    switch next {
                    case UInt8(ascii: "*"): state.starred = true
                    case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"): emit(Character(Unicode.Scalar(next)))
                    case UInt8(ascii: "~"): emit("\u{00A0}")
                    case UInt8(ascii: "_"): emit("-")
                    case 0x0A, 0x0D: if state.destination == .text { endParagraph() }
                    default: break // \- (valgfri bindestrek) og ukjente symboler gir ingen tekst
                    }
                    i += 2
                }
            default:
                // Vanlig tekst: byte for byte som Latin-1 (RTF er 7-biters; 8-biters byte er sjeldne).
                var j = i
                while j < bytes.count, ![UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"), 0x0D, 0x0A].contains(bytes[j]) { j += 1 }
                for b in bytes[i..<j] { emit(Character(Unicode.Scalar(b))) }
                i = j
            }
        }
        endParagraph()
        return paragraphs
    }

    private static func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    private static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }

    private static func windows1252(_ value: UInt8) -> Character {
        if let s = String(bytes: [value], encoding: .windowsCP1252), let c = s.first { return c }
        return Character(Unicode.Scalar(value))
    }
}
