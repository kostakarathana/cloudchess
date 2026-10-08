import Foundation

/// A rolling window. Session IDs make delivery retry/relaunch idempotent.
struct PuzzleAllowance: Codable {
    struct Entry: Codable { let session: String; let date: Date }
    static let limit = 3
    static let interval: TimeInterval = 3600
    private(set) var entries: [Entry] = []
    private(set) var lastSession: String?
    private(set) var latestDate: Date = .distantPast

    mutating func normalize(at date: Date) -> Date {
        let now = max(date, latestDate) // Moving the wall clock backwards never refills.
        latestDate = now
        entries.removeAll { now.timeIntervalSince($0.date) >= Self.interval }
        return now
    }
    func remaining(at date: Date) -> Int {
        max(0, Self.limit - entries.filter { max(date, latestDate).timeIntervalSince($0.date) < Self.interval }.count)
    }
    func nextAvailable(at date: Date) -> Date? {
        guard remaining(at: date) == 0 else { return nil }
        return entries.map(\.date).min()?.addingTimeInterval(Self.interval)
    }
    @discardableResult mutating func admit(session: String, unlimited: Bool, at date: Date) -> Bool {
        let now = normalize(at: date)
        if session == lastSession || entries.contains(where: { $0.session == session }) { return true }
        guard unlimited || remaining(at: now) > 0 else { return false }
        if !unlimited { entries.append(Entry(session: session, date: now)) }
        lastSession = session
        return true
    }
}
