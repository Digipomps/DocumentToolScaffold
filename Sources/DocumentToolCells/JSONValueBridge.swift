// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import Foundation

/// Moves Codable values in and out of `ValueType` through plain JSON, so the cell uses the library's own
/// Codable types as its wire format and does not keep a second, hand-written copy of them.
enum JSONValueBridge {
    enum BridgeError: Error { case unsupported(String) }

    /// A JSON tree. Booleans are tried before numbers, so `true` never turns into `1`.
    indirect enum JSON: Codable, Equatable {
        case null, bool(Bool), integer(Int), float(Double), string(String), list([JSON]), object([String: JSON])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .float(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSON].self) { self = .list(value) }
            else { self = .object(try container.decode([String: JSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .float(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .list(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    static func valueType<T: Encodable>(_ value: T) throws -> ValueType {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONDecoder().decode(JSON.self, from: encoder.encode(value))
        return valueType(json)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(try json(value)))
    }

    static func valueType(_ json: JSON) -> ValueType {
        switch json {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        case .float(let value): return .float(value)
        case .string(let value): return .string(value)
        case .list(let value): return .list(value.map(valueType))
        case .object(let value): return .object(value.mapValues(valueType))
        }
    }

    static func json(_ value: ValueType) throws -> JSON {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value), .number(let value): return .integer(value)
        case .float(let value): return .float(value)
        case .string(let value): return .string(value)
        case .list(let value): return .list(try value.map(json))
        case .object(let value): return .object(try value.mapValues(json))
        case .data(let value): return .string(value.base64EncodedString())
        default: throw BridgeError.unsupported("\(value)")
        }
    }
}
