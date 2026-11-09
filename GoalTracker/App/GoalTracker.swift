import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

// Use the SwiftUI property wrapper, including in command-line SDK builds.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [Competition] = []
    @Published var storageError: String?
    @Published var serverStatus = "正在启动…"
    @Published private(set) var token = UserDefaults.standard.string(forKey: "importToken") ?? UUID().uuidString + UUID().uuidString
    private var server: ImportServer?
    private var file: URL?

    init() {
        load()
        UserDefaults.standard.set(token, forKey: "importToken")
        server = ImportServer(status: { [weak self] status in
            self?.serverStatus = status
        }, submit: { [weak self] token, data in
            guard let self else { return .error(503, "应用正在退出") }
            guard token == self.token else { return .error(401, "令牌无效") }
            let incoming: [Competition]
            do { incoming = try Schedule.decode(data) }
            catch { return .error(400, String(describing: error)) }
            do { return try self.importItems(incoming) }
            catch { return .error(500, error.localizedDescription) }
        })
    }

    func load() {
        do {
            let url = try Schedule.fileURL()
            items = try Schedule.read(from: url)
            file = url
            storageError = nil
        } catch {
            file = nil
            storageError = error.localizedDescription
        }
    }

    func rotateToken() {
        token = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(token, forKey: "importToken")
    }

    func save(_ updated: [Competition]) throws {
        guard let file else { throw Problem(storageError ?? "共享存储不可用") }
        guard updated != items else { return }
        try Schedule.write(updated, to: file)
        items = updated
        WidgetCenter.shared.reloadTimelines(ofKind: Schedule.kind)
    }

    func importItems(_ incoming: [Competition]) throws -> Reply {
        let ids = Set(items.map(\.id))
        let updated = incoming.filter { ids.contains($0.id) }.count
        try save(Schedule.merged(items, with: incoming))
        return Reply(status: 200, body: ["inserted": incoming.count - updated, "updated": updated])
    }
}

@main
struct GoalTrackerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("GoalTracker", id: "countdown") {
            CountdownWindow(store: store)
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 390, height: 350)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                OpenScheduleButton()
            }
        }

        Window("GoalTracker · 赛程", id: "schedule") {
            ScheduleView(store: store)
                .handlesExternalEvents(preferring: ["open-all-competitions"], allowing: ["open-all-competitions"])
        }
        .handlesExternalEvents(matching: ["open-all-competitions"])
        .defaultSize(width: 720, height: 550)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            Form {
                LabeledContent("本机接口", value: "http://127.0.0.1:18765/competitions")
                LabeledContent("状态", value: store.serverStatus)
                LabeledContent("Bearer Token") {
                    Text(store.token).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("重新生成令牌", action: store.rotateToken)
            }.padding(24).frame(width: 620)
        }
    }
}

private struct ScheduleView: View {
    @ObservedObject var store: Store
    @ViewState private var editor: Competition?
    @ViewState private var deletion: Competition?
    @ViewState private var picking = false
    @ViewState private var pending: ImportPreview?
    @ViewState private var message: String?
    @ViewState private var now = Date()

