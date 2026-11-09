import Foundation
import Testing
@testable import SerialCore

@Test func hexPayloadAndValidation() throws {
    #expect(try ByteCodec.payload("AA 55 01 02 0D 0A", format: .hex, ending: .none) == Data([170, 85, 1, 2, 13, 10]))
    #expect(try ByteCodec.payload("状态", format: .text, ending: .crlf) == Data("状态\r\n".utf8))
    #expect(throws: ByteCodec.InputError.invalidHex) { try ByteCodec.parseHex("AA 5 Z0") }
    #expect(throws: ByteCodec.InputError.invalidHex) { try ByteCodec.parseHex("0xAB") }
}

@Test func streamingUTF8PreservesAllCharacterBoundaries() {
    let message = "ASCII 波形 🔌"
    let bytes = Data(message.utf8)
    for split in 0...bytes.count {
        var decoder = StreamingUTF8()
        let output = decoder.append(bytes.prefix(split)) + decoder.append(bytes.dropFirst(split)) + decoder.finish()
        #expect(output == message)
    }
    var decoder = StreamingUTF8()
    #expect(decoder.append(Data([0xff, 0xe4, 0xb8])) == "�")
    #expect(decoder.finish() == "�")
}

@Test func fireWaterOfficialNumericExamplesAtAllSplits() {
    let bytes = Data("channels: 1.386578,0.977929,-0.628913,-0.942729\r\n1.386578,0.977929,-0.628913,-0.942729\n\rd:1.2,2.35,3.6\n".utf8)
    let frame: [Float] = [1.386578, 0.977929, -0.628913, -0.942729]
    for split in 0...bytes.count {
        var parser = StreamParser(.fireWater)
        let result = parser.append(bytes.prefix(split)) + parser.append(bytes.dropFirst(split))
        #expect(result == [frame, frame, [1.2, 2.35, 3.6]])
        #expect(parser.invalidFrames == 0)
    }
    var parser = StreamParser(.fireWater, lineLimit: 10)
    #expect(parser.append(Data("d:12,".utf8)).isEmpty)
    #expect(parser.append(Data("2\nimage:1\nd:1,nan\n0123456789bad\n1,2\n".utf8)) == [[12, 2], [1, 2]])
    #expect(parser.invalidFrames == 3)
}

@Test func justFloatOfficialFrameAndRecovery() {
    let official = Data([0xbf, 0x10, 0x59, 0x3f, 0xb1, 0x02, 0x95, 0x3e,
                         0x57, 0xa6, 0x16, 0xbe, 0x7b, 0x4d, 0x7f, 0xbf, 0, 0, 128, 127])
    let expected = [0x3f5910bf, 0x3e9502b1, 0xbe16a657, 0xbf7f4d7b].map { Float(bitPattern: $0) }
    for split in 0...official.count {
        var parser = StreamParser(.justFloat)
        let result = parser.append(official.prefix(split)) + parser.append(official.dropFirst(split) + official)
        #expect(result == [expected, expected])
    }
    var parser = StreamParser(.justFloat)
    let single = Data([0, 0, 128, 63, 0, 0, 128, 127])
    let nan = Data([0, 0, 192, 127, 0, 0, 128, 127])
    let garbage = Data(repeating: 0xaa, count: 100_000)
    #expect(parser.append(garbage + single + nan + single) == [[1]])
    #expect(parser.invalidFrames == 2)
    var raw = StreamParser(.raw)
    #expect(raw.append(official).isEmpty)
}

@Test func sampleRetentionStatisticsAndEnvelope() {
    var store = SampleStore(interval: 0.01, capacity: 10)
    for index in 0..<15 { store.append([index == 8 ? 100 : Float(index)]) }
    #expect(store.firstTime == 0.05)
    #expect(abs(store.lastTime - 0.14) < 1e-12)
    #expect(store.nearest(to: 0.02) == nil)
    #expect(store.nearest(to: 0.079)?.values == [100])
    #expect(store.envelope(in: 0...0.14, channel: 0, buckets: 1).map(\.values) == [[5], [100]])
    #expect(store.statistics[0].count == 15)
    #expect(store.statistics[0].latest == 14)
    #expect(store.statistics[0].min == 0)
    #expect(store.statistics[0].max == 100)
    #expect(store.statistics[0].mean == 197.0 / 15.0)
}

@Test func crcStandardVector() {
    let data = Data("123456789".utf8)
    #expect(ByteCodec.crc16Modbus(data) == 0x4b37)
    #expect(ByteCodec.xor(data) == 0x31)
    #expect(ByteCodec.sum8(data) == 0xdd)
}
