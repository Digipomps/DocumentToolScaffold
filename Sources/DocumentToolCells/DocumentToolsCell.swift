// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

@_spi(HAVENRuntime) import CellBase
import DocumentTools
import Foundation

/// `cell:///DocumentTools` (purposes D2, D3 and F1).
///
/// The cell reads, numbers and prepares documents with the `DocumentTools` library. It stores nothing: whoever calls
/// keeps the previous version and sends it back in for numbering. Data travels in the payload, never as a file path.
///
/// Key paths (all under `documenttools.`): `read`, `number`, `diff`, `prepare` and `verifyRefs` are set operations;
/// `purposes`, `ownership` and `state` are get operations. Errors come back as `{ "error": { "code", "message" } }`.
///
/// Operational events (`DocumentToolOpsEvent`) go out on the cell's flow with the topic `documenttools.ops.v1`.
/// They never carry document text, file names or hashes. Reading the flow needs `r---` on `feed`.
public final class DocumentToolsCell: GeneralCell, EntityAtlasDescribing {
    public static let keyPrefix = "documenttools"
    public static let publicOperationKeys = [
        "documenttools.read", "documenttools.number", "documenttools.diff", "documenttools.prepare",
        "documenttools.verifyRefs", "documenttools.purposes", "documenttools.ownership", "documenttools.state", "documenttools.serviceDescription",
    ]
    /// Base64 makes the payload about 4/3 of the file; this keeps the decoded file within `DocumentIntake.maxBytes`.
    static let maxBase64Characters = (DocumentIntake.maxBytes / 3 + 1) * 4

