// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Ett avsnitt slik alle leserne gir det ut (formål A, PDD_dokumentverktoy_2026-11-18).
///
/// Samme form som `DocxReader.Paragraph` i argumentkartet (CellScaffold 0d1a8078), slik at nummereringen
/// kan brukes uendret for alle formater. Verktøyet skriver aldri ny tekst inn i et avsnitt.
public struct Paragraph: Codable, Equatable, Hashable, Sendable {
    public var style: String
    public var text: String
    public var footnotes: [String]

    public init(style: String, text: String, footnotes: [String] = []) {
        self.style = style
        self.text = text
        self.footnotes = footnotes
    }
}

public enum DocumentFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case docx
    case pdf
    case markdown
    case rtf
    case plaintext
}

/// Resultatet av `DocumentTools.read`.
public struct DocumentText: Codable, Equatable, Sendable {
    public var format: DocumentFormat
    /// SHA-256 av filens byte, i små heksadesimaler.
    public var sourceSHA256: String
    public var paragraphs: [Paragraph]
    /// Ting leseren måtte gjette eller hoppe over, på norsk. Tom når ingenting er usikkert.
    public var warnings: [String]

    public init(format: DocumentFormat, sourceSHA256: String, paragraphs: [Paragraph], warnings: [String] = []) {
        self.format = format
        self.sourceSHA256 = sourceSHA256
        self.paragraphs = paragraphs
        self.warnings = warnings
    }
}

/// Alle feil har en stabil kode og en norsk tekst (kontrakten `documenttools_cell_contract_v1`).
public struct DocumentToolsError: Error, Equatable, CustomStringConvertible, Sendable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    public static func tooLarge(_ bytes: Int) -> DocumentToolsError {
        .init("too-large", "Filen er for stor (\(bytes) byte). Grensen er \(DocumentIntake.maxBytes) byte.")
    }
    public static let unknownFormat = DocumentToolsError("unknown-format", "Formatet er ikke gjenkjent. Støttet: docx, pdf, md, rtf og txt.")
    public static let emptyDocument = DocumentToolsError("empty-document", "Dokumentet har ingen tekst.")
}

/// Inngangen til biblioteket. Heter ikke `DocumentTools` fordi en type med samme navn som modulen gjør
/// `DocumentTools.X` tvetydig for de som bruker biblioteket.
public enum DocumentIntake {
    /// Øvre grense for en fil og for hver del som pakkes ut (vern mot zip-bomber).
    public static let maxBytes = 20 * 1024 * 1024

    /// Leser en fil til felles format. Formatet bestemmes av innholdet; filnavnet brukes bare til å skille
    /// Markdown fra ren tekst, fordi begge er tekst.
    public static func read(data: Data, name: String = "") throws -> DocumentText {
        guard data.count <= maxBytes else { throw DocumentToolsError.tooLarge(data.count) }
        guard !data.isEmpty else { throw DocumentToolsError.emptyDocument }
        let format = try detectFormat(data: data, name: name)
        var warnings: [String] = []
        let paragraphs: [Paragraph]
        switch format {
        case .docx:
            do {
                paragraphs = try DocxReader.read(data: data)
            } catch let error as DocxReader.ReadError {
                throw DocumentToolsError(error.code, error.description)
            }
        case .pdf:
            let result = try PDFReader.read(data: data)
            paragraphs = result.paragraphs
            warnings += result.warnings
        case .rtf:
            paragraphs = try RTFReader.read(data: data)
        case .markdown:
            paragraphs = try MarkdownReader.read(text: TextDecoding.decode(data, warnings: &warnings))
        case .plaintext:
            paragraphs = PlainTextReader.read(text: try TextDecoding.decode(data, warnings: &warnings))
        }
        guard !paragraphs.isEmpty else { throw DocumentToolsError.emptyDocument }
        return DocumentText(format: format, sourceSHA256: SHA256.hex(data), paragraphs: paragraphs, warnings: warnings)
    }

    /// Format ut fra de første bytene. En zip-fil er docx (leseren avviser zip uten `word/document.xml`).
    public static func detectFormat(data: Data, name: String = "") throws -> DocumentFormat {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .docx }
        if head.starts(with: Array("%PDF-".utf8)) { return .pdf }
        // RTF kan ha BOM eller mellomrom først.
        let start = [UInt8](data.prefix(64)).drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        if Array(start.prefix(5)) == Array("{\\rtf".utf8) { return .rtf }
        if looksBinary(data) { throw DocumentToolsError.unknownFormat }
        let lower = name.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return .markdown }
        return .plaintext
    }

    /// Binærfiler (bilder, kjørbare filer) har nullbyte tidlig; UTF-16-tekst har BOM og er unntatt.
    static func looksBinary(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4096))
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        return head.contains(0)
    }
}

/// Navn på det felles avsnittet som kan brukes inni typer som selv har en `Paragraph`.
public typealias DocumentParagraph = Paragraph
