import Foundation

/// Free play is supported by rewarded ads instead of a hard paywall. A new
/// player gets an ad-free introduction; after that, each ad break grants a
/// batch of puzzles sized so breaks stay roughly four minutes apart. Session
/// IDs make delivery retry/relaunch idempotent; the wall clock never refills
/// anything by moving backwards.
struct AdAllowance: Codable {
    static let introPuzzles = 8, introSeconds: TimeInterval = 600
    /// Minimum time between ad breaks; an exhausted batch inside it plays free.
    static let minimumGap: TimeInterval = 240
    static let hourlyCap = 8
    /// Puzzles per short break: about four minutes of play at the recent pace.
    static let shortRange = 3...8
    /// The longer break is a disclosed bundle of rewarded ads (networks cap a
    /// single rewarded ad at roughly 30 s and require it to be dismissible).
    static let longRange = 15...20, longAds = 3
    static let targetSeconds: TimeInterval = 240
    static let sessionMemory = 64

    struct Offer: Codable, Equatable { var short: Int; var long: Int }
    enum Break: String, Codable { case short, long }

    private(set) var started: Date?
    private(set) var delivered = 0
    private(set) var credits = 0
    private(set) var sessions: [String] = []
    private(set) var breaks: [Date] = []
    private(set) var latestDate: Date = .distantPast
    /// Rolled once when a break is first offered and kept until one is watched,
    /// so a relaunch never rerolls the batch sizes the player was shown.
    private(set) var offer: Offer?

    private mutating func normalize(_ date: Date) -> Date {
        let now = max(date, latestDate)
        latestDate = now
        breaks.removeAll { now.timeIntervalSince($0) >= 3600 }
        return now
    }
    func introducing(at date: Date) -> Bool {
        let now = max(date, latestDate)
        return delivered < Self.introPuzzles || now.timeIntervalSince(started ?? now) < Self.introSeconds
    }
    /// True when the next new puzzle needs an ad break first.
    func needsBreak(at date: Date) -> Bool {
        let now = max(date, latestDate)
        if introducing(at: now) || credits > 0 { return false }
        if let last = breaks.last, now.timeIntervalSince(last) < Self.minimumGap { return false }
        return breaksInLastHour(at: now) < Self.hourlyCap
    }
    func admitted(_ session: String) -> Bool { sessions.contains(session) }
    func breaksInLastHour(at date: Date) -> Int { let now = max(date, latestDate); return breaks.filter { now.timeIntervalSince($0) < 3600 }.count }
    @discardableResult mutating func admit(session: String, unlimited: Bool, at date: Date) -> Bool {
        let now = normalize(date)
        if sessions.contains(session) { return true }
        if !unlimited {
            if started == nil { started = now }
            if needsBreak(at: now) { return false }
            if !introducing(at: now) && credits > 0 { credits -= 1 }
            delivered += 1
        }
        sessions.append(session)
        if sessions.count > Self.sessionMemory { sessions.removeFirst(sessions.count - Self.sessionMemory) }
        return true
    }
    /// `recent` holds the latest puzzle durations in seconds (solve time plus transition).
    mutating func prepareOffer(recent: [Double]) -> Offer {
        if let offer { return offer }
        let made = Self.offer(recent: recent)
        offer = made
        return made
    }
    static func offer(recent: [Double]) -> Offer {
        let sorted = recent.filter { $0.isFinite && $0 > 0 }.suffix(5).sorted()
        let median = sorted.isEmpty ? 60 : sorted[sorted.count / 2]
        let short = min(shortRange.upperBound, max(shortRange.lowerBound, Int((targetSeconds / max(10, median)).rounded())))
        // Faster play earns the larger end of the long batch too.
        let long = longRange.lowerBound + (short - shortRange.lowerBound) * (longRange.upperBound - longRange.lowerBound) / (shortRange.upperBound - shortRange.lowerBound)
        return Offer(short: short, long: long)
    }
    /// Called only after every ad in the break was watched (or the network had
    /// no fill while online): grants the offered batch exactly once.
    mutating func grant(_ kind: Break, at date: Date) {
        let now = normalize(date)
        let shown = offer ?? Self.offer(recent: [])
        credits += kind == .short ? shown.short : shown.long
        breaks.append(now)
        offer = nil
    }
}

/// Advertised yearly saving against twelve monthly payments, rounded down so
/// the yearly plan is never described as cheaper than it is.
enum PlanPricing {
    static func savingsPercent(monthly: Decimal, annual: Decimal) -> Int? {
        guard monthly > 0, annual > 0 else { return nil }
        let saving = 1 - NSDecimalNumber(decimal: annual).doubleValue / NSDecimalNumber(decimal: monthly * 12).doubleValue
        let percent = Int((saving * 100 + 1e-9).rounded(.down))
        return percent > 0 ? percent : nil
    }
}
