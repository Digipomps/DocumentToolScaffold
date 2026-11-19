// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Leser avsnittene i en .docx (formål A1, PDD_dokumentverktoy_2026-11-18).
///
/// Kopiert fra CellScaffold `pdd/argumentkart-native-analyse` 0d1a8078, `Sources/App/Cells/DocumentAnalysis/DocxReader.swift`
/// (PDD_argumentkart-native-analyse_2026-11-18, A.docx-read). Endringer: `public`, avsnittstypen er den felles
/// `Paragraph`, `collapseWhitespace`/`canonicalStyleName` bor i `TextSupport`, og XML-leserne slår eksplisitt av
/// eksterne entiteter. Oppførselen er ellers uendret.
///
/// Samme regler som `tools/docx_read.py` i PDD-mappen:
/// - avsnitt (`w:p`) i dokumentrekkefølge; tomme avsnitt hoppes over
/// - stilnavnet slås opp i `styles.xml`, så norsk Word (`Overskrift1`) gir «Heading 1»
/// - tekst fra `w:t`; `w:tab` blir tab, `w:br`/`w:cr` blir mellomrom; mellomrom slås sammen
/// - slettet tekst i sporede endringer (`w:delText`) tas ikke med, innsatt tekst (`w:ins`) tas med
/// - fotnoter (`w:footnoteReference`) hentes fra `footnotes.xml`, i rekkefølgen de står i avsnittet
/// Cellen skriver aldri noe inn i teksten.
public enum DocxReader {
    public typealias Paragraph = DocumentParagraph

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notADocx
        case missingDocument
        case unreadableXML(String)
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .notADocx: return "Filen er ikke en .docx (ikke en zip-fil)."
            case .missingDocument: return "Filen mangler word/document.xml og er ikke et Word-dokument."
            case .unreadableXML(let part): return "Klarte ikke å lese \(part) i dokumentet."
            case .tooLarge(let bytes): return "Filen er for stor (\(bytes) byte). Grensen er \(DocxReader.maxBytes) byte."
            }
        }

        public var code: String {
            switch self {
            case .notADocx: return "not-a-docx"
            case .missingDocument: return "missing-document-xml"
            case .unreadableXML: return "unreadable-xml"
            case .tooLarge: return "too-large"
            }
        }
    }

    /// Øvre grense for en opplastet fil og for hver del som pakkes ut (vern mot zip-bomber).
    public static let maxBytes = DocumentIntake.maxBytes

    public static func read(data: Data) throws -> [Paragraph] {
        guard data.count <= maxBytes else { throw ReadError.tooLarge(data.count) }
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)
        } catch {
            throw ReadError.notADocx
        }
        guard let documentXML = try part("word/document.xml", in: archive) else { throw ReadError.missingDocument }
        let styles = try part("word/styles.xml", in: archive).map(StyleNames.parse) ?? [:]
        let footnotes = try part("word/footnotes.xml", in: archive).map(Footnotes.parse) ?? [:]
        return try Body.parse(documentXML, styles: styles, footnotes: footnotes)
    }

    private static func part(_ path: String, in archive: Archive) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        guard entry.uncompressedSize <= UInt64(maxBytes) else { throw ReadError.tooLarge(Int(entry.uncompressedSize)) }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                data.append(chunk)
                if data.count > maxBytes { throw ReadError.tooLarge(data.count) }
            }
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.unreadableXML(path)
        }
        return data
    }

    /// Se `TextSupport.collapseWhitespace`.
    static func collapseWhitespace(_ text: String) -> String { TextSupport.collapseWhitespace(text) }

    static func canonicalStyleName(_ name: String) -> String { TextSupport.canonicalStyleName(name) }
}

// MARK: - XML

private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

/// Felles: elementnavn uten prefiks når elementet ligger i Word-navnerommet.
private func wordLocalName(_ elementName: String, _ namespaceURI: String?) -> String? {
    guard namespaceURI == wordNamespace else { return nil }
    if let colon = elementName.lastIndex(of: ":") { return String(elementName[elementName.index(after: colon)...]) }
    return elementName
}