    private var emitOpsElement: ((FlowElement) -> Void)?
    /// The scaffold identity that owns the cell and signs the service description. Not persisted; the cell is ephemeral.
    private var signer: Identity?
    private var startedAt = Date()

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await installBindings(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    // MARK: - EntityAtlasDescribing (D3)

    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Document Tools",
            summary: "Reads docx, pdf, md, rtf and txt into numbered paragraphs and model-ready text, natively and without a model.",
            purposeRefs: DocumentToolPurposes.refs,
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: Self.publicOperationKeys,
            knowledgeRoles: []
        )
    }

    // MARK: - Bindings

    private func installBindings(owner: Identity) async {
        agreementTemplate.ensureGrant("rw--", for: Self.keyPrefix)
        agreementTemplate.ensureGrant("r---", for: "feed")
        emitOpsElement = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        signer = owner

        await registerGet(key: "documenttools.purposes", owner: owner,
                          returns: .list([.object(["code": .string("A1"), "ref": .string("purpose://…"), "title": .string(""),
                                                    "goal": .string(""), "availability": .string("available|planned|parked")])]),
                          permissions: ["r---"],
                          description: .string("The purposes DocumentToolScaffold fulfils or plans, the same list as in its README.")) { [weak self] requester in
            await self?.guarded("r---", requester) { try JSONValueBridge.valueType(DocumentToolPurposes.all) } ?? .null
        }
        await registerGet(key: "documenttools.ownership", owner: owner,
                          returns: .object(["ownerGroup": .string("Digipomps"), "ownerLegalEntity": .string(""), "groupOwnerMembers": .list([])]),
                          permissions: ["r---"],
                          description: .string("Who owns the scaffold (a declaration; not enforced until HAVEN group identities are on main).")) { [weak self] requester in
            await self?.guarded("r---", requester) {
                .object([
                    "ownerGroup": .string(DocumentToolOwnership.ownerGroup),
                    "ownerLegalEntity": .string(DocumentToolOwnership.ownerLegalEntity),
                    "groupOwnerMembers": .list(DocumentToolOwnership.groupOwnerMembers.map { .string($0) }),
                    "enforced": .bool(false),
                ])
            } ?? .null
        }
        await registerGet(key: "documenttools.state", owner: owner,
                          returns: .object(["status": .string("ok|degraded"), "reasons": .list([]), "pdfEngine": .bool(true)]),
                          permissions: ["r---"],
                          description: .string("Health of the tool: whether the PDF engine is present.")) { [weak self] requester in
            await self?.guarded("r---", requester) { [weak self] in
                guard let self else { return .null }
                return try JSONValueBridge.valueType(self.healthEvent())
            } ?? .null
        }

        await registerGet(key: "documenttools.serviceDescription", owner: owner,
                          returns: .object(["payload": .object([:]), "signature": .object([:])]),
                          permissions: ["r---"],
                          description: .string("The service description (owner, purposes, cell and flow), signed by the scaffold identity.")) { [weak self] requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: Self.keyPrefix, for: requester) else { return .string("denied") }
            guard let signer = self.signer else { return Self.errorValue("no-signer", "Cellen har ingen eier som kan signere.") }
            let instanceID = ProcessInfo.processInfo.environment["DOCUMENTTOOLS_INSTANCE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? self.uuid
            do {
                let description = try await DocumentToolServiceDescription.signed(
                    instanceID: instanceID, environment: ProcessInfo.processInfo.environment["CELL_SCAFFOLD_ENVIRONMENT"], signer: signer)
                return try JSONValueBridge.valueType(description)
            } catch {
                return Self.errorValue("signing-failed", "Tjenestebeskrivelsen kunne ikke signeres.")
            }
        }

        await registerSet(key: "documenttools.read", owner: owner,
                          input: .object(["name": .string("file name, only a hint"), "dataBase64": .string("the file")]),
                          returns: .object(["format": .string(""), "sourceSHA256": .string(""), "paragraphs": .list([]), "warnings": .list([])]),
                          permissions: ["-w--"],
                          flowEffects: [.string(DocumentToolOpsEvent.topic)],
                          description: .string("Reads a document. The format is decided by the content, not the name.")) { [weak self] requester, value in
            await self?.guarded("-w--", requester) { [weak self] in try self?.read(value) ?? .null } ?? .null
        }
        await registerSet(key: "documenttools.number", owner: owner,
                          input: .object(["paragraphs": .list([]), "previous": .list([]), "prefix": .string("A")]),
                          returns: .object(["paragraphs": .list([]), "removed": .list([]), "merged": .object([:])]),
                          permissions: ["-w--"],
                          description: .string("Numbers paragraphs, stably against the previous version when it is given.")) { [weak self] requester, value in
            await self?.guarded("-w--", requester) {
                let input = try JSONValueBridge.decode(NumberInput.self, from: value)
                return try JSONValueBridge.valueType(ParagraphNumbering.number(input.paragraphs, previous: input.previous, prefix: input.prefix ?? "A"))
            } ?? .null
        }
        await registerSet(key: "documenttools.diff", owner: owner,
                          input: .object(["numbered": .object([:])]),
                          returns: .object(["changed": .list([]), "moved": .list([]), "added": .list([]), "removed": .list([]), "merged": .object([:])]),
                          permissions: ["-w--"],
                          description: .string("Version diff from a numbering outcome.")) { [weak self] requester, value in
            await self?.guarded("-w--", requester) {
                let input = try JSONValueBridge.decode(DiffInput.self, from: value)
                return try JSONValueBridge.valueType(VersionDiff(input.numbered))
            } ?? .null
        }
        await registerSet(key: "documenttools.prepare", owner: owner,
                          input: .object(["numbered": .list([]), "maxTokensPerChunk": .integer(8000)]),
                          returns: .object(["text": .string(""), "sha256": .string(""), "tokenEstimate": .object([:]), "chunks": .list([])]),
                          permissions: ["-w--"],
                          description: .string("Deterministic model-ready text with hash, chunks and a labelled token estimate.")) { [weak self] requester, value in
            await self?.guarded("-w--", requester) {
                let input = try JSONValueBridge.decode(PrepareInput.self, from: value)
                return try JSONValueBridge.valueType(ModelReadyText.prepare(input.numbered, maxTokensPerChunk: input.maxTokensPerChunk))
            } ?? .null
        }
        await registerSet(key: "documenttools.verifyRefs", owner: owner,
                          input: .object(["refs": .list([]), "knownRefs": .list([])]),
                          returns: .object(["ok": .bool(true), "unknown": .list([])]),
                          permissions: ["-w--"],
                          description: .string("Checks that every A-number a model mentions exists in the text it was given.")) { [weak self] requester, value in
            await self?.guarded("-w--", requester) {
                let input = try JSONValueBridge.decode(VerifyInput.self, from: value)
                return try JSONValueBridge.valueType(ModelReadyText.verifyRefs(input.refs, knownRefs: input.knownRefs))
            } ?? .null
        }

        emit(DocumentToolOpsEvent(kind: .started))
        emit(healthEvent())
    }

    // MARK: - Operations

    private struct ReadInput: Decodable { var name: String?; var dataBase64: String }
    private struct NumberInput: Decodable { var paragraphs: [Paragraph]; var previous: [ParagraphNumbering.Numbered]?; var prefix: String? }
    private struct DiffInput: Decodable { var numbered: ParagraphNumbering.Outcome }
    private struct PrepareInput: Decodable { var numbered: [ParagraphNumbering.Numbered]; var maxTokensPerChunk: Int? }
    private struct VerifyInput: Decodable { var refs: [String]; var knownRefs: [String] }

    private func read(_ value: ValueType) throws -> ValueType {
        let input = try JSONValueBridge.decode(ReadInput.self, from: value)
        guard input.dataBase64.count <= Self.maxBase64Characters else {
            emit(.failed(code: "too-large", bytes: input.dataBase64.count / 4 * 3, durationMs: 0))
            throw DocumentToolsError("too-large", "Filen er større enn grensen på \(DocumentIntake.maxBytes / 1_048_576) MB.")
        }
        guard let data = Data(base64Encoded: input.dataBase64) else {
            throw DocumentToolsError("invalid-payload", "dataBase64 er ikke gyldig base64.")
        }
        let started = Date()
        do {
            let document = try DocumentIntake.read(data: data, name: input.name ?? "")
            emit(.completed(document, bytes: data.count, durationMs: Self.milliseconds(since: started)))
            return try JSONValueBridge.valueType(document)
        } catch let error as DocumentToolsError {
            emit(.failed(code: error.code, bytes: data.count, durationMs: Self.milliseconds(since: started)))
            throw error
        }
    }

    /// Checks access, runs the operation and turns every error into `{ "error": { "code", "message" } }`.
    private func guarded(_ access: String, _ requester: Identity, _ operation: () throws -> ValueType) async -> ValueType {
        guard await validateAccess(access, at: Self.keyPrefix, for: requester) else { return .string("denied") }
        do {
            return try operation()
        } catch let error as DocumentToolsError {
            return Self.errorValue(error.code, error.message)
        } catch is Swift.DecodingError { // CellBase has its own DecodingError, so the module name is needed
            return Self.errorValue("invalid-payload", "Payloaden har ikke feltene nøkkelstien krever.")
        } catch is JSONValueBridge.BridgeError {
            return Self.errorValue("invalid-payload", "Payloaden har en verditype nøkkelstien ikke tar imot.")
        } catch {
            // The error type only, never its description: a description can carry document content.
            return Self.errorValue("internal", "Uventet feil (\(String(describing: type(of: error)))).")
        }
    }

    static func errorValue(_ code: String, _ message: String) -> ValueType {
        .object(["error": .object(["code": .string(code), "message": .string(message)])])
    }

    func healthEvent() -> DocumentToolOpsEvent {
        var reasons: [String] = []
        if !PDFReader.engineAvailable { reasons.append("pdf-engine-missing") }
        if DocumentToolAdminEntry.endpoint() == nil { reasons.append("admin-endpoint-missing") }
        return DocumentToolOpsEvent(kind: .health, status: reasons.isEmpty ? "ok" : "degraded", reasons: reasons)
    }

    func emit(_ event: DocumentToolOpsEvent) {
        guard let emitOpsElement, case let .object(object)? = try? JSONValueBridge.valueType(event) else { return }
        var element = FlowElement(title: event.kind.rawValue, content: .object(object),
                                  properties: FlowElement.Properties(type: .event, contentType: .object))
        element.topic = DocumentToolOpsEvent.topic
        emitOpsElement(element)
    }

    private static func milliseconds(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }
}
