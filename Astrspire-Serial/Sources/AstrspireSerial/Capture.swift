import Foundation
import SerialCore

enum Direction: String, CaseIterable { case rx = "RX", tx = "TX" }
enum DemoSignal: String, CaseIterable {
    case off = "串口", sine = "正弦波", square = "方波", noise = "随机"
}

struct LogRow: Identifiable {
    let id: Int
    let date: Date
    let direction: Direction
    let bytes: Data
    let text: String
    let hex: String
}

struct CaptureSnapshot {
    var rows: [LogRow] = []
    var rx = 0
    var tx = 0
    var invalid = 0
    var error: String?
    var dropped = 0
    var wave = WaveSnapshot()
}

struct WaveSnapshot {
    var segment = 0
    var series = Array(repeating: [Sample](), count: 8)
    var stats = Array(repeating: ChannelStats(), count: 8)
    var range = 0.0...10.0
    var available = 0.0...0.0
    var cursors: [Sample?] = [nil, nil]
    var count = 0
}

struct WaveRequest {
    var duration = 10.0
    var end: Double?
    var cursors: [Double?] = [nil, nil]
    var enabled = false
}

final class Capture {
    private let queue = DispatchQueue(label: "Astrspire.capture", qos: .userInitiated)
    private let backlogLock = NSLock()
    private var pendingBytes = 0
    private var droppedBytes = 0
    private let pendingLimit = 8 * 1024 * 1024
    private let diskLimit = 512 * 1024 * 1024

    private var parser = StreamParser(.raw)
    private var decoder = StreamingUTF8()
    private var samples = SampleStore(interval: 0.01)
    private var frozenSamples: SampleStore?
    private var source = DemoSignal.off
    private var segment = 0
    private var phase = 0.0
    private var rows = [LogRow]()
    private var nextID = 0
    private var rx = 0
    private var tx = 0
    private var diskBytes = 0
    private var error: String?
    private var folder: URL?
    private var logFile: FileHandle?
    private var rawFile: FileHandle?
    private var sampleFile: FileHandle?
    private var sampleURL: URL?
    private let dateFormat = ISO8601DateFormatter()

    init(directory: URL? = nil) {
        dateFormat.formatOptions.insert(.withFractionalSeconds)
        queue.async { self.prepareFiles(directory: directory) }
    }

