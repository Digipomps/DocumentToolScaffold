// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// An operational event (purpose F1). It says that something happened and how it went, never what the
/// document said: the type has no field for text, file names or hashes, so a caller cannot put them in.
public struct DocumentToolOpsEvent: Codable, Equatable, Sendable {
    public static let topic = "documenttools.ops.v1"

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case started
        case stopped
        case readCompleted = "read.completed"
        case readFailed = "read.failed"
        case pdfEngineMissing = "pdf-engine-missing"
        case timeout
        case health
    }

    public var kind: Kind
    /// ISO 8601, UTC.
    public var at: String
    /// `docx`, `pdf`, `markdown`, `rtf` or `plaintext`, when known.
    public var format: String?
    public var bytes: Int?
    public var paragraphs: Int?
    public var durationMs: Int?
    /// A `DocumentToolsError` code, for `read.failed`, `pdf-engine-missing` and `timeout`.
    public var errorCode: String?
    /// For `health`: `ok` or `degraded`, with stable reason codes such as `pdf-engine-missing` or `admin-endpoint-missing`.
    public var status: String?
    public var reasons: [String]?

    public init(kind: Kind, at: Date = Date(), format: String? = nil, bytes: Int? = nil, paragraphs: Int? = nil,
                durationMs: Int? = nil, errorCode: String? = nil, status: String? = nil, reasons: [String]? = nil) {
        self.kind = kind
        self.at = Self.timestamp(at)
        self.format = format
        self.bytes = bytes
        self.paragraphs = paragraphs
        self.durationMs = durationMs
        self.errorCode = errorCode
        self.status = status
        self.reasons = reasons
    }

    /// The event for a finished read.
    public static func completed(_ document: DocumentText, bytes: Int, durationMs: Int) -> DocumentToolOpsEvent {
        DocumentToolOpsEvent(kind: .readCompleted, format: document.format.rawValue, bytes: bytes,
                             paragraphs: document.paragraphs.count, durationMs: durationMs)
    }

    /// The event for a failed read. A missing PDF engine and a timeout get their own kind, so the admin view can count them.
    public static func failed(code: String, bytes: Int, durationMs: Int) -> DocumentToolOpsEvent {
        let kind: Kind
        switch code {
        case "pdf-engine-missing": kind = .pdfEngineMissing
        case "pdf-timeout": kind = .timeout
        default: kind = .readFailed
        }
        return DocumentToolOpsEvent(kind: kind, bytes: bytes, durationMs: durationMs, errorCode: code)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
