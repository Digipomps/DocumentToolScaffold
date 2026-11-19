// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import DocumentTools
import Foundation

/// The signed service description DocumentToolScaffold gives AdminScaffold (purposes G and D5).
///
/// It says which service this is, which instance, what it is for, where its cell and operational flow are, and who
/// owns it. The scaffold identity signs it, the same pattern as `CellScaffoldServiceIdentityManifest` in CellScaffold.
///
/// Ownership is a declaration: the owner is the Digipomps group identity, with its group owner members listed. HAVEN
/// group identities (`GovernancePolicy`) are not on CellProtocol main yet, so `ownerEnforced` is `false` and the group
/// does not sign. When group identities land, the group (by its policy) signs instead and `ownerEnforced` becomes `true`.
public struct DocumentToolServiceDescription: Codable, Equatable, Sendable {
    public static let schemaVersion = "haven.documenttools.service.v1"
    public static let canonicalization = "json_sorted_keys_v1"
    public static let signatureAlgorithm = "Ed25519"
    public static let serviceID = "documenttools"

    public struct Owner: Codable, Equatable, Sendable {
        public var group: String
        public var legalEntity: String
        public var organizationNumber: String
        public var groupOwnerMembers: [String]
        public var ownerEnforced: Bool

        public static let digipomps = Owner(
            group: DocumentToolOwnership.ownerGroup,
            legalEntity: "Stiftelsen Digipomps",
            organizationNumber: "922135134",
            groupOwnerMembers: DocumentToolOwnership.groupOwnerMembers,
            ownerEnforced: false
        )
    }

    public struct Payload: Codable, Equatable, Sendable {
        public var schemaVersion: String
        public var canonicalization: String
        public var serviceID: String
        public var instanceID: String
        public var environment: String?
        public var cellEndpoint: String
        public var opsTopic: String
        public var purposeRefs: [String]
        public var owner: Owner
        public var signerIdentityID: String
        public var signerSigningPublicKeyFingerprint: String
        public var issuedAt: String
    }

    public struct Signature: Codable, Equatable, Sendable {
        public var algorithm: String
        public var signatureBase64URL: String
    }

    public enum DescriptionError: Error, Equatable {
        case invalidSigner
        case invalidPayload
        case invalidSignature
    }

    public var payload: Payload
    public var signature: Signature

    /// Builds and signs a description with the scaffold's own identity.
    public static func signed(instanceID: String, environment: String? = nil, signer: Identity,
                              cellEndpoint: String = "cell:///DocumentTools", issuedAt: Date = Date()) async throws -> DocumentToolServiceDescription {
        guard let fingerprint = signer.signingPublicKeyFingerprint, !fingerprint.isEmpty else { throw DescriptionError.invalidSigner }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let payload = Payload(
            schemaVersion: schemaVersion, canonicalization: canonicalization, serviceID: serviceID,
            instanceID: instanceID, environment: environment, cellEndpoint: cellEndpoint,
            opsTopic: DocumentToolOpsEvent.topic, purposeRefs: DocumentToolPurposes.refs.sorted(), owner: .digipomps,
            signerIdentityID: signer.uuid, signerSigningPublicKeyFingerprint: fingerprint,
            issuedAt: formatter.string(from: issuedAt)
        )
        try validate(payload)
        guard let signature = try await signer.sign(data: canonicalData(payload)) else { throw DescriptionError.invalidSignature }
        return DocumentToolServiceDescription(payload: payload,
                                              signature: Signature(algorithm: signatureAlgorithm, signatureBase64URL: base64URL(signature)))
    }

    /// Verifies the signature against the identity that is expected to have signed it, and that the payload is well formed.
    public func verify(expectedSigner: Identity) async throws {
        try Self.validate(payload)
        guard payload.signerIdentityID == expectedSigner.uuid,
              payload.signerSigningPublicKeyFingerprint == expectedSigner.signingPublicKeyFingerprint else {
            throw DescriptionError.invalidSigner
        }
        guard signature.algorithm == Self.signatureAlgorithm,
              let data = Self.decodeBase64URL(signature.signatureBase64URL), data.count == 64,
              await expectedSigner.verify(signature: data, for: try Self.canonicalData(payload)) else {
            throw DescriptionError.invalidSignature
        }
    }

    static func validate(_ payload: Payload) throws {
        guard payload.schemaVersion == schemaVersion, payload.canonicalization == canonicalization,
              payload.serviceID == serviceID, !payload.instanceID.isEmpty, payload.instanceID.count <= 128,
              payload.cellEndpoint.hasPrefix("cell://"), payload.opsTopic == DocumentToolOpsEvent.topic,
              !payload.purposeRefs.isEmpty, payload.purposeRefs.allSatisfy({ $0.hasPrefix("purpose://") }),
              !payload.owner.group.isEmpty, !payload.owner.groupOwnerMembers.isEmpty else {
            throw DescriptionError.invalidPayload
        }
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
