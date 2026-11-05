import Foundation
// swiftc -parse-as-library CloudChess/PuzzleAllowance.swift scripts/test_ad_allowance.swift -o /tmp/ad-allowance && /tmp/ad-allowance
@main struct AdAllowanceTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { assertions += 1; precondition(condition(), message) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }

        // 1. Introduction: 8 puzzles AND 10 minutes before any break.
        var ledger = AdAllowance()
        for n in 0..<AdAllowance.introPuzzles { check(ledger.admit(session: "i\(n)", unlimited: false, at: at(Double(n))), "Intro puzzle \(n)") }
        check(!ledger.needsBreak(at: at(100)), "Ten minutes have not passed")
        check(ledger.admit(session: "i8", unlimited: false, at: at(100)), "Fast player keeps playing inside ten minutes")
        check(ledger.needsBreak(at: at(600)), "Break due after both gates")
        check(!ledger.admit(session: "blocked", unlimited: false, at: at(600)), "No new puzzle without a break")
        check(ledger.admit(session: "i8", unlimited: false, at: at(600)), "Admitted puzzle stays idempotent")
        check(ledger.admit(session: "paid", unlimited: true, at: at(600)), "Subscribers never need a break")
        var slow = AdAllowance()
        for n in 0..<3 { slow.admit(session: "s\(n)", unlimited: false, at: at(Double(n) * 400)) }
        check(!slow.needsBreak(at: at(1200)), "Ten minutes alone do not end the introduction")

        // 2. Offer sizing from pace, fixed until watched.
        check(AdAllowance.offer(recent: [30, 30, 30, 30, 30]) == .init(short: 8, long: 20), "Fast play: 8 / 20")
        check(AdAllowance.offer(recent: [60, 60, 60]) == .init(short: 4, long: 16), "Minute puzzles: 4 / 16")
        check(AdAllowance.offer(recent: [200, 300, 120]) == .init(short: 3, long: 15), "Slow play: 3 / 15")
        check(AdAllowance.offer(recent: []) == .init(short: 4, long: 16), "No history: a minute each")
        check(AdAllowance.offer(recent: [1, 1, 1, 9000, 9000, 9000, 1]).short == 3 && AdAllowance.offer(recent: [9000, 9000, 30, 30, 30, 30, 30]).short == 8, "Median of the last five")
        let shown = ledger.prepareOffer(recent: [30, 30, 30])
        check(ledger.prepareOffer(recent: [500, 500]) == shown, "A relaunch never rerolls the shown offer")
        let restored = try JSONDecoder().decode(AdAllowance.self, from: JSONEncoder().encode(ledger))
        check(restored.offer == shown, "Offer persists")

        // 3. Grants: exact batch once, then the four-minute gap and hourly cap.
        ledger.grant(.short, at: at(610))
        check(ledger.offer == nil && ledger.credits == shown.short, "Short batch granted once")
        for n in 0..<shown.short { check(ledger.admit(session: "g\(n)", unlimited: false, at: at(620 + Double(n))), "Granted puzzle \(n)") }
        check(ledger.credits == 0, "Batch used")
        check(!ledger.needsBreak(at: at(610 + 239)), "Inside the four-minute gap play stays free")
        check(ledger.admit(session: "gap", unlimited: false, at: at(610 + 239)), "Gap puzzle admitted")
        check(ledger.credits == 0, "A gap puzzle costs nothing")
        check(ledger.needsBreak(at: at(610 + 240)), "Break after the gap")
        _ = ledger.prepareOffer(recent: [60])
        ledger.grant(.long, at: at(900))
        check(ledger.credits == 16, "Long batch")
        // Clock rollback never refills or skips a break.
        var rollback = ledger
        for n in 0..<16 { rollback.admit(session: "r\(n)", unlimited: false, at: at(901)) }
        check(rollback.needsBreak(at: at(-50_000)) == rollback.needsBreak(at: at(901)) && rollback.needsBreak(at: at(901 + 240)), "Rollback uses the latest time seen")
        var capped = AdAllowance()
        for n in 0..<AdAllowance.introPuzzles { capped.admit(session: "c\(n)", unlimited: false, at: at(0)) }
        var t = 700.0, breaks = 0
        while breaks < 20 {
            if capped.needsBreak(at: at(t)) { _ = capped.prepareOffer(recent: [30]); capped.grant(.short, at: at(t)); breaks += 1 }
            let recent = capped.breaksInLastHour(at: at(t))
            check(recent <= AdAllowance.hourlyCap, "Hourly cap \(recent)")
            check(capped.admit(session: "p\(t)", unlimited: false, at: at(t)), "Admitted at \(t)")
            t += 5
        }
        // 4. Yearly saving: US 59.99 vs 12 × 7.99 = 37.4% → "Save 37%", never rounded up.
        check(PlanPricing.savingsPercent(monthly: Decimal(string: "7.99")!, annual: Decimal(string: "59.99")!) == 37, "US saving")
        check(PlanPricing.savingsPercent(monthly: 10, annual: 60) == 50, "Exact half")
        check(PlanPricing.savingsPercent(monthly: Decimal(string: "4.99")!, annual: Decimal(string: "59.88")!) == nil, "No saving, no badge")
        check(PlanPricing.savingsPercent(monthly: 0, annual: 50) == nil, "Missing monthly price")
        check(PlanPricing.savingsPercent(monthly: Decimal(string: "9.99")!, annual: Decimal(string: "59.99")!) == 49, "49.96% rounds down")
        // 5. Premium prompt: every 2–4 completed breaks, at most hourly, waits while
        //    ineligible, and each "not now" adds at most two breaks.
        for roll in 2...4 {
            var u = PremiumUpsell(); var shownAt: [Int] = []
            for n in 1...12 { if u.noteBreak(at: at(Double(n) * 4000), eligible: true, roll: { r in check(r == 2...4, "Interval 2–4"); return roll }) { shownAt.append(n) } }
            check(shownAt == Array(stride(from: roll, through: 12, by: roll)), "Every \(roll) breaks: \(shownAt)")
        }
        var hourly = PremiumUpsell(); var prompts = 0
        for n in 1...11 { if hourly.noteBreak(at: at(Double(n) * 300), eligible: true, roll: { _ in 2 }) { prompts += 1 } }
        check(prompts == 1, "Five-minute breaks: one prompt within the hour (\(prompts))")
        var waiting = PremiumUpsell()
        check(!waiting.noteBreak(at: at(0), eligible: true, roll: { _ in 2 }), "Not yet due")
        check(!waiting.noteBreak(at: at(4000), eligible: false, roll: { _ in 2 }), "Due but offline: waits")
        check(waiting.noteBreak(at: at(8000), eligible: true, roll: { _ in 2 }), "Shown at the next eligible break")
        var declining = PremiumUpsell()
        for _ in 0..<5 { declining.declined() }
        var gaps: [Int] = [], count = 0
        for n in 1...30 { count += 1; if declining.noteBreak(at: at(Double(n) * 4000), eligible: true, roll: { _ in 3 }) { gaps.append(count); count = 0 } }
        check(gaps.allSatisfy { $0 == 5 }, "Declines add at most two breaks: \(gaps)")
        let saved = try! JSONDecoder().decode(PremiumUpsell.self, from: JSONEncoder().encode(declining))
        check(saved == declining, "Prompt schedule persists")
        print("PASS: \(assertions) ad allowance assertions")
    }
}