    private func prepareFiles(directory override: URL?) {
        do {
            let directory: URL
            if let override {
                directory = override
            } else {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                directory = root.appendingPathComponent("Astrspire Serial/Captures", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            folder = directory
            logFile = try Self.createFile(directory.appendingPathComponent("serial.txt"))
            rawFile = try Self.createFile(directory.appendingPathComponent("rx.bin"))
        } catch {
            self.error = "无法创建采集文件：\(error.localizedDescription)"
        }
    }

    private static func createFile(_ url: URL) throws -> FileHandle {
        try Data().write(to: url, options: .withoutOverwriting)
        return try FileHandle(forWritingTo: url)
    }

    private func write(_ data: Data, to file: FileHandle?) {
        guard error == nil, let file, !data.isEmpty else { return }
        guard data.count <= diskLimit - diskBytes else {
            error = "本次运行已达到 512 MiB 采集上限。请导出数据后重新启动应用。"
            return
        }
        do {
            try file.write(contentsOf: data)
            diskBytes += data.count
        } catch {
            self.error = "采集写入失败：\(error.localizedDescription)"
        }
    }

    func begin(mode: WireProtocol, interval: Double, source: DemoSignal) {
        queue.async {
            self.parser = StreamParser(mode)
            self.samples = SampleStore(interval: interval)
            self.frozenSamples = nil
            self.source = source
            self.phase = 0
            self.segment += 1
            try? self.sampleFile?.close()
            self.sampleFile = nil
            self.sampleURL = nil
            guard self.error == nil, let folder = self.folder else { return }
            let url = folder.appendingPathComponent("wave-\(self.segment)-\(source == .off ? "serial" : "demo").csv")
            do {
                self.sampleFile = try Self.createFile(url)
                self.sampleURL = url
            } catch {
                self.error = "无法创建波形采集文件：\(error.localizedDescription)"
            }
        }
    }

    func ingest(_ bytes: Data, direction: Direction, at date: Date = Date()) {
        backlogLock.lock()
        if bytes.count > pendingLimit - pendingBytes || droppedBytes > 0 {
            droppedBytes += bytes.count
            backlogLock.unlock()
            return
        }
        pendingBytes += bytes.count
        backlogLock.unlock()
        queue.async {
            defer {
                self.backlogLock.lock()
                self.pendingBytes -= bytes.count
                self.backlogLock.unlock()
            }
            self.record(bytes, direction: direction, at: date)
        }
    }

    private func record(_ bytes: Data, direction: Direction, at date: Date) {
        if direction == .rx {
            rx += bytes.count
            write(bytes, to: rawFile)
            if source == .off { recordSamples(parser.append(bytes)) }
        } else {
            tx += bytes.count
        }

        let timestamp = dateFormat.string(from: date)
        var log = ""
        var transmitDecoder = StreamingUTF8()
        for offset in stride(from: 0, to: bytes.count, by: 256) {
            let chunk = Data(bytes.dropFirst(offset).prefix(256))
            var text = direction == .rx ? decoder.append(chunk) : transmitDecoder.append(chunk)
            if direction == .tx, offset + chunk.count == bytes.count { text += transmitDecoder.finish() }
            let hex = ByteCodec.hex(chunk)
            rows.append(LogRow(id: nextID, date: date, direction: direction, bytes: chunk, text: text, hex: hex))
            nextID += 1
            log += "\(timestamp) \(direction.rawValue) \(hex)\n"
        }
        if rows.count > 1600 { rows.removeFirst(rows.count - 1600) }
        write(Data(log.utf8), to: logFile)
    }

    func finishRX() {
        queue.async {
            let text = self.decoder.finish()
            guard !text.isEmpty else { return }
            self.rows.append(LogRow(id: self.nextID, date: Date(), direction: .rx, bytes: Data(), text: text, hex: ""))
            self.nextID += 1
        }
    }

    func clearTerminal() { queue.async { self.rows.removeAll(keepingCapacity: true) } }

    private func recordSamples(_ frames: [[Float]]) {
        var csv = ""
        for values in frames {
            let sample = samples.append(values)
            let columns = values.map { String($0) } + Array(repeating: "", count: 8 - values.count)
            csv += ([String(sample.time)] + columns).joined(separator: ",") + "\n"
        }
        write(Data(csv.utf8), to: sampleFile)
    }

    func generate(_ count: Int, for signal: DemoSignal) {
        queue.async {
            guard signal == self.source, signal != .off else { return }
            let frames = (0..<count).map { _ in
                defer { self.phase += self.samples.interval * 2 * .pi }
                return (1...8).map { channel -> Float in
                    let s = sin(self.phase * Double(channel))
                    switch signal {
                    case .off: return 0
                    case .sine: return Float(s)
                    case .square: return s < 0 ? -1 : 1
                    case .noise: return Float.random(in: -1...1)
                    }
                }
            }
            self.recordSamples(frames)
        }
    }

    func freezeWave(_ paused: Bool) {
        queue.async {
            self.frozenSamples = paused ? self.samples : nil
        }
    }

    func snapshot(_ request: WaveRequest, completion: @escaping (CaptureSnapshot) -> Void) {
        queue.async {
            self.backlogLock.lock()
            let dropped = self.droppedBytes
            self.backlogLock.unlock()
            let displaySamples = self.frozenSamples ?? self.samples
            let available = displaySamples.firstTime...displaySamples.lastTime
            let end = max(request.duration, request.end ?? available.upperBound)
            let range = (end - request.duration)...end
            var wave = WaveSnapshot(segment: self.segment, stats: self.samples.statistics, range: range,
                                    available: available, count: self.samples.count)
            if request.enabled {
                wave.series = (0..<8).map { displaySamples.envelope(in: range, channel: $0) }
                wave.cursors = request.cursors.map { $0.flatMap(displaySamples.nearest(to:)) }
            }
            let result = CaptureSnapshot(rows: self.rows, rx: self.rx, tx: self.tx,
                                         invalid: self.parser.invalidFrames, error: self.error, dropped: dropped, wave: wave)
            DispatchQueue.main.async { completion(result) }
        }
    }

    enum ExportKind { case log, samples, raw }

    func export(_ kind: ExportKind, to destination: URL, columns: [String],
                completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let url: URL?
            let handle: FileHandle?
            let header: String
            switch kind {
            case .log:
                url = self.folder?.appendingPathComponent("serial.txt")
                handle = self.logFile
                header = ""
            case .raw:
                url = self.folder?.appendingPathComponent("rx.bin")
                handle = self.rawFile
                header = ""
            case .samples:
                url = self.sampleURL
                handle = self.sampleFile
                let labels = columns.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                header = "\u{feff}" + (["time_s"] + labels).joined(separator: ",") + "\n"
            }
            let length = try? handle?.offset()
            DispatchQueue.global(qos: .utility).async {
                let result = Result {
                    guard let url, let length else { throw CocoaError(.fileReadNoSuchFile) }
                    try Self.copyPrefix(of: url, length: length, header: header, to: destination)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func copyPrefix(of source: URL, length: UInt64, header: String, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let output = try createFile(temporary)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try output.write(contentsOf: Data(header.utf8))
        var remaining = length
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
