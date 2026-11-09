import Foundation

public enum SendFormat: String, Codable, CaseIterable { case text = "UTF-8", hex = "HEX" }

public enum LineEnding: String, Codable, CaseIterable {
    case none = "无", cr = "CR", lf = "LF", crlf = "CRLF"

    var bytes: [UInt8] {
        switch self {
        case .none: []
        case .cr: [13]
        case .lf: [10]
        case .crlf: [13, 10]
        }
    }
}

public enum ByteCodec {
    public enum InputError: LocalizedError {
        case invalidHex, empty, tooLong
        public var errorDescription: String? {
            switch self {
            case .invalidHex: "HEX 必须由完整的两位字节组成，例如 AA 55 01。"
            case .empty: "请输入要发送的数据。"
            case .tooLong: "单次发送最多 64 KiB。"
            }
        }
    }

    private static let digits = Array("0123456789ABCDEF".utf8)

    public static func hex(_ bytes: Data) -> String {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            if !output.isEmpty { output.append(32) }
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 15)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    public static func parseHex(_ text: String) throws -> Data {
        var result = Data()
        for token in text.split(whereSeparator: \.isWhitespace) {
            let bytes = Array(token.utf8)
            guard bytes.count.isMultiple(of: 2) else { throw InputError.invalidHex }
            for index in stride(from: 0, to: bytes.count, by: 2) {
                guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                    throw InputError.invalidHex
                }
                result.append(high << 4 | low)
            }
        }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    public static func payload(_ text: String, format: SendFormat, ending: LineEnding) throws -> Data {
        var data = try format == .hex ? parseHex(text) : Data(text.utf8)
        data.append(contentsOf: ending.bytes)
        guard !data.isEmpty else { throw InputError.empty }
        guard data.count <= 65_536 else { throw InputError.tooLong }
        return data
    }

    public static func xor(_ data: Data) -> UInt8 { data.reduce(0, ^) }
    public static func sum8(_ data: Data) -> UInt8 { data.reduce(0, &+) }

    public static func crc16Modbus(_ data: Data) -> UInt16 {
        data.reduce(UInt16(0xffff)) { crc, byte in
            var value = crc ^ UInt16(byte)
            for _ in 0..<8 {
                value = (value >> 1) ^ (value & 1 == 1 ? 0xa001 : 0)
            }
            return value
        }
    }
}

public struct StreamingUTF8 {
    private var pending = Data()

    public init() {}

    public mutating func append(_ bytes: Data) -> String {
        pending.append(bytes)
        let values = Array(pending)
        var split = values.count
        if !values.isEmpty {
            for start in stride(from: values.count - 1, through: max(0, values.count - 3), by: -1) {
                let lead = values[start]
                if (0x80...0xbf).contains(lead) { continue }
                let width: Int
                switch lead {
                case 0xc2...0xdf: width = 2
                case 0xe0...0xef: width = 3
                case 0xf0...0xf4: width = 4
                default: width = 1
                }
                if values.count - start < width {
                    let second = start + 1 < values.count ? values[start + 1] : nil
                    let valid = second.map {
                        !(lead == 0xe0 && $0 < 0xa0 || lead == 0xed && $0 > 0x9f ||
                          lead == 0xf0 && $0 < 0x90 || lead == 0xf4 && $0 > 0x8f)
                    } ?? true
                    if valid { split = start }
                }
                break
            }
        }
        pending = Data(values[split...])
        return String(decoding: values[..<split], as: UTF8.self)
    }

    public mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
