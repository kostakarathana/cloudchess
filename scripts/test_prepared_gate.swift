import Foundation
@main struct GateChecks {
 static func main()throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ b:Bool){precondition(b);checks+=1}
    for original in bank.prefix(2000) {
        var c=AdaptivePuzzleCoach();c.ability.mean=original.rating
        let ability=c.challengeLevel(.tactics)
        func valid(_ coach:AdaptivePuzzleCoach,_ age:Double=10,_ excluded:String?=nil,_ instruction:String?=nil)->TrainingPuzzle? {
            PreparedChallengeGate.revalidate(original,ability:ability,age:age,coach:coach,excluded:excluded,instruction:instruction,parent:original)
        }
        check(valid(c) != nil)
        check(valid(c,601)==nil);check(valid(c,-1)==nil)
        check(valid(c,10,original.id)==nil);check(valid(c,10,nil,"mate")==nil)
        c.seen=[original.id];check(valid(c)==nil);c.seen=[]
        c.total=3;c.reviews=[PuzzleReview(puzzle:original,due:0)]
        check((valid(c)==nil)==c.eligibleReview(c.reviews[0]))
        c.total=2;check(valid(c) != nil)
        c.reviews=[];c.total=0
        let savedAbility=c.ability.mean;c.scoring=ChallengeScore(total:100000000,best:100000000);check(valid(c)==nil);c.scoring=nil;c.ability.mean=savedAbility
        for n in 4...8 {for h in 4...8 {
            c.preferredColumns=n;c.preferredRows=h
            check((valid(c) != nil)==(n==original.columns && h==original.rows))
        }}
    }
    print("{\"status\":\"passed\",\"checks\":\(checks)}")
 }
}
