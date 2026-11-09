import Darwin
import Foundation
import Testing
@testable import AstrspireSerial

@MainActor
@Test func serialRoundTripThroughDarwinPseudoTerminal() async throws {
    let master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK)
    try #require(master >= 0, "Could not open a Darwin pseudo terminal: \(String(cString: strerror(errno)))")
    defer { Darwin.close(master) }
    try #require(grantpt(master) == 0 && unlockpt(master) == 0)
    let name = try #require(ptsname(master))
    let path = String(cString: name)
    let transport = ORSSerialService()
    var opened = false
    var closed = false
    var serialError: String?
    var received = Data()
    var sent: Bool?
    transport.event = { event in
        switch event {
        case .opened: opened = true
        case .closed: closed = true
        case .removed: break
        case .error(let message): serialError = message
        }
    }
    transport.received = { received.append($0) }
    transport.sent = { _, success in sent = success }
    defer { transport.disconnect() }

    transport.connect(SerialDevice(path: path, name: "PTY", usbIdentity: nil), settings: SerialSettings())
    for _ in 0..<100 {
        if opened || serialError != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(opened, "Serial open failed: \(serialError ?? "no callback")")
    let slave = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    // Some drivers disallow a second open after O_EXLOCK. The actual transfer
    // verifies the configured line can still move all byte values unchanged.
    if slave >= 0 { Darwin.close(slave) }

    let expectedRX = Data([0, 0xff, 0x0d, 0x0a, 0x80, 0x55])
    let written = expectedRX.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    try #require(written == expectedRX.count)
    let expectedTX = Data([0xaa, 0x55, 0x01, 0, 0x0d, 0x0a])
    transport.send(expectedTX)
    var actualTX = Data()
    for _ in 0..<100 {
        var buffer = [UInt8](repeating: 0, count: 32)
        let readCount = Darwin.read(master, &buffer, buffer.count)
        if readCount > 0 { actualTX.append(contentsOf: buffer.prefix(readCount)) }
        if received.count >= expectedRX.count && actualTX.count >= expectedTX.count && sent != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(received == expectedRX)
    #expect(actualTX == expectedTX)
    #expect(sent == true)
    transport.disconnect()
    for _ in 0..<100 {
        if closed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(closed)
}
