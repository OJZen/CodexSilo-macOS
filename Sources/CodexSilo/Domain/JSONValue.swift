import Foundation

/// Type-safe dynamic JSON value used for auth payload and flexible store fields.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: L10n.tr("error.json.unsupported_value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var int64Value: Int64? {
        if let asDouble = doubleValue {
            return Int64(asDouble)
        }
        return nil
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    static func from(any: Any) throws -> JSONValue {
        switch any {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [String: Any]:
            let converted = try value.mapValues { try JSONValue.from(any: $0) }
            return .object(converted)
        case let value as [Any]:
            return .array(try value.map { try JSONValue.from(any: $0) })
        case _ as NSNull:
            return .null
        default:
            throw AppError.invalidData(L10n.tr("error.json.unsupported_payload_type"))
        }
    }

    func toAny() -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.toAny() }
        case .array(let value):
            return value.map { $0.toAny() }
        case .null:
            return NSNull()
        }
    }

    func prettyPrintedJSONString() throws -> String {
        let object = toAny()
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AppError.invalidData("auth.json 内容不是有效的 JSON 对象。")
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw AppError.invalidData("无法将 auth.json 转换为文本。")
        }
        return string
    }

    static func authJSONObject(from string: String) throws -> JSONValue {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidData("auth.json 不能为空。")
        }

        let data = Data(trimmed.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let value = try JSONValue.from(any: object)
        guard case .object = value else {
            throw AppError.invalidData("auth.json 顶层必须是 JSON 对象。")
        }
        return value
    }
}
