// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Leser PDF med tekstlag (formål A5, PDD_dokumentverktoy_2026-11-18).
///
/// Poppler sin `pdftotext -bbox-layout` gir ord med posisjon i leserekkefølge (også med spalter). Avsnitt,
/// overskrifter og fotnoter lages av reglene under, som er en port av `tools/pdf_ref.py` i PDD-mappen.
/// Målt 2026-11-19 med referansen: 91,6 % eksakte avsnitt på Utkast 5 art. 3 og 90,0 % på tospaltet fixture.
///
/// Regler:
/// - brødtekstens høyde er den vanligste ordhøyden (vektet med tegn); hevede tall under 0,8 av den er fotnotemarkører
/// - sidetall og tekst som går igjen øverst eller nederst på minst tre sider, fjernes
/// - nytt avsnitt når skrifthøyden endres, ved luft over 0,55 linjehøyde, ved innrykk etter en setning,
///   når første ord på linjen hadde fått plass på linjen over, eller ved et punkttegn
/// - over side- eller spalteskift fortsetter avsnittet bare når linjen over ikke slutter som en setning og
///   neste begynner med liten bokstav
/// - større skrift enn brødtekst er overskrift (størst er Heading 1, så 2 og 3)
/// - bindestrek på slutten av en linje beholdes, uten mellomrom etter; verktøyet endrer ikke tekst
public enum PDFReader {
    public struct Result: Equatable, Sendable {
        public var paragraphs: [Paragraph]
        public var warnings: [String]
    }

    public static let engineMissing = DocumentToolsError("pdf-engine-missing", "PDF-motoren (pdftotext fra poppler-utils) er ikke installert.")
    public static let timeout = DocumentToolsError("pdf-timeout", "PDF-en tok for lang tid å lese.")
    public static let unreadable = DocumentToolsError("unreadable-pdf", "PDF-en kunne ikke leses.")
    public static let noTextLayer = DocumentToolsError("no-text-layer", "PDF-en har ikke tekst, bare bilder (for eksempel en skannet side). Tekstgjenkjenning (OCR) er ikke støttet.")

    /// Hvor `pdftotext` letes etter. `DOCUMENTTOOLS_PDFTOTEXT` overstyrer.
    /// Bare for tester: erstatter søkestiene for pdftotext.
    static var pathsOverride: [String]?

