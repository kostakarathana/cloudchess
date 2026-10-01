import Foundation
@main struct Tests {
    static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) {checks+=1;precondition(condition,message)}
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var report:[[String:Any]]=[]
        for kind in ChallengeKind.allCases {
            var easy=AdaptivePuzzleCoach(),strong=AdaptivePuzzleCoach()
            var samples:[[Double]]=[]
            for trueLevel in [600.0,2400.0] {
                var coach=AdaptivePuzzleCoach();var levels:[Double]=[]
                for trial in 0..<300 {
                    var p=bank[trial%bank.count];p.challengeType=kind.rawValue;p.rating=coach.targetRating(for:kind);p.id="\(kind)-\(trueLevel)-\(trial)";p.tags=["shared",kind.rawValue];p.uncertainty=350
                    if !kind.usesHearts {p.calibrationOpponent=coach.opponentRating(for:kind)}
                    coach.begin(p)
                    let chance=AdaptivePuzzleCoach.sigmoid((trueLevel-p.rating)/240)
                    let roll=Double((trial*7919+1777)%10000)/10000
                    let success=roll<chance
                    coach.session?.elapsed=success ? 35:80
                    if !success {coach.session?.extraPenalty=2;if kind.usesHearts{coach.session?.mistakes=3}}
                    let score=coach.liveTestScore
                    check(coach.finish(skipped:!success),"Each fresh result is recorded")
                    let saved=coach
                    check(!coach.finish(skipped:!success),"Duplicate result cannot move ability twice")
                    check(coach.ability.mean==saved.ability.mean,"No duplicate update")
                    check(coach.ability.mean.isFinite && (350...3000).contains(coach.ability.mean),"Finite bounded global rating")
                    check((400...3000).contains(coach.targetRating(for:kind)),"Bounded target in every mode")
                    check((100...3000).contains(coach.opponentRating(for:kind)),"Legal opponent strength")
                    check(coach.scoring!.total>=0 && coach.scoring!.best>=score,"Score floor and lifetime record")
                    let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(coach))
                    check(restored.modeAbility(kind)==coach.modeAbility(kind),"Mode learning survives relaunch")
                    check(restored.opponentRating(for:kind)==coach.opponentRating(for:kind),"Opponent planning survives relaunch")
                    if trial>=240 {levels.append(coach.targetRating(for:kind))}
                }
                samples.append(levels)
                if trueLevel==600 {easy=coach}else{strong=coach}
            }
            let low=samples[0].reduce(0,+)/60,high=samples[1].reduce(0,+)/60
            check(high>low+900,"Every mode separates weak and strong performance")
            check(strong.opponentRating(for:kind)>easy.opponentRating(for:kind)+800,"Bots rise and fall with demonstrated skill")
            report.append(["kind":kind.rawValue,"weakTarget":low,"strongTarget":high,"weakBot":easy.opponentRating(for:kind),"strongBot":strong.opponentRating(for:kind)])
            // Successful long games with a slip must not be scored as a loss.
            if !kind.usesHearts {
                var c=AdaptivePuzzleCoach(),p=bank[0];p.challengeType=kind.rawValue;p.rating=1600
                c.begin(p);c.session?.mistakes=1;c.session?.moves=Array(repeating:"a1a2",count:20);c.session?.elapsed=180
                let before=c.modeAbility(kind);c.finish();check(c.modeAbility(kind)>before,"A won open game with a slip increases mastery")
                let high=c.opponentRating(for:kind)
                for _ in 0..<5 {c.begin(p);c.session?.extraPenalty=2;c.finish(skipped:true)}
                check(c.opponentRating(for:kind)<high-120,"Repeated game losses lower the next bot")
            }
        }
        var shared=AdaptivePuzzleCoach(),hard=bank[0];hard.rating=2300
        let initial=shared.opponentRating(for:.tenMoves)
        for _ in 0..<12 {shared.begin(hard);shared.session?.elapsed=10;shared.finish()}
        check(shared.opponentRating(for:.tenMoves)>initial+300,"Hard tactical wins transfer to stronger sparring")
        var legacy=shared;legacy.adaptationVersion=nil
        for i in legacy.attempts.indices {legacy.attempts[i].kind=nil}
        let original=legacy.scoring!.total;legacy.migrateDifficulty()
        check(legacy.scoring!.total==original,"Migration preserves banked points")
        check(legacy.attempts.allSatisfy{$0.kind != nil},"Legacy mode evidence migrates")
        let data=try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"simulatedAttempts":ChallengeKind.allCases.count*600,"modes":report],options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
    }
}
private extension AdaptivePuzzleCoach {var liveTestScore:Double {scoring?.best ?? 0}}
