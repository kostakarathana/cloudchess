import Foundation
@main struct GateChecks {
 static func main()throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ b:Bool){precondition(b);checks+=1}
    for original in bank.prefix(2000) {
        var c=AdaptivePuzzleCoach();c.ability.mean=original.rating
        // Focused mode: the prepared gate requires the frozen shape/family draw.
        c.focusedSelection=FocusedPuzzleSelection(columns:original.columns,rows:original.rows,mate:original.mate>0)
        let ability=c.challengeLevel(.tactics)
        func valid(_ coach:AdaptivePuzzleCoach,_ age:Double=10,_ excluded:String?=nil,_ instruction:String?=nil)->TrainingPuzzle? {
            PreparedChallengeGate.revalidate(original,ability:ability,age:age,coach:coach,excluded:excluded,instruction:instruction,parent:original)
        }
        check(valid(c) != nil)
        check(valid(c,601)==nil);check(valid(c,-1)==nil)
        check(valid(c,10,original.id)==nil);check(valid(c,10,nil,"mate")==nil)
        c.seen=[original.id];check(valid(c)==nil);c.seen=[]
        c.reviews=[PuzzleReview(puzzle:original,due:0)]
        // Review slots are totals 6 and 7 modulo 8, so both alternating families get one.
        for slot in [6,7,14] {c.total=slot;check(c.reviewSlot);check((valid(c)==nil)==c.eligibleReview(c.reviews[0]))}
        for idle in [0,1,2,3,4,5] {c.total=idle;check(!c.reviewSlot);check(valid(c) != nil)}
        c.reviews=[];c.total=0
        // A failed presentation retires the source: mirrors are rejected for good.
        var cooled=c;cooled.begin(original);cooled.session?.mistakes=3;cooled.finish(skipped:true,now:0)
        cooled.session=nil;cooled.recentPuzzleKeys=[];cooled.focusedSelection=c.focusedSelection
        check(PreparedChallengeGate.revalidate(original.variant(1),ability:ability,age:10,coach:cooled,excluded:nil,instruction:nil,parent:original)==nil)
        cooled.total+=1000;cooled.reviews=[]
        check(PreparedChallengeGate.revalidate(original.variant(1),ability:cooled.challengeLevel(.tactics),age:10,coach:cooled,excluded:nil,instruction:nil,parent:original)==nil)
        cooled.retiredPuzzleKeys=[]
        check(PreparedChallengeGate.revalidate(original.variant(1),ability:cooled.challengeLevel(.tactics),age:10,coach:cooled,excluded:nil,instruction:nil,parent:original) != nil)
        let savedAbility=c.ability.mean;c.scoring=ChallengeScore(total:100000000,best:100000000);check(valid(c)==nil);c.scoring=nil;c.ability.mean=savedAbility
        for n in 4...8 {for h in 4...8 {
            c.preferredColumns=n;c.preferredRows=h
            check((valid(c) != nil)==(n==original.columns && h==original.rows))
        }}
    }
    print("{\"status\":\"passed\",\"checks\":\(checks)}")
 }
}
