// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Port av Pythons `difflib.SequenceMatcher` uten søppelheuristikk (`isjunk=None, autojunk=False`).
///
/// Kopiert uendret fra CellScaffold 0d1a8078 (`SequenceMatcher.swift`), bortsett fra `public`.
///
/// Den native analysen er spesifisert og kontrollert med Python-referansen `tools/native.py` i PDD-mappen
/// (PDD_argumentkart-native-analyse_2026-11-18). For at nummereringen skal bli lik, må sammenligningen
/// gi de samme blokkene og den samme likheten som `difflib`. Algoritmen er derfor tatt over steg for steg:
/// lengste felles blokk, rekursiv deling, sortering, sammenslåing av naboblokker og opkoder.
public struct SequenceMatcher<Element: Hashable> {
    public struct Match: Equatable { public var a: Int; public var b: Int; public var size: Int }
    public enum Tag: String { case equal, replace, delete, insert }
    public struct Opcode: Equatable { public var tag: Tag; public var i1: Int; public var i2: Int; public var j1: Int; public var j2: Int }

    public let a: [Element]
    public let b: [Element]
    private let b2j: [Element: [Int]]

    public init(_ a: [Element], _ b: [Element]) {
        self.a = a
        self.b = b
        var index: [Element: [Int]] = [:]
        for (position, element) in b.enumerated() { index[element, default: []].append(position) }
        self.b2j = index
    }

    /// `find_longest_match(alo, ahi, blo, bhi)`. Ved like lange blokker vinner den som starter først i `a`,
    /// og deretter først i `b`, slik som i Python.
    public func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Match {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            if let positions = b2j[a[i]] {
                for j in positions {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
            }
            j2len = newj2len
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
        return Match(a: besti, b: bestj, size: bestsize)
    }

    /// `get_matching_blocks()`, med vaktblokken `(len(a), len(b), 0)` til slutt.
    public func matchingBlocks() -> [Match] {
        var queue: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]
        var blocks: [Match] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = longestMatch(alo, ahi, blo, bhi)
            if m.size > 0 {
                blocks.append(m)
                if alo < m.a && blo < m.b { queue.append((alo, m.a, blo, m.b)) }
                if m.a + m.size < ahi && m.b + m.size < bhi { queue.append((m.a + m.size, ahi, m.b + m.size, bhi)) }
            }
        }
        blocks.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
        var collapsed: [Match] = []
        var i1 = 0, j1 = 0, k1 = 0
        for m in blocks {
            if i1 + k1 == m.a && j1 + k1 == m.b {
                k1 += m.size
            } else {
                if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
                i1 = m.a; j1 = m.b; k1 = m.size
            }
        }
        if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
        collapsed.append(Match(a: a.count, b: b.count, size: 0))
        return collapsed
    }

    /// `get_opcodes()`.
    public func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var result: [Opcode] = []
        for m in matchingBlocks() {
            let tag: Tag?
            if i < m.a && j < m.b { tag = .replace } else if i < m.a { tag = .delete } else if j < m.b { tag = .insert } else { tag = nil }
            if let tag { result.append(Opcode(tag: tag, i1: i, i2: m.a, j1: j, j2: m.b)) }
            i = m.a + m.size
            j = m.b + m.size
            if m.size > 0 { result.append(Opcode(tag: .equal, i1: m.a, i2: i, j1: m.b, j2: j)) }
        }
        return result
    }

    /// `ratio()`: 2·M / (len(a) + len(b)), og 1 når begge er tomme.
    public func ratio() -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1.0 }
        let matches = matchingBlocks().reduce(0) { $0 + $1.size }
        return 2.0 * Double(matches) / Double(total)
    }
}

extension SequenceMatcher where Element == Unicode.Scalar {
    /// Likhet mellom to tekster, tegn for tegn (Unicode-skalarer, som `str` i Python).
    public static func ratio(_ lhs: String, _ rhs: String) -> Double {
        SequenceMatcher(Array(lhs.unicodeScalars), Array(rhs.unicodeScalars)).ratio()
    }
}
