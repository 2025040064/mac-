import Foundation
import SwiftUI

struct Competition: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var category = ""
    var startDate = Date()
    var endDate = Date()
    var location = ""
    var remarks = ""
    var isArchived = false

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try fields.decode(String.self, forKey: .title)
        startDate = try fields.decode(Date.self, forKey: .startDate)
        endDate = try fields.decode(Date.self, forKey: .endDate)
        category = try fields.decodeIfPresent(String.self, forKey: .category) ?? ""
        location = try fields.decodeIfPresent(String.self, forKey: .location) ?? ""
        remarks = try fields.decodeIfPresent(String.self, forKey: .remarks) ?? ""
        isArchived = try fields.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Schedule {
    static let kind = "GoalTrackerBoard"
    static let route = URL(string: "goaltracker://open-all-competitions")!

    static func decode(_ data: Data) throws -> [Competition] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let field = try decoder.singleValueContainer()
            let string = try field.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: field, debugDescription: "需要带时区的 ISO 8601 日期")
        }
        let items = try decoder.decode([Competition].self, from: data)
        try validate(items)
        return items
    }

    static func validate(_ items: [Competition]) throws {
        var ids = Set<UUID>()
        for (index, item) in items.enumerated() {
            guard ids.insert(item.id).inserted else { throw Problem("第 \(index + 1) 条的 ID 重复。") }
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Problem("第 \(index + 1) 条的名称不能为空。")
            }
            guard item.endDate >= item.startDate else { throw Problem("第 \(index + 1) 条的截止时间早于开始时间。") }
        }
    }

    static func merged(_ existing: [Competition], with incoming: [Competition]) -> [Competition] {
        let updates = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let existingIDs = Set(existing.map(\.id))
        return existing.map { updates[$0.id] ?? $0 } + incoming.filter { !existingIDs.contains($0.id) }
    }

    static func ordered(_ items: [Competition]) -> [Competition] {
        items.sorted { ($0.endDate, $0.startDate, $0.id.uuidString) < ($1.endDate, $1.startDate, $1.id.uuidString) }
    }

    static func focus(_ items: [Competition], at date: Date) -> [Competition] {
        Array(ordered(items.filter { !$0.isArchived && $0.endDate > date }).prefix(2))
    }

    static func fileURL() throws -> URL {
        #if STANDALONE
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("GoalTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("competitions.json")
        #else
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GoalTrackerAppGroup") as? String,
              !group.isEmpty, !group.hasPrefix("."),
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw Problem("无法访问共享存储。请检查两个目标的签名和 App Group。")
        }
        return directory.appendingPathComponent("competitions.json")
        #endif
    }

    static func read(from url: URL) throws -> [Competition] {
        do { return try decode(Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    static func write(_ items: [Competition], to url: URL) throws {
        try validate(items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var field = encoder.singleValueContainer()
            try field.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: url, options: .atomic)
    }
}

struct CountdownFace: View {
    let competition: Competition?
    let date: Date
    var emptyTitle = "暂无待完成赛程"

    var body: some View {
        VStack(spacing: 18) {
            Text(competition?.title ?? emptyTitle)
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            if let competition, competition.endDate > date {
                Text(timerInterval: date...competition.endDate, countsDown: true, showsHours: true)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel("距截止时间")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
