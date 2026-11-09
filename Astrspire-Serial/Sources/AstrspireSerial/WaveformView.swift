import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers
import SerialCore

struct WaveformView: View {
    @ObservedObject var model: Workspace
    @Environment(\.colorScheme) private var appearance
    @ViewState private var interval = 10.0
    @ViewState private var previousDrag = 0.0
    @ViewState private var confirmClear = false

    private var wave: WaveSnapshot { model.snapshot.wave }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(model.signal == .off ? model.prefs.mode.rawValue : "模拟 · \(model.signal.rawValue)",
                              systemImage: model.signal == .off ? "waveform" : "testtube.2")
                            .foregroundStyle(model.signal == .off ? Color.secondary : .orange)
                        Spacer()
                        Text("\(wave.count.formatted()) 组采样")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    if wave.count == 0 {
                        ContentUnavailableView(
                            "等待采样",
                            systemImage: "waveform.path",
                            description: Text(model.prefs.mode == .raw && model.signal == .off
                                              ? "选择 FireWater 或 JustFloat，也可以使用模拟信号。"
                                              : "收到有效采样帧后开始绘图。")
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        plotWithGestures
                    }
                    measurement
                }
                .padding(14)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                channels
            }
        }
        .onAppear { interval = model.prefs.sampleMs }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Picker("数据源", selection: Binding(get: { model.signal }, set: { model.setSignal($0) })) {
                ForEach(DemoSignal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 142)
            TextField("采样间隔", value: $interval, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onSubmit { model.applyInterval(interval) }
                .accessibilityLabel("采样间隔毫秒")
            Text("ms").foregroundStyle(.secondary)
            Button("应用") { model.applyInterval(interval) }
                .disabled(interval == model.prefs.sampleMs)
            Spacer(minLength: 0)
            Button(model.waveEnd == nil ? "暂停" : "实时", systemImage: model.waveEnd == nil ? "pause" : "play") {
                model.toggleWavePause()
            }
            .disabled(wave.count == 0)
            Button("适配", systemImage: "arrow.up.left.and.arrow.down.right") {
                model.prefs.autoY = true
                model.prefs.windowSeconds = max(0.01, min(3600, wave.available.upperBound - wave.available.lowerBound + model.prefs.sampleMs / 1000))
                model.resumeWave()
            }
            Button("PNG", systemImage: "camera") { exportPNG() }.disabled(wave.count == 0)
            Button("CSV", systemImage: "tablecells") { model.export(.samples) }.disabled(wave.count == 0)
            Button("清空", systemImage: "trash") { confirmClear = true }
                .confirmationDialog("开始新的波形采集段？", isPresented: $confirmClear) {
                    Button("清空波形", role: .destructive) { model.startSegment() }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var plot: WavePlot {
        WavePlot(wave: wave, channels: model.prefs.channels, yRange: yRange)
    }

    private var plotWithGestures: some View {
        plot
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(width: frame.width, height: frame.height)
                            .gesture(DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    let change = value.translation.width - previousDrag
                                    previousDrag = value.translation.width
                                    model.pan(seconds: -Double(change / max(1, frame.width)) * model.prefs.windowSeconds)
                                }
                                .onEnded { _ in previousDrag = 0 })
                            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                                guard let time: Double = proxy.value(atX: value.location.x) else { return }
                                model.cursorTimes[model.activeCursor] = min(wave.available.upperBound, max(wave.available.lowerBound, time))
                            })
                            .background(ScrollWheelMonitor { delta in
                                let scale = exp(max(-50, min(50, delta)) * 0.022)
                                model.prefs.windowSeconds = min(3600, max(0.01, model.prefs.windowSeconds * scale))
                            })
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(maxHeight: .infinity)
    }

    private var yRange: ClosedRange<Double> {
        if !model.prefs.autoY, model.prefs.yMin.isFinite, model.prefs.yMax.isFinite,
           model.prefs.yMin < model.prefs.yMax {
            return model.prefs.yMin...model.prefs.yMax
        }
        let values = model.prefs.channels.filter(\.shown).flatMap { channel in
            wave.series[channel.id].map { Double($0.values[channel.id]) }
        }
        guard let lo = values.min(), let hi = values.max() else { return -1...1 }
        let padding = lo == hi ? max(abs(lo) * 0.05, 0.1) : (hi - lo) * 0.08
        return (lo - padding)...(hi + padding)
    }

    private var measurement: some View {
        HStack {
            Picker("游标", selection: $model.activeCursor) {
                Text("A").tag(0)
                Text("B").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Text(wave.cursors[0].map { "A \(number($0.time)) s" } ?? "A —")
            Text(wave.cursors[1].map { "B \(number($0.time)) s" } ?? "B —")
            if let a = wave.cursors[0], let b = wave.cursors[1] {
                Text("Δt \(number(b.time - a.time)) s")
            }
            Spacer()
            Text(model.waveEnd == nil ? "滚轮缩放 · 拖动查看历史 · 点击定位游标" : "历史视图 · 采集继续")
                .foregroundStyle(.secondary)
            if model.cursorTimes.contains(where: { $0 != nil }) {
                Button("重置") { model.cursorTimes = [nil, nil] }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var channels: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("通道").font(.headline)
                Spacer()
                Text("当前采集段统计").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Y 轴自动量程", isOn: $model.prefs.autoY)
            if !model.prefs.autoY {
                HStack {
                    TextField("最小", value: $model.prefs.yMin, format: .number).accessibilityLabel("Y 轴最小值")
                    Text("至")
                    TextField("最大", value: $model.prefs.yMax, format: .number).accessibilityLabel("Y 轴最大值")
                }
                if model.prefs.yMin >= model.prefs.yMax {
                    Text("最小值必须小于最大值。").font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.prefs.channels) { $channel in
                        channelRow($channel)
                    }
                }
            }
        }
        .padding(12)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 260, idealWidth: 294, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    private func channelRow(_ channel: Binding<Channel>) -> some View {
        let index = channel.wrappedValue.id
        let stats = wave.stats[index]
        let a = value(at: 0, channel: index)
        let b = value(at: 1, channel: index)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle("显示通道 \(index + 1)", isOn: channel.shown).labelsHidden()
                ColorPicker("通道颜色", selection: Binding(
                    get: { channel.wrappedValue.color },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        channel.wrappedValue.rgb = UInt32((rgb.redComponent * 255).rounded()) << 16 |
                            UInt32((rgb.greenComponent * 255).rounded()) << 8 | UInt32((rgb.blueComponent * 255).rounded())
                    }), supportsOpacity: false)
                .labelsHidden()
                TextField("名称", text: channel.name)
                TextField("单位", text: channel.unit).frame(width: 52)
            }
            HStack {
                Text("当前 \(number(stats.latest.map(Double.init)))")
                Spacer()
                Text("均值 \(number(stats.mean))")
            }
            HStack {
                Text("最小 \(number(stats.min.map(Double.init)))")
                Spacer()
                Text("最大 \(number(stats.max.map(Double.init)))")
            }
            if a != nil || b != nil {
                Text("A \(number(a))  B \(number(b))  ΔY \(number(a.flatMap { first in b.map { $0 - first } }))")
            }
            Divider()
        }
        .font(.caption.monospacedDigit())
    }

    private func value(at cursor: Int, channel: Int) -> Double? {
        guard let values = wave.cursors[cursor]?.values, values.indices.contains(channel) else { return nil }
        return Double(values[channel])
    }

    private func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.significantDigits(1...6))) } ?? "—"
    }

    private func exportPNG() {
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 12) {
            Text("Astrspire Serial · \(model.signal == .off ? model.prefs.mode.rawValue : "模拟 " + model.signal.rawValue)")
                .font(.headline)
            plot
        }
        .padding(18)
        .frame(width: 1100, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            model.notice = "无法生成波形快照。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = model.signal == .off ? "wave-serial.png" : "wave-demo.png"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try bytes.write(to: url, options: .atomic)
                model.notice = "已导出 \(url.lastPathComponent)"
            } catch {
                model.notice = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct WavePlot: View {
    let wave: WaveSnapshot
    let channels: [Channel]
    let yRange: ClosedRange<Double>

    var body: some View {
        Chart {
            ForEach(channels.filter(\.shown)) { channel in
                ForEach(wave.series[channel.id]) { sample in
                    LineMark(
                        x: .value("时间", sample.time),
                        y: .value("采样值", sample.values[channel.id]),
                        series: .value("通道", channel.id)
                    )
                    .foregroundStyle(channel.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(0..<2, id: \.self) { index in
                if let sample = wave.cursors[index] {
                    RuleMark(x: .value("游标", sample.time))
                        .foregroundStyle(index == 0 ? Color.blue : Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top) { Text(index == 0 ? "A" : "B").font(.caption.bold()) }
                }
            }
        }
        .chartXScale(domain: wave.range)
        .chartYScale(domain: yRange)
        .chartXAxisLabel("推算采样时间 (s)")
        .chartPlotStyle { content in
            content.clipped().background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.onScroll = onScroll }

    final class MonitorView: NSView {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.window === event.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onScroll?(event.scrollingDeltaY)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
