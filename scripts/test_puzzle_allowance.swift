import Foundation
@main struct AllowanceTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { assertions += 1; precondition(condition(), message) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = PuzzleAllowance()
        for n in 0..<3 { check(ledger.admit(session:"s\(n)",unlimited:false,at:start.addingTimeInterval(Double(n)*10)),"Three initial slots") }
        check(!ledger.admit(session:"fourth",unlimited:false,at:start.addingTimeInterval(3599)),"Fourth blocked")
        check(ledger.admit(session:"s2",unlimited:false,at:start.addingTimeInterval(3599)),"Retry idempotent")
        check(ledger.remaining(at:start.addingTimeInterval(-7200))==0,"Clock rollback cannot refill")
        check(ledger.nextAvailable(at:start.addingTimeInterval(3599))==start.addingTimeInterval(3600),"Earliest refill")
        check(ledger.admit(session:"fourth",unlimited:false,at:start.addingTimeInterval(3600)),"Exact boundary refills")
        check(ledger.remaining(at:start.addingTimeInterval(3600))==0,"Rolling, not wall-hour quota")
        let encoded = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(PuzzleAllowance.self,from:encoded)
        check(restored.admit(session:"fourth",unlimited:false,at:start.addingTimeInterval(3601)),"Relaunch retry")
        check(!restored.admit(session:"fifth",unlimited:false,at:start.addingTimeInterval(3601)),"Relaunch preserves quota")
        for n in 0..<1000 { check(restored.admit(session:"paid\(n)",unlimited:true,at:start.addingTimeInterval(3601)),"Unlimited admission") }
        check(!restored.admit(session:"expired",unlimited:false,at:start.addingTimeInterval(3601)),"Expiry respects original free usage")
        // Independent rolling-window oracle, deterministic varied time jumps and paid state.
        var oracle:[(String,Date)]=[];var last:String?;var high=start;var state:UInt64=42
        ledger=PuzzleAllowance()
        for n in 0..<50000 {
            state=state &* 6364136223846793005 &+ 1
            let supplied=start.addingTimeInterval(Double(n)*2 + Double(Int(state%600)-300))
            high=max(high,supplied);oracle.removeAll{high.timeIntervalSince($0.1)>=3600}
            let paid=state%7==0;let id=n%11==0 ? (last ?? "initial") : "n\(n)"
            let duplicate=id==last || oracle.contains{$0.0==id}
            let expected=duplicate || paid || oracle.count<3
            let got=ledger.admit(session:id,unlimited:paid,at:supplied)
            check(got==expected,"Oracle admission \(n)")
            if expected && !duplicate { if !paid {oracle.append((id,high))};last=id }
            check(ledger.remaining(at:supplied)==max(0,3-oracle.count),"Oracle remaining \(n)")
            if n%137==0 {ledger=try JSONDecoder().decode(PuzzleAllowance.self,from:JSONEncoder().encode(ledger))}
        }
        print("PASS: \(assertions) allowance assertions")
    }
}
