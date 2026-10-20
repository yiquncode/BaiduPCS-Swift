import Foundation

/// 百度的 JSON 字段类型不稳定：同一字段有时是数字，有时是字符串。
/// 这个包装按需宽松地读取，不用 Codable。
struct JSON {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw BaiduError.invalidResponse
        }
        raw = object
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }

    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }

    var string: String? {
        switch raw {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    var int64: Int64? {
        switch raw {
        case let value as NSNumber: value.int64Value
        case let value as String: Int64(value)
        default: nil
        }
    }

    var uint64: UInt64? {
        switch raw {
        case let value as NSNumber: value.uint64Value
        case let value as String: UInt64(value)
        default: nil
        }
    }

    var int: Int? { int64.map { Int(truncatingIfNeeded: $0) } }

    var bool: Bool? {
        switch raw {
        case let value as NSNumber: value.boolValue
        case let value as String: value == "1" || value.lowercased() == "true"
        default: nil
        }
    }
}

enum URLEncoding {
    /// 只保留 RFC 3986 的非保留字符。URLComponents 不编码 `+`，服务端会把它读成空格，所以不用它。
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func url(_ base: String, _ items: [(String, String)]) -> URL {
        url(base, rawQuery: query(items))
    }

    static func url(_ base: String, rawQuery: String) -> URL {
        let string = rawQuery.isEmpty ? base : "\(base)?\(rawQuery)"
        // 宽松模式遇到非法字符时会把整个 query 重新编码，已有的 `%2F` 变成 `%252F`。
        guard let url = URL(string: string, encodingInvalidCharacters: false) else {
            preconditionFailure("Invalid URL: \(string)")
        }
        return url
    }

    static func form(_ items: [(String, String)]) -> Data {
        Data(query(items).utf8)
    }
}

/// PCS 的 meta、delete 接口只接受 multipart 表单中的 `param` 字段。
struct MultipartForm {
    let boundary = "FerryBoundary\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(name: String, value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    func finalized() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

enum Path {
    static func join(_ base: String, _ component: String) -> String {
        guard !component.isEmpty else { return base }
        return base.hasSuffix("/") ? base + component : base + "/" + component
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
