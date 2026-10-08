import Foundation
@main struct FocusedTests {
 static func main() throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ b:Bool,_ why:String){precondition(b,why);checks+=1}
    var counts=[String:Int](),c=AdaptivePuzzleCoach()
    // Test draws independently of bank abundance, skill, rewards, and reviews.
    for i in 0..<100000 {
        c.prepareFocusedSelection();let pick=c.focusedSelection!
        counts["\(pick.columns)x\(pick.rows)",default:0]+=1
        check((4...8).contains(pick.columns) && (4...8).contains(pick.rows),"Legal shape")
        check(c.selectChallengeKind(personalAvailable:true) == .tactics,"Disabled modes cannot enter mix")
        if let last=c.previousFocusedMate {check(pick.mate != last,"Families alternate")}
        if i%1000==0 {
            var restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(c))
            restored.prepareFocusedSelection();check(restored.focusedSelection==pick,"Retry and relaunch freeze the draw")
        }
        c.previousFocusedMate=pick.mate;c.focusedSelection=nil
    }
    check(counts.count==25,"All shapes present")
    for count in counts.values {check(abs(count-4000)<300,"Uniform 25-way sampling within statistical bound")}
    // Real candidate selection, every shape/family, low through high ability.
    for level in [400.0,1100,2000,3000] {for x in 4...8 {for y in 4...8 {for mate in [false,true] {
        var c=AdaptivePuzzleCoach();c.ability.mean=level
        let plan=FocusedPuzzleSelection(columns:x,rows:y,mate:mate);c.focusedSelection=plan
        c.total=3;c.reviews=bank.prefix(40).map{PuzzleReview(puzzle:$0,due:0)}
        let candidates=c.candidates(bank)
        check(!candidates.isEmpty,"No empty shape/family at any ability")
        check(candidates.allSatisfy{plan.matches($0)},"Ranking/reviews stay in selected stratum")
        let p=candidates[0];c.begin(p)
        check(c.focusedSelection==nil,"Successful presentation consumes the draw")
        check(!c.allowsNextPuzzle(p),"Repeat excluded")
        c.session=nil;c.focusedSelection=plan
        let next=c.candidates(bank);check(!next.isEmpty,"Recency doesn't starve a shape")
        check(next.allSatisfy{c.allowsNextPuzzle($0)},"Position/source recency maintained")
        if let other=bank.first(where:{!plan.matches($0)}) {
            check(PreparedChallengeGate.revalidate(other,ability:c.challengeLevel(.tactics),age:0,coach:c,excluded:nil,instruction:nil,parent:other)==nil,"Prepared buffer cannot override draw")
        }
    }}}}
    for kind in ChallengeKind.allCases where kind != .tactics {
        var c=AdaptivePuzzleCoach();var p=bank[0];p.challengeType=kind.rawValue
        c.begin(p);c.session?.moves=["a1a2"];c.scoring=ChallengeScore(total:12345,best:54321)
        var collection=CollectionProgress();collection.pending=RewardBoard(seed:42);collection.selectedBoard=3;c.collection=collection
        c.activateFocusedPuzzles();check(c.session==nil,"Unsupported session suspended")
        check(c.suspendedModeSession?.puzzle.kind==kind && c.suspendedModeSession?.moves==["a1a2"],"Resume state archived")
        check(c.scoring?.total==12345 && c.scoring?.best==54321,"No penalty for disabled mode")
        c.activateFocusedPuzzles();check(c.suspendedModeSession != nil,"Idempotent migration")
        let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(c))
        check(restored.collection?.pending?.seed==collection.pending?.seed,"Pending rewards preserved")
        check(restored.collection?.selectedBoard==3,"Ownership/equipment preserved")
    }
    // Legacy tactical sessions also carry their family across a no-penalty return.
    var legacy=AdaptivePuzzleCoach();legacy.session=PuzzleSession(puzzle:bank.first{$0.mate>0}!)
    legacy.activateFocusedPuzzles();legacy.session=nil;legacy.prepareFocusedSelection()
    check(legacy.focusedSelection?.mate==false,"Legacy return cannot repeat checkmate family")
    print("Passed \(checks) checks; 100000 draws, 25 shapes, both families, 4 skill levels. Counts: \(counts)")
 }
}