    static var candidatePaths: [String] {
        if let pathsOverride { return pathsOverride }
        var paths = ["/usr/bin/pdftotext", "/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]
        if let custom = ProcessInfo.processInfo.environment["DOCUMENTTOOLS_PDFTOTEXT"], !custom.isEmpty { paths.insert(custom, at: 0) }
        return paths
    }

    public static var timeoutSeconds: TimeInterval = 30

    public static func read(data: Data) throws -> Result {
        let xml = try runPdftotext(data)
        return try paragraphs(fromBBoxXHTML: xml)
    }

    // MARK: - Poppler

    static func runPdftotext(_ data: Data) throws -> Data {
        #if os(macOS) || os(Linux)
        guard let tool = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw engineMissing }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("documenttools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.pdf")
        let output = dir.appendingPathComponent("out.html")
        try data.write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-q", "-bbox-layout", "-enc", "UTF-8", input.path, output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw engineMissing }
        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw timeout
        }
        guard process.terminationStatus == 0, let xml = try? Data(contentsOf: output) else { throw unreadable }
        return xml
        #else
        throw engineMissing
        #endif
    }

    // MARK: - Layout

    struct Word { var x0, y0, x1, y1: Double; var text: String; var height: Double { y1 - y0 } }

    final class Line {
        var page: Int
        var pageHeight: Double
        var words: [Word]
        var x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0
        var right = 0.0
        var text = ""
        var height = 0.0
        var marks: [String] = []

        init(page: Int, pageHeight: Double, words: [Word]) {
            self.page = page
            self.pageHeight = pageHeight
            self.words = words
            x0 = words.map(\.x0).min() ?? 0
            y0 = words.map(\.y0).min() ?? 0
            x1 = words.map(\.x1).max() ?? 0
            y1 = words.map(\.y1).max() ?? 0
        }

        var rawText: String { words.map(\.text).joined(separator: " ") }
    }

    static func paragraphs(fromBBoxXHTML data: Data) throws -> Result {
        let pages = try BBoxParser.parse(data)
        let body = bodyHeight(pages)
        let wordCount = pages.reduce(0) { $0 + $1.reduce(0) { $0 + $1.words.count } }
        guard body > 0, wordCount >= 3 else { throw noTextLayer }

        var edge: [String: Int] = [:]
        for page in pages {
            for line in page {
                let pos = line.y0 / line.pageHeight
                if pos < 0.08 || pos > 0.92 { edge[digitsMasked(line.rawText), default: 0] += 1 }
            }
        }
        let repeated = Set(edge.filter { $0.value >= 3 }.keys)

        struct Building { var lines: [Line]; var height: Double; var bullet: Bool; var marks: [String] }
        var building: [Building] = []
        var notes: [String: String] = [:]
        var previous: Line?

        for page in pages {
            var lines: [Line] = []
            for line in page {
                let raw = line.rawText.trimmingCharacters(in: .whitespaces)
                let pos = line.y0 / line.pageHeight
                if (pos < 0.08 || pos > 0.92) && (isPageNumber(raw) || repeated.contains(digitsMasked(line.rawText))) { continue }
                splitMarkers(line, body: body)
                if line.text.isEmpty { continue }
                lines.append(line)
            }

            // Fotnoteområdet: liten skrift under siste linje med brødtekst, bare når siden har fotnotemarkører.
            let pageMarks = Set(lines.flatMap(\.marks))
            let lastBodyY = lines.filter { $0.height >= 0.9 * body }.map(\.y1).max() ?? 0
            let noteArea = pageMarks.isEmpty ? [] : lines.filter { $0.height < 0.9 * body && $0.y0 >= lastBodyY - 0.2 * body }
            if !noteArea.isEmpty {
                let area = noteArea.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
                let numbers = area.filter { isDigits($0.text) }
                var current: String?
                for t in area where !isDigits(t.text) {
                    let middle = (t.y0 + t.y1) / 2
                    let beside = numbers.filter { abs(($0.y0 + $0.y1) / 2 - middle) < 0.6 * body && $0.x0 < t.x0 }
                    if let lead = leadingNumber(t.text), pageMarks.contains(lead.number) {
                        current = lead.number
                        notes[lead.number] = lead.rest
                    } else if let number = beside.last?.text {
                        current = number
                        notes[number] = t.text
                    } else if let open = current {
                        notes[open] = join(notes[open] ?? "", t.text)
                    }
                }
            }
            let skip = Set(noteArea.map { ObjectIdentifier($0) })

            for line in lines where !skip.contains(ObjectIdentifier(line)) {
                var bullet = false
                let scalars = Array(line.text)
                if scalars.count > 2, bullets.contains(scalars[0]), scalars[1] == " " {
                    line.text = String(scalars.dropFirst(2))
                    bullet = true
                }
                if previous == nil || breaks(previous!, line, body: body, bullet: bullet) {
                    building.append(Building(lines: [line], height: line.height, bullet: bullet, marks: line.marks))
                } else {
                    building[building.count - 1].lines.append(line)
                    building[building.count - 1].marks += line.marks
                }
                previous = line
            }
        }

        let headingSizes = Array(Set(building.filter { $0.height > body * 1.12 }.map { rounded1($0.height) })).sorted(by: >)
        var paragraphs: [Paragraph] = []
        for b in building {
            var text = ""
            for line in b.lines { text = join(text, line.text) }
            text = TextSupport.collapseWhitespace(TextSupport.cleanExtracted(text))
            guard !text.isEmpty else { continue }
            let style: String
            if let rank = headingSizes.firstIndex(of: rounded1(b.height)) {
                style = "Heading \(min(3, rank + 1))"
            } else if b.bullet {
                style = "List Paragraph"
            } else {
                style = "Normal"
            }
            let footnotes = b.marks.map { TextSupport.collapseWhitespace(TextSupport.cleanExtracted(notes[$0] ?? "")) }
            paragraphs.append(Paragraph(style: style, text: text, footnotes: footnotes))
        }
        var warnings = ["Avsnittsgrenser og overskrifter i PDF er beregnet ut fra layout og kan avvike fra originalen."]
        if paragraphs.contains(where: { $0.footnotes.contains("") }) {
            warnings.append("Noen fotnotemarkører fant ingen fotnotetekst.")
        }
        return Result(paragraphs: paragraphs, warnings: warnings)
    }

    static let bullets: Set<Character> = ["•", "▪", "◦", "‣", "∙", "·", "\u{F0B7}", "\u{F0A7}", "o", "–", "-"]

    static func breaks(_ prev: Line, _ line: Line, body: Double, bullet: Bool) -> Bool {
        if bullet { return true }
        if abs(line.height - prev.height) > 0.12 * body { return true }
        let sameColumn = line.page == prev.page && abs(line.x0 - prev.x0) < 4 * body && line.y0 > prev.y0
        if sameColumn {
            if line.y0 - prev.y1 > 0.55 * body { return true }
            if line.x0 > prev.x0 + 1.0 * body && endsSentence(prev.text) { return true }
            if let first = line.words.first, (prev.right - prev.x1) > (first.x1 - first.x0) + 0.5 * body { return true }
            return false
        }
        return endsSentence(prev.text) || !(line.text.first?.isLowercase ?? false)
    }

    static func splitMarkers(_ line: Line, body: Double) {
        var kept: [Word] = []
        var marks: [String] = []
        for word in line.words {
            if word.height < 0.8 * body, !kept.isEmpty, !word.text.isEmpty, word.text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ",") }) {
                marks += word.text.split(separator: ",").map(String.init)
                continue
            }
            kept.append(word)
        }
        line.text = kept.map(\.text).joined(separator: " ")
        let heights = kept.map(\.height).sorted()
        line.height = heights.isEmpty ? 0 : median(heights)
        line.marks = marks
    }

    static func bodyHeight(_ pages: [[Line]]) -> Double {
        var counts: [Double: Int] = [:]
        for page in pages { for line in page { for word in line.words { counts[rounded1(word.height), default: 0] += word.text.count } } }
        // Høyest antall tegn; ved likhet den minste høyden, så resultatet ikke avhenger av rekkefølgen.
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 0
    }

    static func join(_ a: String, _ b: String) -> String {
        var left = a
        while let last = left.last, last.isWhitespace { left.removeLast() }
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        let chars = Array(left)
        if chars.last == "-", right.first?.isLowercase == true, chars.count > 1, chars[chars.count - 2].isLetter { return left + right }
        return left + " " + right
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:»”\")…".contains(last)
    }

    static func isDigits(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }

    static func leadingNumber(_ text: String) -> (number: String, rest: String)? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = text.dropFirst(digits.count)
        guard let first = rest.first, first.isWhitespace else { return nil }
        return (String(digits), rest.trimmingCharacters(in: .whitespaces))
    }

    static func isPageNumber(_ text: String) -> Bool {
        let lower = text.lowercased()
        let pattern = #"^(side\s*)?\d+(\s*(/|av)\s*\d+)?$"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    static func digitsMasked(_ text: String) -> String {
        var out = ""
        var inDigits = false
        for c in text {
            if c.isASCII && c.isNumber {
                if !inDigits { out.append("#") }
                inDigits = true
            } else {
                out.append(c)
                inDigits = false
            }
        }
        return out
    }

    static func rounded1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

