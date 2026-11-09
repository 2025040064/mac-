import AppKit
import SwiftUI
import SerialCore

struct TerminalView: View {
    @ObservedObject var model: Workspace
    @ViewState private var query = ""
    @ViewState private var direction: Direction?
    @ViewState private var inspector = false
    @ViewState private var showPanel = true
    @ViewState private var selected: LogRow?
    @ViewState private var start = 0
    @ViewState private var length = 0
    @ViewState private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var visible: [LogRow] {
        model.displayedRows.filter { row in
            if let direction, row.direction != direction { return false }
            let content = model.prefs.hexLog ? row.hex : row.text
            return query.isEmpty || content.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let rows = visible
        VStack(spacing: 0) {
            controls
            Divider()
            HSplitView {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if rows.isEmpty {
                                ContentUnavailableView(
                                    query.isEmpty ? "暂无串口数据" : "没有匹配的日志",
                                    systemImage: "terminal",
                                    description: Text(query.isEmpty ? "连接设备后，收发数据会显示在这里。" : "请调整关键词或方向筛选。")
                                )
                                .padding(.top, 36)
                            }
                            ForEach(rows) { row in
                                rowView(row)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: rows.last?.id) {
                        if model.prefs.scroll && !model.terminalPaused { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: model.prefs.scroll) {
                        if model.prefs.scroll { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if inspector {
                    byteInspector
                } else if showPanel {
                    debugPanel
                }
            }
            Divider()
            HStack(spacing: 18) {
                Text("RX \(model.snapshot.rx.formatted()) B").foregroundStyle(.blue)
                Text("TX \(model.snapshot.tx.formatted()) B").foregroundStyle(.orange)
                if model.snapshot.invalid > 0 {
                    Label("协议异常 \(model.snapshot.invalid.formatted())", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if model.terminalPaused { Text("显示已暂停 · 采集继续").foregroundStyle(.orange) }
                Text("显示最近 1,600 条 · 完整记录可导出").foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("显示格式", selection: $model.prefs.hexLog) {
                Text("文本").tag(false)
                Text("HEX").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 125)
            Picker("方向", selection: $direction) {
                Text("全部").tag(nil as Direction?)
                ForEach(Direction.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 82)
            TextField("搜索日志", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .frame(minWidth: 100, maxWidth: 255)
            Button("搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle("时间戳", isOn: $model.prefs.timestamps)
            Toggle("自动滚动", isOn: $model.prefs.scroll)
            Button(model.terminalPaused ? "恢复" : "暂停", systemImage: model.terminalPaused ? "play" : "pause") {
                model.terminalPaused.toggle()
            }
            Button("字节分析", systemImage: "number") { inspector.toggle() }
            Button { if inspector { inspector = false; showPanel = true } else { showPanel.toggle() } } label: {
                Image(systemName: "sidebar.right")
            }
            .help(showPanel && !inspector ? "隐藏调试面板" : "显示调试面板")
            .accessibilityLabel(showPanel && !inspector ? "隐藏调试面板" : "显示调试面板")
            Button("清空", systemImage: "trash") { confirmClear = true }
                .confirmationDialog("清空当前终端视图？", isPresented: $confirmClear) {
                    Button("清空显示", role: .destructive) { model.clearTerminal(); selected = nil }
                } message: { Text("已采集的日志仍可导出。") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var debugPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("调试面板").font(.headline)
                    Spacer()
                    Button { showPanel = false } label: { Image(systemName: "sidebar.right") }
                        .help("隐藏调试面板")
                }
                panelCard {
                    HStack {
                        Text("连接状态").font(.headline)
                        Spacer()
                        Label(model.state.rawValue, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(model.state == .open ? Color.green : Color.secondary)
                    }
                    LabeledContent("串口") {
                        Picker("串口", selection: $model.prefs.device) {
                            Text("选择串口").tag("")
                            if !model.prefs.device.isEmpty, !model.devices.contains(where: { $0.path == model.prefs.device }) {
                                Text("不可用 · \(model.prefs.device)").tag(model.prefs.device)
                            }
                            ForEach(model.devices) { device in
                                Text(device.path).tag(device.path)
                            }
                        }
                        .labelsHidden().disabled(!model.canEditConnection)
                    }
                    LabeledContent("波特率") {
                        Picker("波特率", selection: $model.prefs.serial.baud) {
                            ForEach(Array(Set([9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600, model.prefs.serial.baud])).sorted(), id: \.self) { rate in
                                Text(String(rate)).tag(rate)
                            }
                        }
                        .labelsHidden().disabled(!model.canEditConnection)
                    }
                    Divider()
                    LabeledContent("收发统计") {
                        Text("RX: \(model.snapshot.rx.formatted()) B   TX: \(model.snapshot.tx.formatted()) B")
                            .monospacedDigit().font(.caption)
                    }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 270, idealWidth: 320, maxWidth: 440, maxHeight: .infinity)
        .background(.bar)
    }

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
    }

    private func rowView(_ row: LogRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if model.prefs.timestamps {
                Text(row.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
            }
            Text(row.direction.rawValue)
                .fontWeight(.semibold)
                .foregroundStyle(row.direction == .rx ? .blue : .orange)
            Text(model.prefs.hexLog ? highlighted(row.bytes) : AttributedString(row.text.isEmpty ? " " : row.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(selected?.id == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            Button("分析原始字节") { select(row) }
            Button("复制 HEX") { copy(row.hex) }
            Button("复制文本") { copy(row.text) }
        }
        .onTapGesture(count: 2) { select(row) }
    }

    private func select(_ row: LogRow) {
        selected = row
        start = 0
        length = row.bytes.count
        inspector = true
    }

    private var byteInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEX 字节分析").font(.headline)
            Text("双击日志条目查看原始字节").font(.caption).foregroundStyle(.secondary)
            TextField("帧头，例如 AA 55", text: $model.prefs.frameHead)
            TextField("帧尾，例如 0D 0A", text: $model.prefs.frameTail)
            if (try? ByteCodec.parseHex(model.prefs.frameHead)) == nil || (try? ByteCodec.parseHex(model.prefs.frameTail)) == nil {
                Text("帧头和帧尾必须是完整的 HEX 字节。").font(.caption).foregroundStyle(.red)
            }
            if let selected, !selected.bytes.isEmpty {
                Divider()
                HStack {
                    Text("起始").foregroundStyle(.secondary)
                    TextField("起始", value: $start, format: .number)
                    Text("长度").foregroundStyle(.secondary)
                    TextField("长度", value: $length, format: .number)
                }
                let from = max(0, min(start, selected.bytes.count))
                let count = max(0, min(length, selected.bytes.count - from))
                let bytes = Data(selected.bytes.dropFirst(from).prefix(count))
                ScrollView {
                    Text(highlighted(bytes))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 115)
                Text(String(format: "XOR %02X     SUM8 %02X", ByteCodec.xor(bytes), ByteCodec.sum8(bytes)))
                    .font(.caption.monospaced())
                let crc = ByteCodec.crc16Modbus(bytes)
                Text(String(format: "CRC-16/MODBUS %02X %02X", crc & 255, crc >> 8)).font(.caption.monospaced())
                Button("复制选中字节") { copy(ByteCodec.hex(bytes)) }.disabled(bytes.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(width: 255)
        .background(.bar)
    }

    private func highlighted(_ data: Data) -> AttributedString {
        let head = (try? ByteCodec.parseHex(model.prefs.frameHead)) ?? Data()
        let tail = (try? ByteCodec.parseHex(model.prefs.frameTail)) ?? Data()
        if head.isEmpty && tail.isEmpty { return AttributedString(ByteCodec.hex(data)) }
        let headerBytes = matchingIndices(of: head, in: data)
        let trailerBytes = matchingIndices(of: tail, in: data)
        var result = AttributedString()
        for (index, byte) in data.enumerated() {
            var part = AttributedString((index == 0 ? "" : " ") + String(format: "%02X", byte))
            if headerBytes.contains(index) { part.foregroundColor = .teal }
            if trailerBytes.contains(index) { part.foregroundColor = .orange }
            result += part
        }
        return result
    }

    private func matchingIndices(of pattern: Data, in data: Data) -> IndexSet {
        guard !pattern.isEmpty, pattern.count <= data.count else { return [] }
        var matches = IndexSet()
        var start = data.startIndex
        while let range = data.range(of: pattern, in: start..<data.endIndex) {
            matches.insert(integersIn: range)
            start = range.upperBound
        }
        return matches
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
