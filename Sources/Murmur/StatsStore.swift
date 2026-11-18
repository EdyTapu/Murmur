import Foundation
import os

struct DayStats: Codable, Equatable {
    var words = 0
    var dictations = 0
    /// Words and speaking time of dictations whose length is known; the pair gives words per minute.
    var timedWords = 0
    var seconds = 0.0
    /// Words Murmur learned from the user's own corrections.
    var fixes = 0
    var apps: [String: Int] = [:]
}

/// Per-day usage totals. Kept apart from history so insights survive the
/// history cap and the "delete after 24 hours" / "never store" settings.
@MainActor
final class StatsStore: ObservableObject {
    private let log = Logger(subsystem: "com.alessio.murmur", category: "stats")
    @Published private(set) var days: [String: DayStats] = [:]
    private let fileURL: URL

    /// `backfill` seeds the totals from existing history the first time.
    init(directory: URL = AppSupport.directory, backfill: [HistoryEntry] = []) {
        fileURL = directory.appendingPathComponent("stats.json")
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data) {
            days = decoded
        } else if !backfill.isEmpty {
            for entry in backfill {
                add(words: Self.wordCount(entry.finalText), seconds: entry.duration, app: entry.appName, on: entry.date)
            }
            save()
        }
    }

    func record(text: String, seconds: Double?, app: String?) {
        add(words: Self.wordCount(text), seconds: seconds, app: app, on: Date())
        save()
    }

    func recordFixes(_ count: Int) {
        days[Self.key(Date()), default: DayStats()].fixes += count
        save()
    }

    private func add(words: Int, seconds: Double?, app: String?, on date: Date) {
        var day = days[Self.key(date), default: DayStats()]
        day.words += words
        day.dictations += 1
        if let seconds, seconds > 0 {
            day.timedWords += words
            day.seconds += seconds
        }
        if let app { day.apps[app, default: 0] += words }
        days[Self.key(date)] = day
    }

    private func save() {
        do {
            try JSONEncoder().encode(days).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Insights

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }
    var wordsLearned: Int { days.values.reduce(0) { $0 + $1.fixes } }

    /// Speaking speed over every dictation with a known length; nil until one exists.
    var wordsPerMinute: Int? {
        let seconds = days.values.reduce(0) { $0 + $1.seconds }
        guard seconds >= 10 else { return nil }
        return Int((Double(days.values.reduce(0) { $0 + $1.timedWords }) / seconds * 60).rounded())
    }

    func wordsThisWeek(now: Date = Date()) -> Int {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return lastDays(7, now: now).filter { week.contains($0.date) }.reduce(0) { $0 + $1.words }
    }

    /// Consecutive days with a dictation. A quiet today does not break yesterday's streak.
    func dayStreak(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: now)
        if days[Self.key(day)] == nil { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var streak = 0
        while days[Self.key(day)] != nil, let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            streak += 1
            day = previous
        }
        return streak
    }

    /// Oldest first, ending today.
    func lastDays(_ count: Int, now: Date = Date()) -> [(date: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { ($0, days[Self.key($0)]?.words ?? 0) }
        }
    }

    var topApps: [(name: String, words: Int)] {
        var totals: [String: Int] = [:]
        for day in days.values {
            for (app, words) in day.apps { totals[app, default: 0] += words }
        }
        return totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map { ($0.key, $0.value) }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