/// Leser XHTML fra `pdftotext -bbox-layout`: side → blokk → linje → ord, i poppler sin rekkefølge.
private final class BBoxParser: NSObject, XMLParserDelegate {
    private var pages: [[PDFReader.Line]] = []
    private var pageHeight = 0.0
    private var words: [PDFReader.Word] = []
    private var current: (x0: Double, y0: Double, x1: Double, y1: Double)?
    private var buffer = ""

    static func parse(_ data: Data) throws -> [[PDFReader.Line]] {
        // Dokumenttypen peker på en ekstern DTD; den fjernes så parseren aldri prøver å hente noe.
        var text = String(decoding: data, as: UTF8.self)
        if let start = text.range(of: "<!DOCTYPE"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let delegate = BBoxParser()
        parser.delegate = delegate
        guard parser.parse() else { throw PDFReader.unreadable }
        return delegate.pages
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "page":
            pages.append([])
            pageHeight = Double(attributes["height"] ?? "") ?? 0
        case "line":
            words = []
        case "word":
            current = (Double(attributes["xMin"] ?? "") ?? 0, Double(attributes["yMin"] ?? "") ?? 0,
                       Double(attributes["xMax"] ?? "") ?? 0, Double(attributes["yMax"] ?? "") ?? 0)
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "word":
            if let box = current, !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(PDFReader.Word(x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1, text: buffer))
            }
            current = nil
        case "line":
            guard !words.isEmpty, !pages.isEmpty else { return }
            pages[pages.count - 1].append(PDFReader.Line(page: pages.count - 1, pageHeight: pageHeight, words: words))
        case "page":
            // Høyre kant per linje: lengste linje på siden som starter i samme spalte (innen 40 pt).
            guard let lines = pages.last else { return }
            for line in lines { line.right = lines.filter { abs($0.x0 - line.x0) < 40 }.map(\.x1).max() ?? line.x1 }
        default:
            break
        }
    }
}
