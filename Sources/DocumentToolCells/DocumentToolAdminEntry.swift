// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import Foundation

/// AdminScaffold as the way into the rest of HAVEN (purpose D5).
///
/// The scaffold that hosts `cell:///DocumentTools` is configured with the AdminScaffold endpoint in
/// `DOCUMENTTOOLS_ADMIN_ENDPOINT`. At start it sends its signed service description there (key path
/// `scaffoldServices.register`); AdminScaffold verifies it and subscribes to the operational flow. Without an
/// endpoint the scaffold still runs, but its health says `admin-endpoint-missing`, so it is never silent.
public enum DocumentToolAdminEntry {
    public static let environmentKey = "DOCUMENTTOOLS_ADMIN_ENDPOINT"
    public static let registerKeypath = "scaffoldServices.register"

    public enum Outcome: Equatable {
        case notConfigured
        case registered
        case unreachable(String)
        case rejected(String)
    }

    public static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Resolves the endpoint and registers there.
    public static func register(_ description: DocumentToolServiceDescription, endpoint: String?, requester: Identity,
                                resolver: CellResolverProtocol? = CellBase.defaultCellResolver) async -> Outcome {
        guard let endpoint else { return .notConfigured }
        guard let resolver else { return .unreachable("no-resolver") }
        do {
            let emit = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: requester)
            guard let target = emit as? Meddle else { return .unreachable("not-meddle") }
            return await register(description, at: target, requester: requester)
        } catch {
            return .unreachable("resolve-failed")
        }
    }

    /// Registers at an already resolved AdminScaffold cell.
    public static func register(_ description: DocumentToolServiceDescription, at target: Meddle, requester: Identity) async -> Outcome {
        do {
            let response = try await target.set(keypath: registerKeypath, value: try JSONValueBridge.valueType(description), requester: requester)
            switch response {
            case .string("denied")?: return .rejected("denied")
            case .object(let object)?:
                if case .object(let error)? = object["error"], case .string(let code)? = error["code"] { return .rejected(code) }
                return .registered
            case .bool(true)?: return .registered
            case nil, .null?: return .rejected("no-answer")
            default: return .rejected("unexpected-answer")
            }
        } catch {
            return .unreachable("set-failed")
        }
    }
}
