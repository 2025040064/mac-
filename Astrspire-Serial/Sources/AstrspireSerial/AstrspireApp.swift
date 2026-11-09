import SwiftUI
import SerialCore

// Use the SwiftUI property wrapper across Xcode and command-line SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct AstrspireApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("Astrspire Serial", id: "workspace") {
            WorkspaceView(model: workspace)
                .frame(minWidth: 890, minHeight: 570)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("导出串口日志…") { workspace.export(.log) }
                Button("导出原始 RX…") { workspace.export(.raw) }
                Button("导出波形 CSV…") { workspace.export(.samples) }
            }
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: Workspace
    @ViewState private var portOptions = false
    @ViewState private var customBaud = false
    @ViewState private var baudEntry = ""
    @ViewState private var commandTitle = ""
    @ViewState private var showCommands = false

    private let rates = [9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600]

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            if let issue = model.snapshot.error ?? (model.snapshot.dropped > 0 ? "后台采集跟不上，已停止连接。未保存字节：\(model.snapshot.dropped)" : nil) {
                banner(issue, color: .red)
            }
            if let notice = model.notice {
                HStack {
                    banner(notice, color: .secondary)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                        .accessibilityLabel("关闭提示")
                }
            }
            VSplitView {
                workspaceContent
                    .frame(minHeight: 200, maxHeight: .infinity)
                sender
                    .frame(minHeight: model.prefs.showSender ? 165 : 0,
                           idealHeight: model.prefs.showSender ? 190 : 44,
                           maxHeight: model.prefs.showSender ? .infinity : 44)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("工作区", selection: $model.prefs.tab) {
                    ForEach(WorkTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 225)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("串口日志 TXT…") { model.export(.log) }
                    Button("原始 RX 字节…") { model.export(.raw) }
                    Button("当前采集段 CSV…") { model.export(.samples) }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var workspaceContent: some View {
        ZStack {
            if model.prefs.tab == .wave {
                WaveformView(model: model)
            } else {
                TerminalView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ value: String, color: Color) -> some View {
        Text(value)
            .foregroundStyle(color)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    private var connectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if model.prefs.tab == .wave {
              Picker("串口", selection: $model.prefs.device) {
                Text("选择串口").tag("")
                if !model.prefs.device.isEmpty, !model.devices.contains(where: { $0.path == model.prefs.device }) {
                    Text("不可用 · \(model.prefs.device)").tag(model.prefs.device)
                }
                ForEach(model.devices) { device in
                    Text("\(device.name)  ·  \(device.path)").tag(device.path)
                }
            }
            .labelsHidden()
            .frame(minWidth: 230, idealWidth: 320, maxWidth: 430)
            .disabled(!model.canEditConnection)
            }
            Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新设备列表")
            if model.prefs.tab == .wave {
              Picker("波特率", selection: $model.prefs.serial.baud) {
                ForEach(Array(Set(rates + [model.prefs.serial.baud])).sorted(), id: \.self) { rate in
                    Text(String(rate)).tag(rate)
                }
            }
            .labelsHidden()
            .frame(width: 95)
            .disabled(!model.canEditConnection)
            }
            Button {
                baudEntry = String(model.prefs.serial.baud)
                customBaud = true
            } label: { Image(systemName: "pencil") }
            .help("自定义波特率")
            .disabled(!model.canEditConnection)
            .popover(isPresented: $customBaud) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("自定义波特率").font(.headline)
                    TextField("Baud", text: $baudEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyBaud)
                    Button("应用", action: applyBaud)
                        .disabled(!validBaud)
                }
                .padding(16)
                .frame(width: 210)
            }
            Button { portOptions = true } label: {
                Label("\(model.prefs.serial.dataBits)\(parityLetter)\(model.prefs.serial.stopBits)", systemImage: "slider.horizontal.3")
            }
            .popover(isPresented: $portOptions) { connectionOptions }
            Spacer(minLength: 0)
            Picker("协议", selection: Binding(get: { model.prefs.mode }, set: model.setMode)) {
                ForEach(WireProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            HStack(spacing: 5) {
                Circle().fill(model.state == .open ? .green : model.state == .waiting ? .orange : .gray)
                    .frame(width: 7, height: 7)
                Text(model.state.rawValue).font(.caption)
            }
            .fixedSize()
            Button(model.state == .open ? "断开" : model.state == .waiting ? "取消重连" : "连接") {
                model.toggleConnection()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state == .opening || model.state == .closing || (model.state == .idle && !model.canConnect))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var parityLetter: String {
        switch model.prefs.serial.parity {
        case .none: "N"
        case .even: "E"
        case .odd: "O"
        }
    }

    private var validBaud: Bool {
        Int(baudEntry).map { (1...Int(Int32.max)).contains($0) } ?? false
    }

    private func applyBaud() {
        guard validBaud, let baud = Int(baudEntry) else { return }
        model.prefs.serial.baud = baud
        customBaud = false
    }

    private var connectionOptions: some View {
        Form {
            Group {
                Picker("数据位", selection: $model.prefs.serial.dataBits) {
                    ForEach(5...8, id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("停止位", selection: $model.prefs.serial.stopBits) {
                    ForEach(1...2, id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("校验", selection: $model.prefs.serial.parity) {
                    ForEach(SerialSettings.Parity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("RTS/CTS", isOn: $model.prefs.serial.hardwareFlow)
            }
            .disabled(!model.canEditConnection)
            Toggle("自动重连同一设备", isOn: $model.prefs.reconnect)
                .help("仅当 USB 序列号唯一且端口路径相同时自动重连")
        }
        .padding(16)
        .frame(width: 290)
    }

    private var sender: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.prefs.showSender.toggle()
                } label: {
                    Label("发送", systemImage: model.prefs.showSender ? "chevron.down" : "chevron.right")
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                Spacer()
                if model.prefs.showSender {
                    Menu("发送历史") {
                        if model.prefs.history.isEmpty { Text("暂无发送历史") }
                        ForEach(model.prefs.history) { command in
                            Button(String(command.title.prefix(45))) { model.load(command) }
                        }
                    }
                    .fixedSize()
                    if let last = model.prefs.history.first {
                        Button("重复上次") { model.load(last); model.sendInput() }
                            .disabled(model.state != .open || model.sending)
                    }
                    Button("快捷指令") { showCommands = true }
                        .popover(isPresented: $showCommands) { commands }
                }
            }
            if model.prefs.showSender {
                TextEditor(text: $model.input)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 58, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                    .accessibilityLabel("发送内容")
                HStack(spacing: 12) {
                    Picker("格式", selection: $model.prefs.format) {
                        ForEach(SendFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 125)
                    Picker("换行", selection: $model.prefs.ending) {
                        ForEach(LineEnding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 125)
                    Spacer()
                    TextField("周期", value: $model.prefs.repeatMs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(model.repeatActive)
                    Text("ms").foregroundStyle(.secondary)
                    Button(model.repeatActive ? "停止定时" : "定时发送") { model.toggleRepeat() }
                        .disabled(model.state != .open)
                    Button("发送") { model.sendInput() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.state != .open || model.sending || model.repeatActive)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷指令").font(.headline)
            Text("收藏当前发送内容及格式").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("指令名称", text: $commandTitle).textFieldStyle(.roundedBorder)
                Button("收藏") {
                    let item = SavedCommand(title: commandTitle, text: model.input, format: model.prefs.format, ending: model.prefs.ending)
                    model.prefs.commands.append(item)
                    commandTitle = ""
                }
                .disabled(commandTitle.trimmingCharacters(in: .whitespaces).isEmpty || model.input.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.prefs.commands) { item in
                        HStack {
                            Button(item.title) { model.load(item); showCommands = false }
                                .buttonStyle(.link)
                            Spacer()
                            Button(model.sending ? "发送中" : "发送") { model.sendCommand(item) }
                                .disabled(model.state != .open || model.sending || model.repeatActive)
                            Button(role: .destructive) {
                                model.prefs.commands.removeAll { $0.id == item.id }
                            } label: { Image(systemName: "trash") }
                            .help("删除收藏")
                        }
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .padding(16)
        .frame(width: 330)
    }
}
