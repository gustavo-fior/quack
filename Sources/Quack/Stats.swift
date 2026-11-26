import Foundation

/// Counts of key presses per day. Only totals are stored, never which keys.
final class Stats: ObservableObject {
    @Published private(set) var days: [String: Int]
    @Published private(set) var total: Int

    private let defaults = UserDefaults.standard
    private var dirty = false
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        days = (defaults.dictionary(forKey: "stats.days") as? [String: Int]) ?? [:]
        total = defaults.integer(forKey: "stats.total")
    }

    static func key(for date: Date) -> String { formatter.string(from: date) }

    var today: Int { days[Self.key(for: Date())] ?? 0 }
    var bestDay: Int { days.values.max() ?? 0 }
    var activeDays: Int { days.values.filter { $0 > 0 }.count }

    /// Consecutive days with typing, ending today or yesterday.
    var streak: Int {
        let calendar = Calendar.current
        var day = Date()
        if (days[Self.key(for: day)] ?? 0) == 0 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var count = 0
        while (days[Self.key(for: day)] ?? 0) > 0 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    func recent(_ count: Int) -> [(date: Date, keys: Int)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: start)!
            return (date, days[Self.key(for: date)] ?? 0)
        }
    }

    func add(_ count: Int) {
        guard count > 0 else { return }
        days[Self.key(for: Date()), default: 0] += count
        total += count
        dirty = true
    }

    func save() {
        guard dirty else { return }
        dirty = false
        defaults.set(days, forKey: "stats.days")
        defaults.set(total, forKey: "stats.total")
    }

    func reset() {
        days = [:]
        total = 0
        dirty = true
        save()
    }
}
