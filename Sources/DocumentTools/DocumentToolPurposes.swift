// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// What DocumentToolScaffold is for, as purposes other scaffolds can query.
///
/// This list is the single source in code. `README.md` lists the same references, and the cell
/// (`cell:///DocumentTools`, planned) returns them through `ExploreManifest.intent.purposeRefs` and the
/// `purposes` key path. The purpose tree and its goals are kept in the PDD (`PDD_dokumentverktoy_2026-11-18`).
public enum DocumentToolPurposes {
    public enum Availability: String, Codable, Sendable {
        /// Implemented and tested in the `DocumentTools` library.
        case available
        /// Agreed purpose, not built yet.
        case planned
        /// Deferred to a separate PDD.
        case parked
    }

    public struct Purpose: Codable, Equatable, Sendable {
        public var code: String
        public var ref: String
        public var title: String
        public var goal: String
        public var availability: Availability
    }

    public static let root = "purpose://candidate.dokumentverktoy.root"

    public static let all: [Purpose] = [
        p("root", "root", "Read, number and prepare documents once, natively, for every scaffold",
          "A scaffold that has a document gets numbered, structured text without writing its own reader and without spending model tokens on reading it.", .available),
        p("A", "read", "Read five formats into one common format",
          "docx, pdf, md, rtf and txt give the same structure: paragraphs with style, text and footnotes, plus format, warnings and source hash.", .available),
        p("A1", "read.docx", "Word documents", "Paragraphs, style names and footnotes, unchanged from the argument map reader.", .available),
        p("A2", "read.markdown", "Markdown", "Headings, lists, quotes and code blocks get their own style; [^1] footnotes are collected.", .available),
        p("A3", "read.plaintext", "Plain text", "Paragraphs split on blank lines; UTF-8, UTF-16 with BOM and Windows-1252 are recognised.", .available),
        p("A4", "read.rtf", "RTF", "Own reader: paragraphs, \\u and \\'hh characters, heading styles from the stylesheet, footnotes.", .available),
        p("A5", "read.pdf", "PDF with a text layer",
          "poppler pdftotext plus our own paragraph layer: at least 90 % exact paragraphs on the reference PDFs. A scanned PDF gives no-text-layer, not empty text.", .available),
        p("A6", "read.safe-input", "Hostile files stop safely",
          "Format is decided by content, not file name; size limit; no network; XML without external entities; every error has a code.", .available),
        p("B", "number", "Number paragraphs stably across versions",
          "A-numbers, letter suffixes for new paragraphs, numbers never reused, and a change outcome against the previous version. The prefix can be set.", .available),
        p("B1", "number.version-diff", "Version diff between drafts", "Changed, moved, new, removed and merged paragraphs with similarity, as its own result.", .available),
        p("C", "model-ready", "Finished text for a model", "One deterministic text ([A12] (Heading 2) …, footnotes under the paragraph) with a hash.", .available),
        p("C1", "model-ready.chunks", "Chunks for the model window", "Split on paragraph boundaries within a token budget; a paragraph is never split; each chunk lists its A-numbers.", .available),
        p("C2", "model-ready.token-estimate", "Token estimate before a run", "Estimate per document and per chunk, labelled as an estimate with its method.", .available),
        p("C3", "model-ready.refs-check", "The model's A-numbers exist", "Every A-number in a model answer must exist in the text the model was given.", .available),
        p("D", "reach", "Other scaffolds can use it", "A Swift library for use in the same process, and a cell for use over CellBridge.", .available),
        p("D1", "reach.library", "Library without cells", "DocumentTools depends only on Foundation, FoundationXML and ZIPFoundation, and builds on macOS and Linux.", .available),
        p("D2", "reach.cell", "Cell with key paths", "cell:///DocumentTools with read, number, prepare and diff; data in the payload, no file on disk.", .available),
        p("D3", "reach.announced", "Purposes are readable and queryable",
          "This list is in the README and in code, and the cell answers it over CellProtocol (ExploreManifest purposeRefs and the purposes key path).", .available),
        p("D4", "reach.argumentmap-uses-it", "The argument map uses the tool", "ArgumentMapCell imports DocumentTools with no changed behaviour.", .planned),
        p("D5", "reach.admin-entry", "AdminScaffold is the way into the rest of HAVEN",
          "The scaffold is configured with the AdminScaffold endpoint, registers there with owner, purposes and instance identity, and finds other scaffolds and purposes through it.", .planned),
        p("E", "paid", "Paid use with micropayments", "Deferred to a separate PDD.", .parked),
        p("F", "operations", "Operations are visible to AdminScaffold", "The scaffold emits operational events as a Flow, and AdminScaffold subscribes to it.", .planned),
        p("F1", "operations.events", "Operational events without content",
          "Start, stop, read completed, read failed (error code), pdf-engine-missing, timeout and health. Format, size, duration and error code only; never document text, file names or source hashes.", .available),
        p("F2", "operations.admin-subscribes", "AdminScaffold subscribes", "AdminScaffold attaches to the flow with an admin.observer proof; without a proof the subscription is refused.", .planned),
        p("G", "ownership", "Digipomps owns the scaffold",
          "The owner is the Digipomps group identity (Stiftelsen Digipomps, org. no. 922 135 134), with Kjetil and Vegar as group owner members, declared in a signed service description that AdminScaffold reads.", .planned),
    ]

    /// Purposes that the library fulfils today.
    public static var available: [Purpose] { all.filter { $0.availability == .available } }

    /// Every reference, as `ExploreManifest.intent.purposeRefs` will carry them.
    public static var refs: [String] { all.map(\.ref) }

    private static func p(_ code: String, _ path: String, _ title: String, _ goal: String, _ availability: Availability) -> Purpose {
        Purpose(code: code, ref: "purpose://candidate.dokumentverktoy.\(path)", title: title, goal: goal, availability: availability)
    }
}

/// Who owns DocumentToolScaffold (purpose G). A declaration only: HAVEN's organisation model
/// (group identities with governance policy) is not on CellProtocol main yet, so nothing is enforced here.
public enum DocumentToolOwnership {
    public static let ownerGroup = "Digipomps"
    public static let ownerLegalEntity = "Stiftelsen Digipomps (org. no. 922 135 134)"
    public static let groupOwnerMembers = ["Kjetil", "Vegar"]
}