private func wordAttribute(_ attributes: [String: String], _ name: String) -> String? {
    attributes["w:\(name)"] ?? attributes[name]
}

private final class StyleNames: NSObject, XMLParserDelegate {
    private var names: [String: String] = [:]
    private var currentID: String?

    static func parse(_ data: Data) throws -> [String: String] {
        let delegate = StyleNames()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse() else { throw DocxReader.ReadError.unreadableXML("word/styles.xml") }
        return delegate.names
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch wordLocalName(elementName, namespaceURI) {
        case "style": currentID = wordAttribute(attributes, "styleId")
        case "name":
            if let id = currentID, names[id] == nil, let value = wordAttribute(attributes, "val") { names[id] = value }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if wordLocalName(elementName, namespaceURI) == "style" { currentID = nil }
    }
}

private final class Footnotes: NSObject, XMLParserDelegate {
    private var notes: [String: String] = [:]
    private var currentID: String?
    private var buffer = ""
    private var inText = false

    static func parse(_ data: Data) throws -> [String: String] {
        let delegate = Footnotes()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw DocxReader.ReadError.unreadableXML("word/footnotes.xml") }
        return delegate.notes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch wordLocalName(elementName, namespaceURI) {
        case "footnote":
            // Skilletegn og fortsettelse har w:type; bare vanlige fotnoter tas med.
            currentID = wordAttribute(attributes, "type") == nil ? wordAttribute(attributes, "id") : nil
            buffer = ""
        case "t": inText = currentID != nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch wordLocalName(elementName, namespaceURI) {
        case "t": inText = false
        case "footnote":
            if let id = currentID { notes[id] = DocxReader.collapseWhitespace(buffer) }
            currentID = nil
        default: break
        }
    }
}

private final class Body: NSObject, XMLParserDelegate {
    private struct Open {
        var styleID = "Normal"
        var text = ""
        var noteIDs: [String] = []
        var order: Int
    }

    private let styles: [String: String]
    private let footnotes: [String: String]
    private var stack: [Open] = []
    private var finished: [(Int, DocxReader.Paragraph)] = []
    private var started = 0
    private var inText = false
    private var inParagraphProperties = 0

    private init(styles: [String: String], footnotes: [String: String]) {
        self.styles = styles
        self.footnotes = footnotes
    }

    static func parse(_ data: Data, styles: [String: String], footnotes: [String: String]) throws -> [DocxReader.Paragraph] {
        let delegate = Body(styles: styles, footnotes: footnotes)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw DocxReader.ReadError.unreadableXML("word/document.xml") }
        return delegate.finished.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard let name = wordLocalName(elementName, namespaceURI) else { return }
        switch name {
        case "p":
            stack.append(Open(order: started))
            started += 1
        case "pPr":
            inParagraphProperties += 1
        case "pStyle":
            if inParagraphProperties > 0, !stack.isEmpty, let value = wordAttribute(attributes, "val") { stack[stack.count - 1].styleID = value }
        case "t":
            inText = !stack.isEmpty
        case "tab":
            // w:tab i avsnittsegenskapene er en tabulatorstopp, ikke et tegn.
            if inParagraphProperties == 0, !stack.isEmpty { stack[stack.count - 1].text += "\t" }
        case "br", "cr":
            if !stack.isEmpty { stack[stack.count - 1].text += " " }
        case "footnoteReference":
            if !stack.isEmpty, let id = wordAttribute(attributes, "id") { stack[stack.count - 1].noteIDs.append(id) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let name = wordLocalName(elementName, namespaceURI) else { return }
        switch name {
        case "t": inText = false
        case "pPr": inParagraphProperties = max(0, inParagraphProperties - 1)
        case "p":
            guard let open = stack.popLast() else { return }
            let text = DocxReader.collapseWhitespace(open.text)
            guard !text.isEmpty else { return }
            let style = DocxReader.canonicalStyleName(styles[open.styleID] ?? open.styleID)
            finished.append((open.order, DocxReader.Paragraph(style: style, text: text, footnotes: open.noteIDs.map { footnotes[$0] ?? "" })))
        default:
            break
        }
    }
}
