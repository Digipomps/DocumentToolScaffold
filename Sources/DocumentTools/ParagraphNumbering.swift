// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Stabil avsnittsnummerering mellom versjoner (formål B, PDD_dokumentverktoy_2026-11-18).
///
/// Kopiert fra CellScaffold `pdd/argumentkart-native-analyse` 0d1a8078, `ArgumentMapNumbering.swift`
/// (PDD_argumentkart-native-analyse_2026-11-18, A.numbering). Endringer: nytt navn, `public`, og et valgfritt
/// prefiks (standard «A», som gir nøyaktig samme numre som før). Reglene er uendret.
///
/// Port av `number()` i `tools/native.py` v2, kontrollert mot fasiten i `checks/`:
/// 1. Første versjon: A1, A2, …
/// 2. Ny versjon: avsnittene stilles opp mot forrige versjon i rekkefølge (`SequenceMatcher`).
///    Like avsnitt er «uendret». I et område med forskjeller får et avsnitt forrige nummer når likheten
///    er minst 0,5 («endret»), ellers er det forrige avsnittet fjernet.
/// 3. Et avsnitt uten nummer som ligner et fjernet avsnitt med minst 0,8, er «flyttet» og beholder nummeret.
/// 4. Et avsnitt uten nummer som inneholder hele teksten til fjernede avsnitt (minst 20 tegn), er «endret»
///    med nummeret til det første; de andre er «sammenslått» med det.
/// 5. Et fjernet avsnitt som står i sin helhet i et endret avsnitt, er sammenslått med det.
/// 6. Resten er «ny» og får bokstav etter nærmeste foregående nummer (A4 → A4a, A4a → A4b). Et nummer fra
///    forrige versjon brukes aldri om igjen.
public enum ParagraphNumbering {
    public enum Change: String, Codable, Equatable, Sendable {
        case first = "første"
        case unchanged = "uendret"
        case changed = "endret"
        case moved = "flyttet"
        case new = "ny"
    }

    public struct Numbered: Codable, Equatable, Sendable {
        public var ref: String
        public var style: String
        public var text: String
        public var footnotes: [String]
        public var change: Change
        public var similarity: Double?

        public init(ref: String, style: String, text: String, footnotes: [String] = [], change: Change, similarity: Double? = nil) {
            self.ref = ref
            self.style = style
            self.text = text
            self.footnotes = footnotes
            self.change = change
            self.similarity = similarity
        }
    }

    public struct Outcome: Codable, Equatable, Sendable {
        public var paragraphs: [Numbered]
        public var removed: [String]
        /// Fjernet nummer → nummeret det er slått sammen med.
        public var merged: [String: String]

        public init(paragraphs: [Numbered], removed: [String] = [], merged: [String: String] = [:]) {
            self.paragraphs = paragraphs
            self.removed = removed
            self.merged = merged
        }
    }

    static let changedThreshold = 0.5
    static let earlyStopThreshold = 0.95
    static let movedThreshold = 0.8
    static let minimumMergedLength = 20

    /// `norm()`: mellomrom slått sammen, trimmet, små bokstaver.
    static func normalized(_ text: String) -> String {
        TextSupport.collapseWhitespace(text).lowercased()
    }

