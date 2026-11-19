// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import DocumentTools

/// Testene er avledet fra §5 i FORMAALSSPEC (PDD_dokumentverktoy_2026-11-18). Fixturene har bare oppdiktet tekst.
/// Utkast 5 testes bare når `DOCUMENTTOOLS_GOLDEN_DIR` peker på PDD-mappens `golden/`, fordi teksten ikke skal
/// ligge i repoet.
final class DocumentToolsTests: XCTestCase {
    // MARK: - Hjelpere

    private func fixture(_ path: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + path, withExtension: nil), "Mangler Fixtures/\(path)")
        return try Data(contentsOf: url)
    }

    private var goldenDir: URL? {
        ProcessInfo.processInfo.environment["DOCUMENTTOOLS_GOLDEN_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var hasPdftotext: Bool { PDFReader.candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) } }

    private func requirePdftotext() throws {
        if !hasPdftotext { throw XCTSkip("pdftotext (poppler-utils) er ikke installert i dette miljøet.") }
    }

    private func assertCode(_ expression: @autoclosure () throws -> Any, _ codes: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            let code = (error as? DocumentToolsError)?.code ?? (error as? DocxReader.ReadError)?.code ?? "\(error)"
            XCTAssertTrue(codes.contains(code), "fikk \(code), ventet \(codes.sorted())", file: file, line: line)
        }
    }

    /// Samme mål som `evidence/pdf-maaling-20261118/measure.py`: andel avsnitt (minst 20 tegn) i fasiten som
    /// kommer ut som ett avsnitt med samme tekst. Listetegn foran teksten regnes ikke med.
    static func exactShare(truth: [String], extracted: [String]) -> Double {
        func norm(_ s: String) -> String {
            let t = TextSupport.collapseWhitespace(TextSupport.cleanExtracted(s))
            return t.replacingOccurrences(of: #"^(\d+\.|o|•|▪|-|\x{F0B7})\s+"#, with: "", options: .regularExpression)
        }
        let wanted = truth.filter { $0.count >= 20 }.map(norm)
        let got = Set(extracted.map(norm))
        guard !wanted.isEmpty else { return 0 }
        return Double(wanted.filter(got.contains).count) / Double(wanted.count)
    }

    // MARK: - SHA-256

    func testSHA256MatchesKnownVectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1_000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: - test.dv.docx-unchanged (A1), kopiert fra ArgumentMapNativeTests i CellScaffold 0d1a8078

    private struct Expected: Decodable {
        struct Paragraph: Decodable { var ref: String; var style: String; var change: String; var footnotes: [String] }
        struct Version: Decodable { var paragraphs: [Paragraph]; var removed: [String]?; var merged: [String: String]? }
        var v1: Version
        var v2_against_v1: Version
        var v3_against_v2: Version
    }

    private struct SourceFixture: Decodable {
        struct Row: Decodable { var style: String; var text: String }
        var paragraphs: [Row]
    }

    private func expected() throws -> Expected { try JSONDecoder().decode(Expected.self, from: fixture("docx/forventet.json")) }

    private func assertVersion(_ outcome: ParagraphNumbering.Outcome, _ expected: Expected.Version, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.paragraphs.map(\.ref), expected.paragraphs.map(\.ref), "numre", file: file, line: line)
        XCTAssertEqual(outcome.paragraphs.map(\.change.rawValue), expected.paragraphs.map(\.change), "endringstype", file: file, line: line)
        XCTAssertEqual(outcome.paragraphs.map(\.style), expected.paragraphs.map(\.style), "stil", file: file, line: line)
        XCTAssertEqual(outcome.paragraphs.map(\.footnotes), expected.paragraphs.map(\.footnotes), "fotnoter", file: file, line: line)
        XCTAssertEqual(outcome.removed, expected.removed ?? [], "fjernet", file: file, line: line)
        XCTAssertEqual(outcome.merged, expected.merged ?? [:], "sammenslått", file: file, line: line)
    }

    private func versions() throws -> (v1: ParagraphNumbering.Outcome, v2: ParagraphNumbering.Outcome, v3: ParagraphNumbering.Outcome) {
        let v1 = ParagraphNumbering.number(try DocxReader.read(data: fixture("docx/syntetisk_v1.docx")), previous: nil)
        let v2 = ParagraphNumbering.number(try DocxReader.read(data: fixture("docx/syntetisk_v2.docx")), previous: v1.paragraphs)
        let v3 = ParagraphNumbering.number(try DocxReader.read(data: fixture("docx/syntetisk_v3.docx")), previous: v2.paragraphs)
        return (v1, v2, v3)
    }

    func testDocxReaderReadsParagraphsStylesAndFootnotesInOrder() throws {
        let paragraphs = try DocxReader.read(data: fixture("docx/syntetisk_v2.docx"))
        let source = try JSONDecoder().decode(SourceFixture.self, from: fixture("docx/forventet_v2.source.json"))
        XCTAssertEqual(paragraphs.map(\.text), source.paragraphs.map(\.text))
        XCTAssertEqual(paragraphs.map(\.style), source.paragraphs.map(\.style))
        XCTAssertEqual(paragraphs[2].style, "Heading 1")
        XCTAssertEqual(paragraphs[6].style, "Quote")
        XCTAssertEqual(paragraphs[11].footnotes.count, 3)
    }

    func testDocxReaderRejectsFilesThatAreNotWordDocuments() throws {
        XCTAssertThrowsError(try DocxReader.read(data: fixture("docx/ikke_zip.docx"))) { XCTAssertEqual($0 as? DocxReader.ReadError, .notADocx) }
        XCTAssertThrowsError(try DocxReader.read(data: fixture("docx/mangler_document.docx"))) { XCTAssertEqual($0 as? DocxReader.ReadError, .missingDocument) }
        XCTAssertThrowsError(try DocxReader.read(data: Data(count: DocxReader.maxBytes + 1))) { XCTAssertEqual(($0 as? DocxReader.ReadError)?.code, "too-large") }
    }

    // MARK: - test.dv.numbering-fasit (B)

    func testSequenceMatcherMatchesDifflib() {
        XCTAssertEqual(SequenceMatcher<Unicode.Scalar>.ratio("abcd", "bcde"), 0.75, accuracy: 1e-12)
        XCTAssertEqual(SequenceMatcher<Unicode.Scalar>.ratio("", ""), 1.0)
        XCTAssertEqual(SequenceMatcher<Unicode.Scalar>.ratio("havn", "havna"), 8.0 / 9.0, accuracy: 1e-12)
        let ops = SequenceMatcher(Array("qabxcd"), Array("abycdf")).opcodes().map { "\($0.tag.rawValue) \($0.i1) \($0.i2) \($0.j1) \($0.j2)" }
        XCTAssertEqual(ops, ["delete 0 1 0 0", "equal 1 3 0 2", "replace 3 4 2 3", "equal 4 6 3 5", "insert 6 6 5 6"])
    }

    func testFirstVersionIsNumberedFromA1() throws {
        let (v1, _, _) = try versions()
        assertVersion(v1, try expected().v1)
        XCTAssertTrue(v1.paragraphs.allSatisfy { $0.change == .first })
    }

    func testSecondVersionKeepsNumbersAndMarksChangedMovedMergedAndNew() throws {
        let (_, v2, _) = try versions()
        assertVersion(v2, try expected().v2_against_v1)
    }

    func testThirdVersionNeverReusesANumberFromThePreviousVersion() throws {
        let (_, _, v3) = try versions()
        assertVersion(v3, try expected().v3_against_v2)
        XCTAssertEqual(v3.paragraphs.first { $0.change == .new }?.ref, "A4c", "A4a var brukt i forrige versjon")
    }

    func testSuffixesAfterZAddLetters() {
        var counters: [String: Int] = [:]
        var taken: Set<String> = ["A4z"]
        XCTAssertEqual(ParagraphNumbering.nextSuffix(after: "A4y", counters: &counters, taken: &taken), "A4ya")
        XCTAssertEqual(ParagraphNumbering.nextSuffix(after: "A9", counters: &counters, taken: &taken), "A9a")
        XCTAssertEqual(ParagraphNumbering.nextSuffix(after: "A9", counters: &counters, taken: &taken), "A9b")
    }

    func testPrefixDefaultsToAAndCanBeChanged() throws {
        let paragraphs = try DocxReader.read(data: fixture("docx/syntetisk_v1.docx"))
        XCTAssertEqual(ParagraphNumbering.number(paragraphs, previous: nil).paragraphs.first?.ref, "A1")
        let p = ParagraphNumbering.number(paragraphs, previous: nil, prefix: "P")
        XCTAssertEqual(p.paragraphs.map(\.ref), (1...paragraphs.count).map { "P\($0)" })
    }

    // MARK: - test.dv.diff-fasit (B1)

    func testVersionDiffListsEveryChangeFromTheNumbering() throws {
        let (_, v2, _) = try versions()
        let diff = VersionDiff(v2)
        XCTAssertEqual(diff.changed, v2.paragraphs.filter { $0.change == .changed }.map(\.ref))
        XCTAssertEqual(diff.moved, v2.paragraphs.filter { $0.change == .moved }.map(\.ref))
        XCTAssertEqual(diff.added, v2.paragraphs.filter { $0.change == .new }.map(\.ref))
        XCTAssertEqual(diff.removed, v2.removed)
        XCTAssertEqual(diff.merged, v2.merged)
        XCTAssertFalse(diff.isEmpty)
        let (v1, _, _) = try versions()
        XCTAssertTrue(VersionDiff(ParagraphNumbering.number(try DocxReader.read(data: fixture("docx/syntetisk_v1.docx")), previous: v1.paragraphs)).isEmpty,
                      "samme dokument to ganger gir ingen endringer")
    }

    // MARK: - Utkast 5 (bare med DOCUMENTTOOLS_GOLDEN_DIR)

    func testUtkast5NumberingMatchesHandCheckedFasit() throws {
        guard let dir = goldenDir else { throw XCTSkip("DOCUMENTTOOLS_GOLDEN_DIR er ikke satt; Utkast 5 ligger bare i PDD-mappen.") }
        struct Fasit: Decodable {
            struct Numbering: Decodable {
                struct Row: Decodable { var ref: String; var change: String }
                var paragraphs: [Row]; var removed: [String]; var merged: [String: String]
            }
            var numbering: Numbering
        }
        let fasit = try JSONDecoder().decode(Fasit.self, from: Data(contentsOf: dir.appendingPathComponent("fasit_art2_art3.json")))
        let previous = try Self.parseNumberedText(String(contentsOf: dir.appendingPathComponent("previous_numbered.txt"), encoding: .utf8))
        let current = try DocxReader.read(data: Data(contentsOf: dir.appendingPathComponent("current.docx")))
        let outcome = ParagraphNumbering.number(current, previous: previous)
        XCTAssertEqual(outcome.paragraphs.map(\.ref), fasit.numbering.paragraphs.map(\.ref))
        XCTAssertEqual(outcome.paragraphs.map(\.change.rawValue), fasit.numbering.paragraphs.map(\.change))
        XCTAssertEqual(outcome.removed, fasit.numbering.removed)
        XCTAssertEqual(outcome.merged, fasit.numbering.merged)
    }

    func testUtkast5PDFReachesThreshold() throws {
        guard let dir = goldenDir else { throw XCTSkip("DOCUMENTTOOLS_GOLDEN_DIR er ikke satt.") }
        try requirePdftotext()
        let truth = try DocxReader.read(data: Data(contentsOf: dir.appendingPathComponent("current.docx"))).map(\.text)
        let pdf = try PDFReader.read(data: Data(contentsOf: dir.appendingPathComponent("art3.pdf")))
        let share = Self.exactShare(truth: truth, extracted: pdf.paragraphs.map(\.text))
        print("MÅLING utkast5-art3.pdf eksakte avsnitt: \(String(format: "%.1f", share * 100)) %")
        XCTAssertGreaterThanOrEqual(share, 0.90)
    }

    /// Formatet i `Kildetekst_Utkast5_siste_nummerert.txt`: «[A12] (Normal) tekst», med gamle markører «[ny]»/«[endret]».
    static func parseNumberedText(_ text: String) throws -> [ParagraphNumbering.Numbered] {
        let line = try NSRegularExpression(pattern: #"^\[(A\d+[a-z]?|FB\d+)\]\s*(?:\[endret\]\s*)?\(([^)]*)\)\s*(.*)$"#)
        let marker = try NSRegularExpression(pattern: #"^(\[(ny|endret)\]\s*)+"#)
        return text.components(separatedBy: "\n").compactMap { raw in
            guard let m = line.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let r = Range(m.range(at: 1), in: raw), let s = Range(m.range(at: 2), in: raw), let t = Range(m.range(at: 3), in: raw) else { return nil }
            let body = String(raw[t]).trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = marker.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            return .init(ref: String(raw[r]), style: String(raw[s]), text: clean, footnotes: [], change: .first, similarity: nil)
        }
    }

    // MARK: - test.dv.txt-encodings (A3)

    func testPlainTextReadsTheSameParagraphsInThreeEncodings() throws {
        let wanted = ["Havna i Nordvik får ny kai. Den skal stå ferdig i 2027.",
                      "Blåbær, ærlig øl og «sitater» – med tankestrek.",
                      "Siste avsnitt uten linjeskift til slutt."]
        for name in ["norsk_utf8", "norsk_utf16le", "norsk_cp1252"] {
            let doc = try DocumentIntake.read(data: fixture("text/\(name).txt"), name: "\(name).txt")
            XCTAssertEqual(doc.format, .plaintext, name)
            XCTAssertEqual(doc.paragraphs.map(\.text), wanted, name)
            XCTAssertTrue(doc.paragraphs.allSatisfy { $0.style == "Normal" }, name)
            XCTAssertEqual(doc.warnings.isEmpty, name != "norsk_cp1252", name)
        }
    }

    // MARK: - test.dv.md-fixture (A2)

    func testMarkdownGivesHeadingsListsQuoteCodeAndFootnotes() throws {
        let doc = try DocumentIntake.read(data: fixture("text/syntetisk.md"), name: "syntetisk.md")
        XCTAssertEqual(doc.format, .markdown)
        let wanted: [Paragraph] = [
            Paragraph(style: "Heading 1", text: "Fiktiv havneplan"),
            Paragraph(style: "Normal", text: "Havna i Nordvik får ny kai. Arbeidet starter i **2026**.", footnotes: ["Havneplan for Nordvik 2024–2030."]),
            Paragraph(style: "Heading 2", text: "Mål"),
            Paragraph(style: "List Paragraph", text: "Bedre plass for fiskebåter"),
            Paragraph(style: "List Paragraph", text: "Nye lys på moloen, også om vinteren"),
            Paragraph(style: "List Paragraph", text: "Første fase"),
            Paragraph(style: "List Paragraph", text: "Andre fase"),
            Paragraph(style: "Quote", text: "«Vi må gjøre noe nå», sa en fiktiv havnesjef. Ingen har sagt dette."),
            Paragraph(style: "Heading 2", text: "Undertittel med understrek"),
            Paragraph(style: "Code", text: "kode linje 1\nkode linje 2"),
            Paragraph(style: "Normal", text: "Siste avsnitt viser til to kilder og en [lenke](https://example.org).",
                      footnotes: ["Fiktiv kilde. Fortsetter på neste linje.", "Andre fiktive kilde."]),
        ]
        XCTAssertEqual(doc.paragraphs.count, wanted.count)
        for (got, want) in zip(doc.paragraphs, wanted) { XCTAssertEqual(got, want) }
    }

    // MARK: - test.dv.rtf-fixture (A4)

    func testRTFFromLibreOfficeGivesTheSameTextAsTheDocx() throws {
        let docx = try DocxReader.read(data: fixture("docx/syntetisk_v2.docx"))
        let doc = try DocumentIntake.read(data: fixture("rtf/syntetisk_v2.rtf"), name: "syntetisk_v2.rtf")
        XCTAssertEqual(doc.format, .rtf)
        XCTAssertEqual(doc.paragraphs.map(\.text), docx.map(\.text))
        XCTAssertEqual(doc.paragraphs.map { $0.style.hasPrefix("Heading") ? $0.style : "-" }, docx.map { $0.style.hasPrefix("Heading") ? $0.style : "-" })
        XCTAssertEqual(doc.paragraphs.map(\.footnotes.count), docx.map(\.footnotes.count))
        // Kjent avvik: LibreOffice skriver ikke Word-stilen «Quote» som avsnittsstil i RTF.
    }

    func testRTFHandlesUnicodeHexAndEscapes() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0 Times;}}{\stylesheet{\s0 Normal;}{\s1 heading 1;}}"#
            + #"{\pard\s1 Overskrift\par}{\pard bl\'e5b\'e6r \u248?l og \{klammer\}\line ny linje{\*\footnote \pard Fotnote her.}\par}}"#
        let paragraphs = try RTFReader.read(data: Data(rtf.utf8))
        XCTAssertEqual(paragraphs, [
            Paragraph(style: "Heading 1", text: "Overskrift"),
            Paragraph(style: "Normal", text: "blåbær øl og {klammer} ny linje", footnotes: ["Fotnote her."]),
        ])
    }

    // MARK: - test.dv.pdf-fixture og test.dv.pdf-scanned-refused (A5)

    func testTwoColumnPDFReachesThreshold() throws {
        try requirePdftotext()
        let truth = String(decoding: try fixture("pdf/tospalte.truth.tsv"), as: UTF8.self)
            .split(separator: "\n").compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
        let pdf = try PDFReader.read(data: fixture("pdf/tospalte.pdf"))
        let share = Self.exactShare(truth: truth, extracted: pdf.paragraphs.map(\.text))
        print("MÅLING tospalte.pdf eksakte avsnitt: \(String(format: "%.1f", share * 100)) %")
        XCTAssertGreaterThanOrEqual(share, 0.90)
        XCTAssertFalse(pdf.warnings.isEmpty, "PDF skal alltid si at avsnittene er beregnet")
    }

    /// Paritet med Python-referansen `tools/pdf_ref.py`. Referansen ble laget med poppler 24.02 (Ubuntu Noble,
    /// samme som prod). Andre poppler-versjoner kan plassere ord litt annerledes, så paritet kreves bare på Linux.
    func testPDFMatchesPythonReferenceOnLinux() throws {
        #if os(Linux)
        try requirePdftotext()
        for name in ["syntetisk_v2", "tospalte"] {
            let reference = try JSONDecoder().decode([Paragraph].self, from: fixture("pdf/\(name).reference.json"))
            let got = try PDFReader.read(data: fixture("pdf/\(name).pdf")).paragraphs
            XCTAssertEqual(got.count, reference.count, name)
            for (g, r) in zip(got, reference) { XCTAssertEqual(g, r, name) }
        }
        #else
        throw XCTSkip("Paritet mot referansen kreves bare på Linux (poppler 24.02).")
        #endif
    }

    func testScannedPDFIsRefusedNotEmpty() throws {
        try requirePdftotext()
        assertCode(try PDFReader.read(data: fixture("pdf/skannet.pdf")), ["no-text-layer"])
    }

    func testMissingPopplerGivesItsOwnError() throws {
        let saved = PDFReader.pathsOverride
        defer { PDFReader.pathsOverride = saved }
        PDFReader.pathsOverride = ["/finnes/ikke/pdftotext"]
        assertCode(try PDFReader.read(data: fixture("pdf/tospalte.pdf")), ["pdf-engine-missing"])
    }

    // MARK: - test.dv.hostile-inputs (A6)

    func testHostileInputsStopSafely() throws {
        assertCode(try DocumentIntake.read(data: fixture("hostile/zipbombe.docx"), name: "a.docx"), ["too-large"])
        assertCode(try DocumentIntake.read(data: fixture("hostile/avkuttet.docx"), name: "a.docx"), ["not-a-docx", "unreadable-xml", "missing-document-xml"])
        assertCode(try DocumentIntake.read(data: fixture("hostile/tom.txt"), name: "tom.txt"), ["empty-document"])
        assertCode(try DocumentIntake.read(data: fixture("hostile/bilde.png"), name: "bilde.docx"), ["unknown-format"])
        assertCode(try DocumentIntake.read(data: Data(count: DocumentIntake.maxBytes + 1), name: "stor.txt"), ["too-large"])

        // XXE: en ekstern entitet skal aldri hentes. Enten avvises filen, eller teksten er uten innholdet.
        do {
            let doc = try DocumentIntake.read(data: fixture("hostile/xxe.docx"), name: "xxe.docx")
            XCTAssertFalse(doc.paragraphs.map(\.text).joined().contains("root:"))
        } catch let error as DocumentToolsError {
            XCTAssertTrue(["unreadable-xml", "empty-document"].contains(error.code), error.code)
        }
    }

    func testFormatIsDecidedByContentNotName() throws {
        XCTAssertEqual(try DocumentIntake.detectFormat(data: fixture("hostile/pdf_med_feil_endelse.docx"), name: "rapport.docx"), .pdf)
        XCTAssertEqual(try DocumentIntake.detectFormat(data: fixture("rtf/syntetisk_v2.rtf"), name: "notat.txt"), .rtf)
        XCTAssertEqual(try DocumentIntake.detectFormat(data: fixture("docx/syntetisk_v1.docx"), name: "x.pdf"), .docx)
        XCTAssertEqual(try DocumentIntake.detectFormat(data: Data("# Tittel".utf8), name: "x.md"), .markdown)
        XCTAssertEqual(try DocumentIntake.detectFormat(data: Data("# Tittel".utf8), name: "x.txt"), .plaintext)
    }

    func testSourceHashIsTheHashOfTheFileBytes() throws {
        let data = try fixture("text/norsk_utf8.txt")
        XCTAssertEqual(try DocumentIntake.read(data: data, name: "a.txt").sourceSHA256, SHA256.hex(data))
    }

    // MARK: - test.dv.prepared-deterministic, chunks-boundaries, token-estimate-labelled, refs-check (C–C3)

    private func numberedV2() throws -> [ParagraphNumbering.Numbered] {
        ParagraphNumbering.number(try DocxReader.read(data: fixture("docx/syntetisk_v2.docx")), previous: nil).paragraphs
    }

    func testPreparedTextIsDeterministicAndUsesTheNumberedFormat() throws {
        let numbered = try numberedV2()
        let a = ModelReadyText.prepare(numbered)
        let b = ModelReadyText.prepare(try numberedV2())
        XCTAssertEqual(a.text, b.text)
        XCTAssertEqual(a.sha256, b.sha256)
        XCTAssertEqual(a.sha256, SHA256.hex(a.text))
        XCTAssertTrue(a.text.hasPrefix("[A1] (\(numbered[0].style)) \(numbered[0].text)\n"))
        XCTAssertTrue(a.text.contains("\n  [A12 fotnote 3] "), "fotnoter står innrykket under avsnittet")
        XCTAssertEqual(a.chunks.count, 1)
        XCTAssertEqual(a.chunks[0].text, a.text)
    }

    func testChunksNeverSplitAParagraphAndListTheirRefs() throws {
        let numbered = try numberedV2()
        let prepared = ModelReadyText.prepare(numbered, maxTokensPerChunk: 60)
        XCTAssertGreaterThan(prepared.chunks.count, 1)
        XCTAssertEqual(prepared.chunks.flatMap(\.refs), numbered.map(\.ref), "alle avsnitt én gang, i rekkefølge")
        XCTAssertEqual(prepared.chunks.map(\.text).joined(), prepared.text, "bitene satt sammen er hele teksten")
        for chunk in prepared.chunks {
            XCTAssertEqual(chunk.refs.count, chunk.text.split(separator: "\n").filter { $0.hasPrefix("[") }.count)
            XCTAssertTrue(chunk.tokenEstimate <= 60 || chunk.refs.count == 1, "bare et avsnitt som alene er for stort, kan gå over grensen")
        }
        XCTAssertEqual(prepared.chunks.map(\.index), Array(0..<prepared.chunks.count))
    }

    func testTokenEstimateIsLabelledAsAnEstimate() throws {
        let prepared = ModelReadyText.prepare(try numberedV2())
        XCTAssertTrue(prepared.tokenEstimate.isEstimate)
        XCTAssertTrue(prepared.tokenEstimate.method.contains("anslag"))
        XCTAssertEqual(prepared.tokenEstimate.value, Int((Double(prepared.text.count) / 4).rounded(.up)))
        XCTAssertEqual(ModelReadyText.estimateTokens(""), 1)
    }

    func testRefsCheckRejectsUnknownNumbers() throws {
        let known = try numberedV2().map(\.ref)
        XCTAssertEqual(ModelReadyText.verifyRefs(["A1", "A3"], knownRefs: known), .init(ok: true, unknown: []))
        XCTAssertEqual(ModelReadyText.verifyRefs(["A1", "A999", "A2b", "A999"], knownRefs: known), .init(ok: false, unknown: ["A999", "A2b"]))
    }

    // MARK: - test.dv.purposes-listed (D3)

    func testPurposesAreUniqueAndListedInReadme() throws {
        let refs = DocumentToolPurposes.refs
        XCTAssertEqual(Set(refs).count, refs.count, "formålsreferansene er unike")
        XCTAssertEqual(Set(DocumentToolPurposes.all.map(\.code)).count, refs.count, "kodene er unike")
        XCTAssertTrue(refs.contains(DocumentToolPurposes.root))
        for purpose in DocumentToolPurposes.all {
            XCTAssertFalse(purpose.goal.isEmpty, "\(purpose.code) har et mål")
        }
        XCTAssertEqual(DocumentToolPurposes.all.first { $0.code == "E" }?.availability, .parked)
        // README-en ved pakkeroten skal ha nøyaktig de samme referansene.
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"purpose://candidate\.dokumentverktoy\.[a-z0-9.-]+"#)
        let inReadme = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        XCTAssertEqual(inReadme, Set(refs), "README og DocumentToolPurposes har samme formål")
    }
}
