import Foundation
import Testing
import SerialCore
@testable import AstrspireSerial

private func snapshot(_ capture: Capture, request: WaveRequest = .init()) async -> CaptureSnapshot {
    await withCheckedContinuation { continuation in
        capture.snapshot(request) { continuation.resume(returning: $0) }
    }
}

private func export(_ capture: Capture, _ kind: Capture.ExportKind, to url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
        capture.export(kind, to: url, columns: (1...8).map { "CH\($0)" }) { continuation.resume(with: $0) }
    }
}

@Test func capturePreservesBytesAndSamplesWhileViewIsFrozen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = Capture(directory: directory)
    capture.begin(mode: .fireWater, interval: 0.001, source: .off)
    let chunk = Data(String(repeating: "d:1,2,3,4,5,6,7,8\n", count: 500).utf8)
    for _ in 0..<40 { capture.ingest(chunk, direction: .rx) }
    capture.freezeWave(true)
    let frozen = WaveRequest(duration: 30, end: 30, cursors: [1.1, 3.5], enabled: true)
    let first = await snapshot(capture, request: frozen)
    for _ in 0..<6 { capture.ingest(chunk, direction: .rx) }
    let second = await snapshot(capture, request: frozen)

    #expect(first.error == nil)
    #expect(second.error == nil)
    #expect(second.dropped == 0)
    #expect(second.rx == chunk.count * 46)
    #expect(second.rows.count == 1600)
    #expect(first.wave.range == second.wave.range)
    #expect(first.wave.series == second.wave.series)
    #expect(second.wave.count == 23_000)
    #expect(second.wave.cursors[0]?.values == [1, 2, 3, 4, 5, 6, 7, 8])

    let raw = directory.appendingPathComponent("export.bin")
    try await export(capture, .raw, to: raw)
    #expect(try Data(contentsOf: raw) == (0..<46).reduce(into: Data()) { data, _ in data.append(chunk) })
    let csv = directory.appendingPathComponent("export.csv")
    try await export(capture, .samples, to: csv)
    let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 23_001)
    #expect(lines[1] == "0.0,1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0")

    capture.ingest(Data("partial".utf8), direction: .rx)
    capture.begin(mode: .justFloat, interval: 0.01, source: .off)
    capture.ingest(Data([0, 0, 128, 63, 0, 0, 128, 127]), direction: .rx)
    let switched = await snapshot(capture)
    #expect(switched.wave.count == 1)
    #expect(switched.wave.stats[0].latest == 1)
    #expect(switched.invalid == 0)
}

@MainActor
@Test func reconnectRequiresMatchingDeviceAndStopsRepeating() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "AstrspireTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = MockTransport()
    let device = SerialDevice(path: "/dev/cu.test", name: "USB", usbIdentity: "123:456:unique")
    transport.available = [device]
    let model = Workspace(transport: transport, defaults: defaults, capture: Capture(directory: folder))
    model.prefs.reconnect = true
    model.toggleConnection()
    #expect(model.state == .open)
    model.input = "STATUS"
    model.toggleRepeat()
    #expect(model.repeatActive)
    transport.available = []
    model.refreshDevices()
    #expect(model.state == .waiting)
    #expect(!model.repeatActive)
    transport.available = [SerialDevice(path: device.path, name: "Different", usbIdentity: "different")]
    try await Task.sleep(for: .milliseconds(1100))
    model.refreshDevices()
    #expect(model.state == .waiting)
    transport.available = [device]
    model.refreshDevices()
    #expect(model.state == .open)
    #expect(transport.opens == [device, device])
}

private final class MockTransport: SerialTransport {
    var event: ((SerialEvent) -> Void)?
    var received: ((Data) -> Void)?
    var sent: ((Data, Bool) -> Void)?
    var available: [SerialDevice] = []
    var opens: [SerialDevice] = []

    func devices() -> [SerialDevice] { available }
    func connect(_ device: SerialDevice, settings: SerialSettings) { opens.append(device); event?(.opened) }
    func disconnect() { event?(.closed) }
    func send(_ data: Data) { sent?(data, true) }
}