    var body: some View {
        List {
            if let error = store.storageError {
                Text(error).foregroundStyle(.red)
                Button("重试", action: store.load)
            } else if store.items.isEmpty {
                ContentUnavailableView("暂无赛程", systemImage: "calendar", description: Text("新增一场比赛，或导入 JSON 文件。"))
            } else {
                let items = Schedule.ordered(store.items)
                section("进行中", items.filter { !$0.isArchived && $0.startDate <= now && $0.endDate > now })
                section("未开始", items.filter { !$0.isArchived && $0.startDate > now })
                section("已结束", items.filter { !$0.isArchived && $0.endDate <= now })
                section("已归档", items.filter(\.isArchived))
            }
        }
        .task(id: store.items) {
            now = Date()
            for date in Set(store.items.flatMap { [$0.startDate, $0.endDate] }).sorted() {
                let delay = date.timeIntervalSinceNow
                if delay <= 0 { continue }
                do { try await Task.sleep(for: .seconds(min(delay, 86_400 * 365))) }
                catch { return }
                now = Date()
                while date > now {
                    do { try await Task.sleep(for: .seconds(min(date.timeIntervalSince(now), 86_400 * 365))) }
                    catch { return }
                    now = Date()
                }
            }
        }
        .onOpenURL { url in
            if url == Schedule.route {
                editor = nil
                pending = nil
                now = Date()
            }
        }
        .toolbar {
            Button("导入 JSON", systemImage: "square.and.arrow.down") { picking = true }
            Button("新增", systemImage: "plus") {
                var item = Competition()
                item.endDate = item.startDate.addingTimeInterval(3600)
                editor = item
            }.keyboardShortcut("n")
        }
        .sheet(item: $editor) { item in
            Editor(item: item) { edited in try store.save(Schedule.merged(store.items, with: [edited])) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pending = ImportPreview(items: try Schedule.decode(Data(contentsOf: url)))
            }
        }
        .sheet(item: $pending) { preview in
            let existing = Set(store.items.map(\.id))
            VStack(alignment: .leading, spacing: 12) {
                Text("预览导入").font(.headline)
                List(preview.items) { item in
                    LabeledContent(item.title, value: existing.contains(item.id) ? "更新" : "新增")
                }
                HStack {
                    Spacer()
                    Button("取消") { pending = nil }.keyboardShortcut(.cancelAction)
                    Button("导入 \(preview.items.count) 条") {
                        pending = nil
                        perform { _ = try store.importItems(preview.items) }
                    }.keyboardShortcut(.defaultAction).disabled(preview.items.isEmpty)
                }
            }.padding().frame(width: 460, height: 320)
        }
        .alert("删除赛事？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { item in
            Button("删除", role: .destructive) {
                perform { try store.save(store.items.filter { $0.id != item.id }) }
            }
            Button("取消", role: .cancel) {}
        } message: { item in Text(item.title) }
        .alert("操作失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private func section(_ title: String, _ items: [Competition]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text("\(item.startDate.formatted(date: .abbreviated, time: .shortened)) – \(item.endDate.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                            let details = [item.category, item.location, item.remarks].filter { !$0.isEmpty }
                            if !details.isEmpty { Text(details.joined(separator: " · ")).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("编辑") { editor = item }
                        Menu {
                            Button(item.isArchived ? "恢复" : "归档") {
                                var updated = item
                                updated.isArchived.toggle()
                                perform { try store.save(Schedule.merged(store.items, with: [updated])) }
                            }
                            Button("删除", role: .destructive) { deletion = item }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }.padding(.vertical, 5)
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { message = (error as? DecodingError).map { String(describing: $0) } ?? error.localizedDescription }
    }
}

private struct ImportPreview: Identifiable {
    let id = UUID()
    let items: [Competition]
}

private struct Editor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var item: Competition
    @ViewState private var error: String?
    let save: (Competition) throws -> Void

    var body: some View {
        Form {
            TextField("名称", text: $item.title)
            TextField("组别 / 赛道", text: $item.category)
            DatePicker("开始时间", selection: $item.startDate)
            DatePicker("截止时间", selection: $item.endDate)
            TextField("地点 / 形式", text: $item.location)
            TextField("备注 / 目标", text: $item.remarks, axis: .vertical)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(item); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
}

private struct OpenScheduleButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开赛程") { openWindow(id: "schedule") }
            .keyboardShortcut("l")
    }
}

private struct CountdownWindow: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @ViewState private var now = Date()

    var body: some View {
        let competition = Schedule.focus(store.items, at: now).first
        VStack(spacing: 0) {
            dragArea
            Button {
                openWindow(id: "schedule")
            } label: {
                CountdownFace(competition: competition, date: now,
                              emptyTitle: store.storageError == nil ? "暂无待完成赛程" : "无法读取赛程")
                    .padding(.horizontal, 28)
                    .frame(height: 170)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开完整赛程")
            dragArea
        }
        .frame(width: 390, height: 350)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .task(id: store.items) {
            now = Date()
            while let deadline = Schedule.focus(store.items, at: now).first?.endDate {
                let delay = max(0, deadline.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(min(delay, 86_400 * 365))) }
                catch { return }
                now = Date()
            }
        }
    }

    private var dragArea: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .accessibilityHidden(true)
    }
}
