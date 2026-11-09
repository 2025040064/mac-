import Foundation

public enum WireProtocol: String, Codable, CaseIterable {
    case raw = "RawData", fireWater = "FireWater", justFloat = "JustFloat"
}

public struct StreamParser {
    public let mode: WireProtocol
    public private(set) var invalidFrames = 0
    private let lineLimit: Int
    private var line = [UInt8]()
    private var skippingLine = false
    private var binary = [UInt8]()
    private var binaryOverflow = false
    private var tail: UInt32 = 0
    private var count = 0

    public init(_ mode: WireProtocol, lineLimit: Int = 4096) {
        self.mode = mode
        self.lineLimit = max(1, lineLimit)
    }

    public mutating func append(_ bytes: Data) -> [[Float]] {
        switch mode {
        case .raw: []
        case .fireWater: parseLines(bytes)
        case .justFloat: parseBinary(bytes)
        }
    }

    private mutating func parseLines(_ bytes: Data) -> [[Float]] {
        var frames = [[Float]]()
        for byte in bytes {
            if byte == 10 {
                if !skippingLine, let frame = Self.fireWaterFrame(line) {
                    frames.append(frame)
                } else if !skippingLine && line.contains(where: { $0 != 13 && $0 != 32 && $0 != 9 }) {
                    invalidFrames += 1
                }
                line.removeAll(keepingCapacity: true)
                skippingLine = false
            } else if !skippingLine {
                if line.count == lineLimit {
                    skippingLine = true
                    line.removeAll(keepingCapacity: true)
                    invalidFrames += 1
                } else {
                    line.append(byte)
                }
            }
        }
        return frames
    }

    private static func fireWaterFrame(_ bytes: [UInt8]) -> [Float]? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let payload = parts.last else { return nil }
        if parts.count > 1, parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines) == "image" {
            return nil
        }
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...8).contains(fields.count) else { return nil }
        var frame = [Float]()
        for field in fields {
            guard let value = Float(field.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                return nil
            }
            frame.append(value)
        }
        return frame
    }

    private mutating func parseBinary(_ bytes: Data) -> [[Float]] {
        var frames = [[Float]]()
        for byte in bytes {
            tail = (tail << 8) | UInt32(byte)
            count = min(4, count + 1)
            if !binaryOverflow {
                binary.append(byte)
                if binary.count > 36 {
                    binary.removeAll(keepingCapacity: true)
                    binaryOverflow = true
                    invalidFrames += 1
                }
            }
            guard count == 4, tail == 0x0000807f else { continue }
            if !binaryOverflow {
                let length = binary.count - 4
                if length >= 4, length.isMultiple(of: 4) {
                    let values = stride(from: 0, to: length, by: 4).map { i in
                        Float(bitPattern: UInt32(binary[i]) | UInt32(binary[i + 1]) << 8 |
                              UInt32(binary[i + 2]) << 16 | UInt32(binary[i + 3]) << 24)
                    }
                    if values.allSatisfy(\.isFinite) { frames.append(values) }
                    else { invalidFrames += 1 }
                } else {
                    invalidFrames += 1
                }
            }
            binaryOverflow = false
            binary.removeAll(keepingCapacity: true)
            count = 0
            tail = 0
        }
        return frames
    }
}
