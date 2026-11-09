import SwiftUI
import WidgetKit

private struct Entry: TimelineEntry {
    let date: Date
    var focus: [Competition] = []
    var failed = false
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        var item = Competition()
        item.title = "数学建模竞赛"
        item.category = "本科组"
        item.remarks = "完成论文与附件提交"
        item.endDate = item.startDate.addingTimeInterval(86_400)
        var next = item
        next.id = UUID()
        next.title = "程序设计竞赛"
        next.startDate = item.endDate
        return Entry(date: .now, focus: [item, next])
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries().entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(entries())
    }

    private func entries() -> Timeline<Entry> {
        let now = Date()
        do {
            let items = try Schedule.read(from: Schedule.fileURL())
            let eligible = items.filter { !$0.isArchived && $0.endDate > now }
            var dates: Set<Date> = [now]
            dates.formUnion(eligible.map(\.endDate))
            let orderedDates = dates.sorted()
            let entries = orderedDates.prefix(64).map { Entry(date: $0, focus: Schedule.focus(eligible, at: $0)) }
            let policy: TimelineReloadPolicy
            if orderedDates.count > entries.count {
                policy = .after(orderedDates[entries.count])
            } else {
                policy = .never
            }
            return Timeline(entries: entries, policy: policy)
        } catch {
            return Timeline(entries: [Entry(date: now, failed: true)], policy: .after(now.addingTimeInterval(3600)))
        }
    }
}

private struct BoardView: View {
    let entry: Entry

    var body: some View {
        CountdownFace(competition: entry.focus.first, date: entry.date,
                      emptyTitle: entry.failed ? "无法读取赛程" : "暂无待完成赛程")
            .containerBackground(.ultraThinMaterial, for: .widget)
            .widgetURL(Schedule.route)
    }
}

@main
struct GoalTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Schedule.kind, provider: Provider()) { BoardView(entry: $0) }
            .configurationDisplayName("GoalTracker 赛程")
            .description("显示最近截止的赛事和实时倒计时。")
            .supportedFamilies([.systemLarge])
    }
}
