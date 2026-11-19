// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import Foundation

/// Lets AdminScaffold read the operational flow (purpose F2).
///
/// An identity that is not the owner may read `feed` and the `documenttools.*` get keys (`r---`, never a write) only when
/// it carries an `admin.observer` role credential that AdminScaffold's `AdminRoleEnrollment` cell verifies. The check
/// asks AdminScaffold every time, so a revoked credential stops working at once. Without an AdminScaffold endpoint, or
/// when the check fails in any way, access is refused.
public struct DocumentToolAdminObserver: Sendable {
    public static let role = "admin.observer"
    public static let proofKeypath = "identity.proofs.scaffold.roles.admin.observer"
    public static let verifyKeypath = "verifyRoleCredential"
    public static let roleEndpointEnvironmentKey = "DOCUMENTTOOLS_ADMIN_ROLE_ENDPOINT"
    /// Key paths an observer may read. Writes are never granted this way.
    public static let readableKeypaths: Set<String> = ["feed", DocumentToolsCell.keyPrefix]

    public var verify: @Sendable (Identity) async -> Bool

    public init(verify: @escaping @Sendable (Identity) async -> Bool) {
        self.verify = verify
    }

    /// Refuses everyone. Used when no AdminScaffold is configured.
    public static let none = DocumentToolAdminObserver { _ in false }

    /// Checks the credential at AdminScaffold, resolved from the environment.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DocumentToolAdminObserver {
        guard let endpoint = roleEndpoint(environment: environment) else { return .none }
        return DocumentToolAdminObserver { identity in
            await verifyAtAdminScaffold(identity, endpoint: endpoint)
        }
    }

    /// `DOCUMENTTOOLS_ADMIN_ROLE_ENDPOINT`, or the AdminScaffold endpoint with its last path part replaced by
    /// `AdminRoleEnrollment` (cell://admin.example/AdminScaffoldServices → cell://admin.example/AdminRoleEnrollment).
    public static func roleEndpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = environment[roleEndpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        guard let admin = DocumentToolAdminEntry.endpoint(environment: environment),
              let slash = admin.lastIndex(of: "/"), admin.index(after: slash) < admin.endIndex,
              admin.hasPrefix("cell://") else { return nil }
        return String(admin[...slash]) + "AdminRoleEnrollment"
    }

    static func verifyAtAdminScaffold(_ identity: Identity, endpoint: String,
                                      resolver: CellResolverProtocol? = CellBase.defaultCellResolver) async -> Bool {
        guard let resolver,
              let enrollment = try? await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity) as? Meddle,
              let credential = try? await identity.get(keypath: proofKeypath, requester: identity) else {
            return false
        }
        let response = try? await enrollment.set(keypath: verifyKeypath,
                                                 value: .object(["role": .string(role), "credential": credential]),
                                                 requester: identity)
        return granted(response)
    }

    /// Only an explicit `{ "granted": true }` counts.
    static func granted(_ response: ValueType?) -> Bool {
        guard case .object(let object)? = response, case .bool(true)? = object["granted"] else { return false }
        return true
    }
}
