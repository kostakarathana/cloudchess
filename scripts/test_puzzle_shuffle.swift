import Foundation
@main struct ShuffleTests {
 static func main() throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ value:Bool,_ reason:String) {precondition(value,reason);checks+=1}
    var coach=AdaptivePuzzleCoach()
    // Use real catalogue positions, including all modes' shared identity rules.
    for i in 0..<10000 {
        let kind=coach.selectChallengeKind(personalAvailable:i%17<8)
        check(kind != coach.previousChallengeKind,"No adjacent mode repeat with changing availability")
        let frozen=coach.recentPuzzleKeys
        var speculation=coach
        _ = speculation.selectChallengeKind(personalAvailable:true)
        check(coach.recentPuzzleKeys==frozen,"Speculation never changes committed history")
        var p=bank[i%bank.count];p.challengeType=kind.rawValue
        if !coach.allowsNextPuzzle(p) {p=bank[(i+10)%bank.count];p.challengeType=kind.rawValue}
        check(coach.allowsNextPuzzle(p),"Fresh puzzle accepted")
        let prior=coach.recentPuzzleKeys ?? []
        coach.begin(p)
        check(coach.recentPuzzleKeys?.count==min(3,prior.count+1),"History is bounded to three presentations")
        check(!coach.allowsNextPuzzle(p),"Current puzzle excluded")
        var alias=p;alias.id="alias-\(i)";alias.fen=p.fen.split(separator:" ").prefix(4).joined(separator:" ")+" 89 120"
        check(!coach.allowsNextPuzzle(alias),"Same position under new ID or move counters excluded")
        for keys in coach.recentPuzzleKeys! {check(!Set(keys).isDisjoint(with:coach.blockedPuzzleKeys),"All of the last three protected")}
        if i%100==0 {
            let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(coach))
            var a=coach,b=restored
            check(a.blockedPuzzleKeys==b.blockedPuzzleKeys,"Recent history survives relaunch")
            check(a.selectChallengeKind(personalAvailable:true)==b.selectChallengeKind(personalAvailable:true),"Deterministic continuation")
        }
    }
    // Exact boundary: three different puzzles must intervene before A returns.
    var c=AdaptivePuzzleCoach();let a=bank[0]
    c.begin(a)
    for i in 1...3 {
        check(!c.allowsNextPuzzle(a),"A blocked until three intervening puzzles")
        c.begin(bank[i])
    }
    check(c.allowsNextPuzzle(a),"A becomes eligible after three intervening puzzles")
    c=AdaptivePuzzleCoach();c.begin(a.variant(1))
    for symmetry in 0..<4 {check(!c.allowsNextPuzzle(a.variant(symmetry)),"Mirrored tactical puzzle is still the same puzzle")}
    c.session=nil
    check(c.selectChallengeKind(personalAvailable:true) != .tactics,"Clearing session for skip retains previous mode")
    c.total=3;c.reviews=[PuzzleReview(puzzle:a,due:0)]
    check(!c.eligibleReview(c.reviews[0]),"Due review cannot bypass cooldown")
    check(c.candidates(bank).allSatisfy{c.allowsNextPuzzle($0)},"Tactical candidate shortlist obeys hard exclusion")
    // Prepared assets with a new identity must still obey position cooldown.
    var candidate=a;candidate.id="new-cache-key"
    check(PreparedChallengeGate.revalidate(candidate,ability:c.challengeLevel(.tactics),age:0,coach:c,excluded:nil,instruction:nil,parent:candidate)==nil,"Cached aliases rejected at handoff")
    // Migrate the old save shape: no new optional field, history from seen IDs.
    var legacy=AdaptivePuzzleCoach();legacy.seen=[bank[0].variant(3).id,bank[1].variant(1).id,bank[2].variant(0).id]
    let data=try JSONEncoder().encode(legacy)
    legacy=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:data)
    for p in bank.prefix(3) {for v in 0..<4 {check(!legacy.allowsNextPuzzle(p.variant(v)),"Legacy variant IDs retain cooldown")}}
    legacy.begin(bank[3]);check(legacy.allowsNextPuzzle(bank[0]),"Migrated oldest item ages out")
    // Every mode's starting position is protected even if a generator changes IDs.
    for kind in ChallengeKind.allCases {
        var p=a;p.challengeType=kind.rawValue
        var learner=AdaptivePuzzleCoach();learner.begin(p)
        check(!PuzzleVariety.keys(id:p.id,fen:p.fen,columns:p.columns,rows:p.rows).isDisjoint(with:learner.blockedPuzzleKeys),"Generator exclusion keys cover every mode")
    }
    print("{\"status\":\"passed\",\"checks\":\(checks),\"presentations\":10000}")
 }
}
