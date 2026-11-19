// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase
@testable import DocumentToolCells
import DocumentTools

/// Tests for `cell:///DocumentTools`: test.cell.contract-fixtures, test.cell.auth-negative, test.cell.explore-purposes (D3)
/// and test.dv.ops-no-content / test.dv.ops-event-kinds (F1).
final class DocumentToolsCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    private func makeCell() async throws -> (DocumentToolsCell, owner: Identity, outsider: Identity) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerIdentity = await vault.identity(for: "documenttools-owner", makeNewIfNotFound: true)
        let outsiderIdentity = await vault.identity(for: "documenttools-outsider", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerIdentity)
        let outsider = try XCTUnwrap(outsiderIdentity)
        return (await DocumentToolsCell(owner: owner), owner, outsider)
    }

    private static let markdown = """
    # Tittel

    Første avsnitt med en fotnote.[^1]

    Andre avsnitt.

    [^1]: Fotnoten.
    """

    private func readMarkdown(_ cell: DocumentToolsCell, _ requester: Identity) async throws -> ValueType? {
        try await cell.set(keypath: "documenttools.read",
                           value: .object(["name": .string("notat.md"), "dataBase64": .string(Data(Self.markdown.utf8).base64EncodedString())]),
                           requester: requester)
    }

    /// `ValueType` never compares lists or objects as equal, so tests compare them as JSON.
    private func json(_ value: ValueType?) throws -> JSONValueBridge.JSON? {
        try value.map { try JSONValueBridge.json($0) }
    }

    /// A refused request either throws from GeneralCell's own access check or comes back as "denied" from the cell.
    private func assertDenied(_ operation: () async throws -> ValueType?, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let value = try await operation()
            XCTAssertEqual(value, .string("denied"), message, file: file, line: line)
        } catch {}
    }

    private func object(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: ValueType] {
        guard case let .object(object)? = value else {
            XCTFail("forventet objekt, fikk \(String(describing: value))", file: file, line: line)
            throw XCTSkip("ikke objekt")
        }
        return object
    }

    // MARK: - test.cell.contract-fixtures

    func testReadNumberPrepareAndVerifyThroughTheCell() async throws {
        let (cell, owner, _) = try await makeCell()

        let read = try object(try await readMarkdown(cell, owner))
        XCTAssertEqual(read["format"], .string("markdown"))
        let document = try JSONValueBridge.decode(DocumentText.self, from: .object(read))
        XCTAssertEqual(document.paragraphs.map(\.style), ["Heading 1", "Normal", "Normal"])
        XCTAssertEqual(document.paragraphs[1].footnotes, ["Fotnoten."])

        let numberedValue = try await cell.set(keypath: "documenttools.number",
                                               value: .object(["paragraphs": try JSONValueBridge.valueType(document.paragraphs)]),
                                               requester: owner)
        let outcome = try JSONValueBridge.decode(ParagraphNumbering.Outcome.self, from: try XCTUnwrap(numberedValue))
        XCTAssertEqual(outcome.paragraphs.map(\.ref), ["A1", "A2", "A3"])
        XCTAssertEqual(outcome, ParagraphNumbering.number(document.paragraphs, previous: nil), "cellen gir det samme som biblioteket")

        let preparedValue = try await cell.set(keypath: "documenttools.prepare",
                                               value: .object(["numbered": try JSONValueBridge.valueType(outcome.paragraphs)]), requester: owner)
        let prepared = try JSONValueBridge.decode(ModelReadyText.Prepared.self, from: try XCTUnwrap(preparedValue))
        XCTAssertEqual(prepared, ModelReadyText.prepare(outcome.paragraphs))
        XCTAssertTrue(prepared.text.contains("[A2 fotnote 1] Fotnoten."))

        let diff = try object(try await cell.set(keypath: "documenttools.diff",
                                                 value: .object(["numbered": try JSONValueBridge.valueType(outcome)]), requester: owner))
        XCTAssertEqual(try json(diff["removed"]), .list([]))

        let check = try object(try await cell.set(keypath: "documenttools.verifyRefs",
                                                  value: .object(["refs": .list([.string("A1"), .string("A9")]),
                                                                  "knownRefs": .list([.string("A1"), .string("A2")])]),
                                                  requester: owner))
        XCTAssertEqual(check["ok"], .bool(false))
        XCTAssertEqual(try json(check["unknown"]), .list([.string("A9")]))
    }

    func testErrorsComeBackWithCode() async throws {
        let (cell, owner, _) = try await makeCell()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let unknown = try object(try await cell.set(keypath: "documenttools.read",
                                                    value: .object(["name": .string("a.docx"), "dataBase64": .string(png.base64EncodedString())]),
                                                    requester: owner))
        XCTAssertEqual(try object(unknown["error"])["code"], .string("unknown-format"))
        let invalid = try object(try await cell.set(keypath: "documenttools.number", value: .object(["feil": .bool(true)]), requester: owner))
        XCTAssertEqual(try object(invalid["error"])["code"], .string("invalid-payload"), "\(invalid)")
    }

    // MARK: - test.cell.auth-negative

    func testOutsiderWithoutAgreementIsDenied() async throws {
        let (cell, _, outsider) = try await makeCell()
        await assertDenied({ try await self.readMarkdown(cell, outsider) }, "en fremmed skal ikke få lese dokumenter")
        await assertDenied({ try await cell.get(keypath: "documenttools.purposes", requester: outsider) }, "en fremmed skal ikke få formålene uten avtale")
        do {
            _ = try await cell.flow(requester: outsider)
            XCTFail("en fremmed skal ikke få lese driftshendelsene")
        } catch {}
    }

    // MARK: - test.cell.explore-purposes (D3)

    func testPurposesAreQueryableOverCellProtocol() async throws {
        let (cell, owner, _) = try await makeCell()
        let manifest = try await ExploreManifestBuilder.build(for: cell, requester: owner)
        XCTAssertEqual(Set(manifest.intent.purposeRefs), Set(DocumentToolPurposes.refs))
        XCTAssertTrue(Set(manifest.operations.map(\.key)).isSuperset(of: ["documenttools.read", "documenttools.purposes"]))

        let listed = try JSONValueBridge.decode([DocumentToolPurposes.Purpose].self,
                                                from: try await cell.get(keypath: "documenttools.purposes", requester: owner))
        XCTAssertEqual(listed, DocumentToolPurposes.all)

        let ownership = try object(try await cell.get(keypath: "documenttools.ownership", requester: owner))
        XCTAssertEqual(ownership["ownerGroup"], .string("Digipomps"))
        XCTAssertEqual(try json(ownership["groupOwnerMembers"]), .list([.string("Kjetil"), .string("Vegar")]))
        XCTAssertEqual(ownership["enforced"], .bool(false))
    }

    // MARK: - test.dv.ops-no-content og test.dv.ops-event-kinds (F1)

    func testOpsEventsCarryNoDocumentContent() async throws {
        let (cell, owner, _) = try await makeCell()
        let collected = ElementBox()
        let subscription = try await cell.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { collected.append($0) })
        defer { subscription.cancel() }

        _ = try await readMarkdown(cell, owner)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        _ = try await cell.set(keypath: "documenttools.read",
                               value: .object(["name": .string("hemmelig-navn.docx"), "dataBase64": .string(png.base64EncodedString())]),
                               requester: owner)

        let deadline = Date().addingTimeInterval(5)
        while collected.elements.filter({ $0.title.hasPrefix("read") }).count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reads = collected.elements.filter { $0.topic == DocumentToolOpsEvent.topic && $0.title.hasPrefix("read") }
        XCTAssertEqual(reads.map(\.title), ["read.completed", "read.failed"])

        let encoded = try String(decoding: JSONEncoder().encode(collected.elements), as: UTF8.self)
        for secret in ["Tittel", "Første avsnitt", "Fotnoten", "notat.md", "hemmelig-navn"] {
            XCTAssertFalse(encoded.contains(secret), "driftshendelsene skal ikke inneholde «\(secret)»")
        }
        let document = try DocumentIntake.read(data: Data(Self.markdown.utf8), name: "notat.md")
        XCTAssertFalse(encoded.contains(document.sourceSHA256), "driftshendelsene skal ikke inneholde kildehashen")
        XCTAssertTrue(encoded.contains("unknown-format"))
    }

    func testOpsEventKindsAreStable() {
        XCTAssertEqual(DocumentToolOpsEvent.Kind.allCases.map(\.rawValue),
                       ["started", "stopped", "read.completed", "read.failed", "pdf-engine-missing", "timeout", "health"])
        XCTAssertEqual(DocumentToolOpsEvent.failed(code: "pdf-engine-missing", bytes: 1, durationMs: 0).kind, .pdfEngineMissing)
        XCTAssertEqual(DocumentToolOpsEvent.failed(code: "pdf-timeout", bytes: 1, durationMs: 0).kind, .timeout)
        XCTAssertEqual(DocumentToolOpsEvent.failed(code: "too-large", bytes: 1, durationMs: 0).kind, .readFailed)
    }

    // MARK: - test.dv.owner-declared og test.dv.service-description-signed (G)

    func testServiceDescriptionIsSignedAndNamesDigipompsAsOwner() async throws {
        let (cell, owner, outsider) = try await makeCell()
        let value = try await cell.get(keypath: "documenttools.serviceDescription", requester: owner)
        let description = try JSONValueBridge.decode(DocumentToolServiceDescription.self, from: value)
        try await description.verify(expectedSigner: owner)
        XCTAssertEqual(description.payload.owner, .digipomps)
        XCTAssertEqual(description.payload.owner.organizationNumber, "922135134")
        XCTAssertEqual(description.payload.owner.groupOwnerMembers, ["Kjetil", "Vegar"])
        XCTAssertFalse(description.payload.owner.ownerEnforced)
        XCTAssertEqual(Set(description.payload.purposeRefs), Set(DocumentToolPurposes.refs))
        XCTAssertEqual(description.payload.opsTopic, "documenttools.ops.v1")

        var tampered = description
        tampered.payload.owner.groupOwnerMembers.append("Mallory")
        do { try await tampered.verify(expectedSigner: owner); XCTFail("endret eierliste skal avvises") }
        catch { XCTAssertEqual(error as? DocumentToolServiceDescription.DescriptionError, .invalidSignature) }

        do { try await description.verify(expectedSigner: outsider); XCTFail("feil signerer skal avvises") }
        catch { XCTAssertEqual(error as? DocumentToolServiceDescription.DescriptionError, .invalidSigner) }
    }

    // MARK: - test.dv.admin-entry-configured og test.dv.admin-registration (D5)

    func testAdminEntryIsExplicitWhenMissingAndRegistersWhenPresent() async throws {
        XCTAssertNil(DocumentToolAdminEntry.endpoint(environment: [:]))
        XCTAssertNil(DocumentToolAdminEntry.endpoint(environment: ["DOCUMENTTOOLS_ADMIN_ENDPOINT": "  "]))
        XCTAssertEqual(DocumentToolAdminEntry.endpoint(environment: ["DOCUMENTTOOLS_ADMIN_ENDPOINT": "cell://admin.example/AdminScaffoldServices"]),
                       "cell://admin.example/AdminScaffoldServices")

        let (cell, owner, _) = try await makeCell()
        let description = try JSONValueBridge.decode(DocumentToolServiceDescription.self,
                                                     from: try await cell.get(keypath: "documenttools.serviceDescription", requester: owner))
        let notConfigured = await DocumentToolAdminEntry.register(description, endpoint: nil, requester: owner)
        XCTAssertEqual(notConfigured, .notConfigured)
        if DocumentToolAdminEntry.endpoint() == nil {
            let health = try object(try await cell.get(keypath: "documenttools.state", requester: owner))
            XCTAssertEqual(health["status"], .string("degraded"))
            guard case .list(let reasons)? = health["reasons"] else { return XCTFail("reasons mangler") }
            XCTAssertTrue(reasons.contains(.string("admin-endpoint-missing")))
        }

        let admin = await FakeAdminServicesCell(owner: owner)
        let outcome = await DocumentToolAdminEntry.register(description, at: admin, requester: owner)
        XCTAssertEqual(outcome, .registered)
        let received = try XCTUnwrap(admin.received)
        try await received.verify(expectedSigner: owner)
        XCTAssertEqual(received.payload.owner.group, "Digipomps")
    }

    // MARK: - test.cell.ops-flow-admin og test.cell.ops-flow-auth-negative (F2)

    func testVerifiedAdminObserverReadsTheFlowButCannotWrite() async throws {
        let (cell, _, outsider) = try await makeCell()
        let observerIdentity = await CellBase.defaultIdentityVault?.identity(for: "documenttools-admin-observer", makeNewIfNotFound: true)
        let observer = try XCTUnwrap(observerIdentity)
        let observerUUID = observer.uuid
        cell.adminObserver = DocumentToolAdminObserver { $0.uuid == observerUUID }

        _ = try await cell.flow(requester: observer)
        let purposes = try JSONValueBridge.decode([DocumentToolPurposes.Purpose].self,
                                                  from: try await cell.get(keypath: "documenttools.purposes", requester: observer))
        XCTAssertEqual(purposes.count, DocumentToolPurposes.all.count)
        await assertDenied({ try await self.readMarkdown(cell, observer) }, "en observatør skal ikke få skrive")

        do {
            _ = try await cell.flow(requester: outsider)
            XCTFail("uten verifisert admin.observer-bevis skal abonnementet avvises")
        } catch {}
    }

    func testAdminObserverCheckIsStrict() {
        XCTAssertEqual(DocumentToolAdminObserver.roleEndpoint(environment: [:]), nil)
        XCTAssertEqual(DocumentToolAdminObserver.roleEndpoint(environment: [DocumentToolAdminEntry.environmentKey: "cell://admin.example/AdminScaffoldServices"]),
                       "cell://admin.example/AdminRoleEnrollment")
        XCTAssertEqual(DocumentToolAdminObserver.roleEndpoint(environment: [DocumentToolAdminEntry.environmentKey: "cell://admin.example/AdminScaffoldServices",
                                                                            DocumentToolAdminObserver.roleEndpointEnvironmentKey: "cell://roles.example/AdminRoleEnrollment"]),
                       "cell://roles.example/AdminRoleEnrollment")
        XCTAssertTrue(DocumentToolAdminObserver.granted(.object(["granted": .bool(true), "role": .string("admin.observer")])))
        for refused: ValueType? in [nil, .null, .string("denied"), .bool(true), .object(["granted": .bool(false)]), .object(["granted": .string("true")])] {
            XCTAssertFalse(DocumentToolAdminObserver.granted(refused), "\(String(describing: refused))")
        }
    }
}

/// Stands in for AdminScaffold's `scaffoldServices.register` until WP16 builds the real one in CellScaffold.
private final class FakeAdminServicesCell: GeneralCell {
    var received: DocumentToolServiceDescription?

    required init(owner: Identity) async {
        await super.init(owner: owner)
        await registerSet(key: DocumentToolAdminEntry.registerKeypath, owner: owner) { [weak self] _, value in
            self?.received = try? JSONValueBridge.decode(DocumentToolServiceDescription.self, from: value)
            return .object(["registered": .bool(self?.received != nil)])
        }
    }

    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

private final class ElementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FlowElement] = []
    func append(_ element: FlowElement) { lock.lock(); stored.append(element); lock.unlock() }
    var elements: [FlowElement] { lock.lock(); defer { lock.unlock() }; return stored }
}
