// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum TextSupport {
    /// Mellomrom slås sammen og trimmes, som Pythons `re.sub(r"\s+", " ", t).strip()`.
    /// Kopiert fra `DocxReader.collapseWhitespace` (CellScaffold 0d1a8078) uten endring.
    public static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Pythons `\s` for `str`: Unicode-mellomrom pluss kontrolltegnene 0x1C–0x1F.
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if (0x09...0x0D).contains(scalar.value) || (0x1C...0x20).contains(scalar.value) { return true }
        return scalar.properties.isWhitespace
    }

    /// Kanoniske stilnavn, så norsk og engelsk Word gir samme navn.
    public static func canonicalStyleName(_ name: String) -> String {
        switch name.lowercased() {
        case "heading 1": return "Heading 1"
        case "heading 2": return "Heading 2"
        case "heading 3": return "Heading 3"
        case "normal": return "Normal"
        default: return name
        }
    }

    /// Fjerner myk bindestrek og bytter ligaturer som PDF-er ofte har.
    static func cleanExtracted(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00AD}", with: "")
        for (from, to) in [("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }
}

/// Tegnkoding for tekstfiler (formål A3): UTF-8, UTF-16 med BOM, ellers Windows-1252.
enum TextDecoding {
    static func decode(_ data: Data, warnings: inout [String]) throws -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let s = String(data: data.dropFirst(3), encoding: .utf8) else { throw unsupported }
            return s
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { throw unsupported }
            return s
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { throw unsupported }
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Ikke gyldig UTF-8: Windows-1252 dekker norske tegn i eldre filer.
        guard let s = String(data: data, encoding: .windowsCP1252) else { throw unsupported }
        warnings.append("Filen var ikke UTF-8 og er lest som Windows-1252.")
        return s
    }

    static let unsupported = DocumentToolsError("unsupported-encoding", "Tegnkodingen i filen er ikke støttet.")
}