    public static func number(_ paragraphs: [Paragraph], previous: [Numbered]?, prefix: String = "A") -> Outcome {
        guard let previous, !previous.isEmpty else {
            let numbered = paragraphs.enumerated().map { index, p in
                Numbered(ref: "\(prefix)\(index + 1)", style: p.style, text: p.text, footnotes: p.footnotes, change: .first, similarity: nil)
            }
            return Outcome(paragraphs: numbered, removed: [], merged: [:])
        }

        let a = previous.map { normalized($0.text) }
        let b = paragraphs.map { normalized($0.text) }
        let aScalars = a.map { Array($0.unicodeScalars) }
        let bScalars = b.map { Array($0.unicodeScalars) }
        func ratio(_ i: Int, _ j: Int) -> Double { SequenceMatcher(aScalars[i], bScalars[j]).ratio() }

        var out: [Numbered?] = Array(repeating: nil, count: paragraphs.count)
        var removed: [String] = []
        func assign(_ j: Int, ref: String, change: Change, similarity: Double? = nil) {
            let p = paragraphs[j]
            out[j] = Numbered(ref: ref, style: p.style, text: p.text, footnotes: p.footnotes, change: change, similarity: similarity)
        }

        for op in SequenceMatcher(a, b).opcodes() {
            if op.tag == .equal {
                for k in 0..<(op.i2 - op.i1) { assign(op.j1 + k, ref: previous[op.i1 + k].ref, change: .unchanged) }
                continue
            }
            var jj = op.j1
            for i in op.i1..<op.i2 {
                var best: (j: Int, r: Double)?
                if jj < op.j2 {
                    for j in jj..<op.j2 {
                        let r = ratio(i, j)
                        if r >= changedThreshold && (best == nil || r > best!.r) { best = (j, r) }
                        if let best, best.r > earlyStopThreshold { break }
                    }
                }
                if let best {
                    assign(best.j, ref: previous[i].ref, change: .changed)
                    jj = best.j + 1
                } else {
                    removed.append(previous[i].ref)
                }
            }
        }

        let previousIndex = Dictionary(previous.enumerated().map { ($1.ref, $0) }, uniquingKeysWith: { first, _ in first })

        // 3. Flyttet.
        for j in out.indices where out[j] == nil && !removed.isEmpty {
            var best: (r: Double, ref: String)?
            for i in previous.indices where removed.contains(previous[i].ref) {
                let candidate = (r: ratio(i, j), ref: previous[i].ref)
                // Som Pythons max() over (ratio, ref): høyest likhet, ved likhet størst nummer som tekst.
                if best == nil || candidate.r > best!.r || (candidate.r == best!.r && candidate.ref > best!.ref) { best = candidate }
            }
            if let best, best.r >= movedThreshold {
                assign(j, ref: best.ref, change: .moved, similarity: (best.r * 100).rounded() / 100)
                removed.removeAll { $0 == best.ref }
            }
        }

        // 4. Sammenslått og flyttet.
        var merged: [String: String] = [:]
        for j in out.indices where out[j] == nil && !removed.isEmpty {
            let inside = previous.indices
                .filter { removed.contains(previous[$0].ref) && a[$0].unicodeScalars.count >= minimumMergedLength && b[j].contains(a[$0]) }
                .map { previous[$0].ref }
            guard let first = inside.first else { continue }
            assign(j, ref: first, change: .changed)
            removed.removeAll { $0 == first }
            for ref in inside.dropFirst() { merged[ref] = first }
        }

        // 5. Sammenslått i et endret avsnitt.
        for ref in removed where merged[ref] == nil {
            guard let i = previousIndex[ref], a[i].unicodeScalars.count >= minimumMergedLength else { continue }
            if let host = out.indices.first(where: { out[$0]?.change == .changed && b[$0].contains(a[i]) }) {
                merged[ref] = out[host]!.ref
            }
        }

        // 6. Nye.
        var taken = Set(out.compactMap { $0?.ref }).union(previous.map(\.ref))
        var counters: [String: Int] = [:]
        var last = "\(prefix)0"
        for j in out.indices {
            if let existing = out[j] { last = existing.ref; continue }
            let ref = nextSuffix(after: last, counters: &counters, taken: &taken)
            assign(j, ref: ref, change: .new)
        }
        return Outcome(paragraphs: out.map { $0! }, removed: removed, merged: merged)
    }

    /// A4 → A4a, A4b … og A4a → A4b, A4c …; et nummer som er tatt, hoppes over. Etter «z» legges det til bokstaver.
    static func nextSuffix(after last: String, counters: inout [String: Int], taken: inout Set<String>) -> String {
        let scalars = Array(last.unicodeScalars)
        var baseEnd = scalars.count
        while baseEnd > 0, ("a"..."z").contains(scalars[baseEnd - 1]) { baseEnd -= 1 }
        let base = String(String.UnicodeScalarView(scalars[0..<baseEnd]))
        let start = Array(scalars[baseEnd...])
        let a = Unicode.Scalar("a").value, z = Unicode.Scalar("z").value
        var k = counters[last] ?? 0
        var candidate: String
        repeat {
            let code = start.isEmpty ? a + UInt32(k) : start[start.count - 1].value + 1 + UInt32(k)
            if code > z {
                candidate = last + String(repeating: "a", count: Int(code - z))
            } else {
                let head = String(String.UnicodeScalarView(start.dropLast()))
                candidate = base + head + String(Unicode.Scalar(code)!)
            }
            k += 1
        } while taken.contains(candidate)
        counters[last] = k
        taken.insert(candidate)
        return candidate
    }
}
