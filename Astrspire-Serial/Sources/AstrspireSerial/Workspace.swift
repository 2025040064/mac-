import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SerialCore

enum WorkTab: String, CaseIterable, Codable { case terminal = "串口终端", wave = "实时波形" }

struct SavedCommand: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
    var format: SendFormat
    var ending: LineEnding
}

struct Channel: Codable, Identifiable {
    var id: Int
    var name: String
    var unit = ""
    var shown = true
    var rgb: UInt32
    var color: Color {
        Color(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    static let defaults = [0x34b8f3, 0x32c79c, 0xf9ae42, 0xda74eb, 0xff6767, 0x758aff, 0xb4cf46, 0x38d5d4]
        .enumerated().map { Channel(id: $0, name: "CH\($0 + 1)", rgb: UInt32($1)) }
}

struct Preferences: Codable {
    var serial = SerialSettings()
    var device = ""
    var usbIdentity: String?
    var reconnect = false
    var mode = WireProtocol.raw
    var sampleMs = 10.0
    var tab = WorkTab.terminal
    var showSender = true
    var hexLog = false
    var scroll = true
    var timestamps = true
    var channels = Channel.defaults
    var commands: [SavedCommand] = []
    var history: [SavedCommand] = []
    var format = SendFormat.text
    var ending = LineEnding.none
    var repeatMs = 1000.0
    var frameHead = ""
    var frameTail = ""
    var autoY = true
    var yMin = -1.0
    var yMax = 1.0
    var windowSeconds = 10.0
}

@MainActor
final class Workspace: ObservableObject {
    @Published var prefs: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: "workspace.v1") }
        }
    }
    @Published private(set) var devices: [SerialDevice] = []
    @Published private(set) var state = LinkState.idle
    @Published var notice: String?
    @Published private(set) var snapshot = CaptureSnapshot()
    @Published var terminalPaused = false
    @Published private(set) var displayedRows: [LogRow] = []
    @Published var input = ""
    @Published private(set) var repeatActive = false
    @Published private(set) var sending = false
    @Published private(set) var signal = DemoSignal.off
    @Published var waveEnd: Double?
    @Published var cursorTimes: [Double?] = [nil, nil]
    @Published var activeCursor = 0

    enum LinkState: String { case idle = "未连接", opening = "连接中", open = "已连接", closing = "断开中", waiting = "等待重连" }

    private let defaults: UserDefaults
    private let transport: any SerialTransport
    private let capture: Capture
    private var updateTimer: Timer?
    private var repeatTask: Task<Void, Never>?
    private var repeatPayload: Data?
    private var pendingCommand: SavedCommand?
    private var snapshotPending = false
    private var displayTicks = 0
    private var demoRemainder = 0.0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var reconnectAt = Date.distantPast
    private var reconnectDevice: SerialDevice?
    private var captureFaultHandled = false

    init(transport: any SerialTransport = ORSSerialService(), defaults: UserDefaults = .standard,
         capture: Capture = Capture()) {
        self.transport = transport
        self.capture = capture
        self.defaults = defaults
        var initial = defaults.data(forKey: "workspace.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            ?? Preferences()
        if initial.channels.map(\.id) != Array(0..<8) { initial.channels = Channel.defaults }
        prefs = initial
        transport.event = { [weak self] in self?.handle($0) }
        transport.received = { [weak self] in self?.capture.ingest($0, direction: .rx) }
        transport.sent = { [weak self] in self?.didSend($0, success: $1) }
        startSegment()
        refreshDevices()
        updateTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let updateTimer { RunLoop.main.add(updateTimer, forMode: .common) }
    }

    deinit { updateTimer?.invalidate() }

    func refreshDevices() {
        let available = transport.devices()
        if devices != available { devices = available }
        if state == .open, !available.contains(where: { $0.path == prefs.device }) {
            handle(.removed)
            transport.disconnect()
        }
        if state == .idle, prefs.device.isEmpty, let first = available.first { prefs.device = first.path }
        if state == .waiting, !prefs.reconnect {
            reconnectDevice = nil
            state = .idle
        }
        if state == .waiting, !captureFaultHandled, Date() >= reconnectAt, let previous = reconnectDevice,
           let identity = previous.usbIdentity,
           let device = available.first(where: { $0.path == previous.path && $0.usbIdentity == identity }),
           available.filter({ $0.usbIdentity == identity }).count == 1 {
            connect(device)
        }
    }

    var canConnect: Bool { devices.contains { $0.path == prefs.device } && !captureFaultHandled }
    var canEditConnection: Bool { state == .idle }

    func toggleConnection() {
        switch state {
        case .idle:
            if canConnect, let device = devices.first(where: { $0.path == prefs.device }) { connect(device) }
        case .waiting:
            reconnectDevice = nil
            state = .idle
        case .open:
            reconnectDevice = nil
            stopRepeating()
            state = .closing
            transport.disconnect()
        case .opening, .closing: break
        }
    }

    private func connect(_ device: SerialDevice) {
        guard (1...Int(Int32.max)).contains(prefs.serial.baud),
              (5...8).contains(prefs.serial.dataBits), (1...2).contains(prefs.serial.stopBits) else {
            notice = "串口参数无效。"
            return
        }
        state = .opening
        notice = nil
        prefs.usbIdentity = device.usbIdentity
        reconnectDevice = nil
        if signal == .off { startSegment() }
        transport.connect(device, settings: prefs.serial)
    }

    private func handle(_ event: SerialEvent) {
        switch event {
        case .opened:
            if state == .opening { state = .open }
        case .closed:
            stopRepeating()
            capture.finishRX()
            state = reconnectDevice != nil ? .waiting : .idle
        case .removed:
            guard state == .open || state == .opening else { return }
            stopRepeating()
            let path = prefs.device
            let identity = prefs.usbIdentity
            reconnectDevice = prefs.reconnect && !captureFaultHandled && identity != nil
                ? SerialDevice(path: path, name: path, usbIdentity: identity) : nil
            reconnectAt = Date().addingTimeInterval(1)
            state = .closing
            notice = reconnectDevice != nil ? "设备已拔出，等待同一 USB 设备。" :
                "设备已拔出。请确认设备后手动连接。"
        case .error(let message):
            stopRepeating()
            notice = "串口错误：\(message)"
            if state == .opening {
                state = .closing
                transport.disconnect()
            } else if (state == .open) && !transport.devices().contains(where: { $0.path == prefs.device }) {
                handle(.removed)
                transport.disconnect()
            }
        }
    }

    func sendInput() {
        guard state == .open, !sending else { return }
        do {
            let bytes = try ByteCodec.payload(input, format: prefs.format, ending: prefs.ending)
            let command = SavedCommand(title: input, text: input, format: prefs.format, ending: prefs.ending)
            send(bytes, command: command)
        } catch {
            notice = error.localizedDescription
        }
    }

    func sendCommand(_ command: SavedCommand) {
        guard state == .open, !sending, !repeatActive else { return }
        do {
            let bytes = try ByteCodec.payload(command.text, format: command.format, ending: command.ending)
            send(bytes, command: command)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func send(_ bytes: Data, command: SavedCommand? = nil) {
        guard state == .open, !sending else { return }
        pendingCommand = command
        sending = true
        transport.send(bytes)
    }

    private func didSend(_ bytes: Data, success: Bool) {
        sending = false
        defer { pendingCommand = nil }
        if !bytes.isEmpty { capture.ingest(bytes, direction: .tx) }
        guard success else {
            stopRepeating()
            notice = "发送未完成。本机驱动已接受 \(bytes.count) 个字节。"
            return
        }
        if let pendingCommand {
            prefs.history.removeAll { $0.text == pendingCommand.text && $0.format == pendingCommand.format && $0.ending == pendingCommand.ending }
            prefs.history.insert(pendingCommand, at: 0)
            if prefs.history.count > 50 { prefs.history.removeLast() }
        }
    }

    func toggleRepeat() {
        if repeatActive { stopRepeating(); return }
        guard state == .open, !sending, prefs.repeatMs.isFinite, (10...3_600_000).contains(prefs.repeatMs) else {
            notice = "定时发送间隔须为 10 至 3,600,000 毫秒。"
            return
        }
        do {
            let bytes = try ByteCodec.payload(input, format: prefs.format, ending: prefs.ending)
            let period = Duration.milliseconds(prefs.repeatMs)
            repeatActive = true
            repeatPayload = bytes
            sendInput()
            repeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: period) } catch { return }
                    guard let self, let payload = self.repeatPayload, self.state == .open else { return }
                    self.send(payload)
                }
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatPayload = nil
        repeatActive = false
    }

    func load(_ command: SavedCommand) {
        input = command.text
        prefs.format = command.format
        prefs.ending = command.ending
    }

    func setMode(_ value: WireProtocol) {
        guard value != prefs.mode else { return }
        prefs.mode = value
        if signal == .off { startSegment() }
    }

    func setSignal(_ value: DemoSignal) {
        guard value != signal else { return }
        signal = value
        startSegment()
    }

    func applyInterval(_ value: Double) {
        guard value.isFinite, (0.1...60_000).contains(value) else {
            notice = "采样间隔须为 0.1 至 60,000 毫秒。"
            return
        }
        guard value != prefs.sampleMs else { return }
        prefs.sampleMs = value
        startSegment()
    }

    func startSegment() {
        waveEnd = nil
        cursorTimes = [nil, nil]
        demoRemainder = 0
        capture.begin(mode: prefs.mode, interval: prefs.sampleMs / 1000, source: signal)
    }

    func clearTerminal() {
        displayedRows = []
        capture.clearTerminal()
    }

    func toggleWavePause() {
        if waveEnd == nil {
            waveEnd = snapshot.wave.range.upperBound
            capture.freezeWave(true)
        } else {
            resumeWave()
        }
    }

    func resumeWave() {
        waveEnd = nil
        capture.freezeWave(false)
    }

    func pan(seconds: Double) {
        let wave = snapshot.wave
        waveEnd = min(wave.available.upperBound, max(wave.available.lowerBound, (waveEnd ?? wave.range.upperBound) + seconds))
    }

    private func tick() {
        displayTicks += 1
        if displayTicks.isMultiple(of: 10) { refreshDevices() }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.25, now - lastTick)
        lastTick = now
        guard !snapshotPending else { return }
        if signal != .off {
            let frames = demoRemainder + elapsed / (prefs.sampleMs / 1000)
            capture.generate(Int(frames), for: signal)
            demoRemainder = frames - Double(Int(frames))
        }
        snapshotPending = true
        let duration = prefs.windowSeconds.isFinite ? min(3600, max(0.01, prefs.windowSeconds)) : 10
        capture.snapshot(WaveRequest(duration: duration, end: waveEnd, cursors: cursorTimes,
                                     enabled: prefs.tab == .wave)) { [weak self] value in
            guard let self else { return }
            self.snapshotPending = false
            self.snapshot = value
            if !self.terminalPaused && self.prefs.tab == .terminal { self.displayedRows = value.rows }
            if !self.captureFaultHandled, value.error != nil || value.dropped > 0 {
                self.captureFaultHandled = true
                self.stopRepeating()
                self.reconnectDevice = nil
                if self.state == .open || self.state == .opening {
                    self.state = .closing
                    self.transport.disconnect()
                }
                self.setSignal(.off)
            }
        }
    }

    func export(_ kind: Capture.ExportKind) {
        let panel = NSSavePanel()
        switch kind {
        case .log: panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "serial.txt"
        case .samples:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = signal == .off ? "wave-serial.csv" : "wave-demo.csv"
        case .raw: panel.allowedContentTypes = [.data]; panel.nameFieldStringValue = "rx.bin"
        }
        let columns = prefs.channels.map { $0.unit.isEmpty ? $0.name : "\($0.name) (\($0.unit))" }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.capture.export(kind, to: url, columns: columns) { result in
                switch result {
                case .success: self.notice = "已导出 \(url.lastPathComponent)"
                case .failure(let error): self.notice = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
