// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Versjonsdiff mellom utkast (formål B1): nummereringens utfall som eget resultat.
public struct VersionDiff: Codable, Equatable, Sendable {
    public var changed: [String]
    public var moved: [String]
    public var added: [String]
    public var removed: [String]
    /// Fjernet nummer → nummeret det er slått sammen med.
    public var merged: [String: String]
    /// Likhet med forrige versjon for flyttede avsnitt (0–1, to desimaler).
    public var similarity: [String: Double]

    public init(_ outcome: ParagraphNumbering.Outcome) {
        changed = outcome.paragraphs.filter { $0.change == .changed }.map(\.ref)
        moved = outcome.paragraphs.filter { $0.change == .moved }.map(\.ref)
        added = outcome.paragraphs.filter { $0.change == .new }.map(\.ref)
        removed = outcome.removed
        merged = outcome.merged
        similarity = Dictionary(outcome.paragraphs.compactMap { p in p.similarity.map { (p.ref, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    public var isEmpty: Bool { changed.isEmpty && moved.isEmpty && added.isEmpty && removed.isEmpty && merged.isEmpty }
}

/// Modellklar tekst (formål C, C1, C2, C3).
///
/// Formatet er det samme som `Kildetekst_Utkast5_siste_nummerert.txt` i bokprosjektet:
///
///     [A12] (Heading 2) Tekst i avsnittet.
///       [A12 fotnote 1] Teksten i fotnoten.
///
/// Én linje per avsnitt, fotnoter innrykket under. Samme inndata gir alltid samme byte og samme hash.
public enum ModelReadyText {
    public struct TokenEstimate: Codable, Equatable, Sendable {
        public var value: Int
        public var method: String
        public var isEstimate: Bool
    }

    public struct Chunk: Codable, Equatable, Sendable {
        public var index: Int
        public var refs: [String]
        public var text: String
        public var tokenEstimate: Int
    }

    public struct Prepared: Codable, Equatable, Sendable {
        public var text: String
        public var sha256: String
        public var tokenEstimate: TokenEstimate
        public var chunks: [Chunk]
    }

    /// Samme regel som `AIGatewayModels.estimateTokens` i CellScaffold: tegn / 4, rundet opp, minst 1.
    /// Et anslag. Faktisk forbruk måles av den som kaller modellen.
    public static let tokenMethod = "tegn/4 rundet opp (samme regel som AIGateway i CellScaffold); anslag, ikke telling"

    public static func estimateTokens(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    public static func line(for paragraph: ParagraphNumbering.Numbered) -> String {
        var out = "[\(paragraph.ref)] (\(paragraph.style)) \(paragraph.text)"
        for (n, note) in paragraph.footnotes.enumerated() {
            out += "\n  [\(paragraph.ref) fotnote \(n + 1)] \(note)"
        }
        return out
    }

    /// - Parameter maxTokensPerChunk: øvre grense per bit. `nil` gir én bit. Et avsnitt deles aldri; et avsnitt
    ///   som alene er større enn grensen, blir en egen bit.
    public static func prepare(_ paragraphs: [ParagraphNumbering.Numbered], maxTokensPerChunk: Int? = nil) -> Prepared {
        let lines = paragraphs.map(line(for:))
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        var chunks: [Chunk] = []
        var refs: [String] = []
        var body: [String] = []
        var tokens = 0
        func close() {
            guard !body.isEmpty else { return }
            let chunkText = body.joined(separator: "\n") + "\n"
            chunks.append(Chunk(index: chunks.count, refs: refs, text: chunkText, tokenEstimate: estimateTokens(chunkText)))
            refs = []; body = []; tokens = 0
        }
        for (paragraph, line) in zip(paragraphs, lines) {
            let cost = estimateTokens(line + "\n")
            if let limit = maxTokensPerChunk, limit > 0, !body.isEmpty, tokens + cost > limit { close() }
            refs.append(paragraph.ref)
            body.append(line)
            tokens += cost
        }
        close()
        return Prepared(text: text, sha256: SHA256.hex(text),
                        tokenEstimate: TokenEstimate(value: estimateTokens(text), method: tokenMethod, isEstimate: true),
                        chunks: chunks)
    }

    public struct RefCheck: Codable, Equatable, Sendable {
        public var ok: Bool
        public var unknown: [String]
    }

    /// C3: hvert A-nummer en modell viser til, må finnes i teksten den fikk. Rekkefølgen i `unknown` følger `refs`.
    public static func verifyRefs(_ refs: [String], knownRefs: [String]) -> RefCheck {
        let known = Set(knownRefs)
        var seen = Set<String>()
        let unknown = refs.filter { !known.contains($0) && seen.insert($0).inserted }
        return RefCheck(ok: unknown.isEmpty, unknown: unknown)
    }
}
