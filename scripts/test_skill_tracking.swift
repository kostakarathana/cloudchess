import Foundation

/// Simulated learners of known strength play the real focused-puzzle coach.
/// Each picks the coach's first candidate, solves it with a logistic chance
/// against the item rating (adjusted for the frozen adaptive defender), and
/// the coach scores and learns as it does in the app. Checks:
///   - the level, selected rating and defender strength rise with true skill;
///   - after 40 puzzles the level sits closer to true skill than the old fixed
///     25% skill weighting would put it, across the catalogue's range;
///   - a struggling player's level falls rather than drifting up with score.
/// Usage: skill-tracking <puzzles.json>
@main struct SkillTrackingTests {
    static var checks=0
    static func check(_ ok:Bool,_ message:@autoclosure()->String) {
        checks+=1
        if !ok {FileHandle.standardError.write(("FAIL: "+message()+"\n").data(using:.utf8)!);exit(1)}
    }
    struct Run {var levels:[Double]=[],ratings:[Double]=[],strengths:[Double]=[],old:[Double]=[];var final:AdaptivePuzzleCoach}
    static func play(_ bank:[TrainingPuzzle],skill:Double,seed:UInt64,count:Int=40)->Run {
        var coach=AdaptivePuzzleCoach();coach.sequence=seed
        var rng=SplitMix(seed:seed &* 7919 &+ 17);var run=Run(final:coach)
        for _ in 0..<count {
            guard let p=coach.candidates(bank).first else{break}
            coach.begin(p);coach.session?.requiresAdmission=false
            let strength=coach.session!.defenseStrength
            let effective=p.rating-PuzzleDefense.ratingShift(strength:strength)
            let chance=1/(1+exp(-(skill-effective)/240))
            let u=rng.unit()
            coach.session?.elapsed=p.seconds
            if u<chance {coach.finish()}
            else if u<chance+(1-chance)*0.45 {coach.session?.mistakes=1;coach.finish()}
            else {coach.session?.mistakes=3;coach.session?.extraPenalty=1.75;coach.finish(skipped:true)}
            coach.session=nil
            let score=coach.currentScore,progression=850+300*log2(1+score/100000)
            run.levels.append(coach.challengeLevel(.tactics));run.ratings.append(p.rating);run.strengths.append(strength)
            run.old.append(min(3000,max(400,0.75*progression+0.25*coach.modeAbility(.tactics))))
        }
        run.final=coach;return run
    }
    struct SplitMix {var seed:UInt64
        mutating func unit()->Double {seed &+= 0x9e3779b97f4a7c15;var z=seed;z=(z^(z>>30)) &* 0xbf58476d1ce4e5b9;z=(z^(z>>27)) &* 0x94d049bb133111eb;return Double((z^(z>>31))>>11)/9007199254740992}
    }
    static func mean(_ v:ArraySlice<Double>)->Double {v.reduce(0,+)/Double(max(1,v.count))}
    static func main() throws {
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        // Strength mapping is monotone, bounded and full strength for older sessions.
        check(PuzzleDefense.strength(opponent:nil)==1,"Sessions without an opponent keep the full defense")
        var last = -1.0
        for elo in stride(from:400.0,through:3000,by:50) {let s=PuzzleDefense.strength(opponent:elo);check(s>=last && s>=0 && s<=1,"Strength rises with the opponent");last=s}
        check(PuzzleDefense.strength(opponent:800)==0 && PuzzleDefense.strength(opponent:2000)==1,"Forgiving at 800, full strength from 2000")
        check(PuzzleDefense.seed(session:"a",ply:3)==PuzzleDefense.seed(session:"a",ply:3) && PuzzleDefense.seed(session:"a",ply:3) != PuzzleDefense.seed(session:"a",ply:4),"Seeds are stable per session and ply")
        // Skill weight earns evidence, monotone in score at fixed ability.
        var c=AdaptivePuzzleCoach();check(abs(c.skillWeight-0.25)<1e-9,"A new player is weighted like before")
        c.ability.evidence=20;check(abs(c.skillWeight-0.425)<1e-9,"Twenty updates move skill weight to 42.5%")
        c.ability.evidence=100000;check(c.skillWeight<0.6 && c.skillWeight>0.599,"Skill weight approaches 60%")
        var previous=0.0
        for score in [0.0,1e5,1e6,1e7] {c.scoring=ChallengeScore(total:score,best:score);let l=c.challengeLevel(.tactics);check(l>previous,"Level still rises with score");previous=l}
        // Review slots: two consecutive totals in every eight.
        for t in 0..<32 {c.total=t;check(c.reviewSlot==(t%8>=6),"Review slot schedule")}
        var summary:[String:Any]=[:]
        var finals:[(skill:Double,level:Double,rating:Double,strength:Double,newError:Double,oldError:Double)]=[]
        for skill in [800.0,1300,1800,2300] {
            var level=0.0,rating=0.0,strength=0.0,newError=0.0,oldError=0.0;let seeds:[UInt64]=[1,2,3,4,5]
            for seed in seeds {
                let run=play(bank,skill:skill,seed:seed)
                level+=mean(run.levels.suffix(10));rating+=mean(run.ratings.suffix(10));strength+=mean(run.strengths.suffix(10))
                newError+=abs(mean(run.levels.suffix(10))-skill);oldError+=abs(mean(run.old.suffix(10))-skill)
            }
            let n=Double(seeds.count)
            finals.append((skill,level/n,rating/n,strength/n,newError/n,oldError/n))
            summary["\(Int(skill))"]=["level":Int(level/n),"selectedRating":Int(rating/n),"defense":(strength/n*100).rounded()/100,"levelError":Int(newError/n),"oldWeightingError":Int(oldError/n)]
        }
        for (a,b) in zip(finals,finals.dropFirst()) {
            check(b.level>a.level+100,"Level rises with true skill: \(a.skill)→\(b.skill) \(a.level)→\(b.level)")
            check(b.rating>a.rating+60,"Selected puzzles get harder with true skill: \(a.rating)→\(b.rating)")
            check(b.strength>=a.strength,"The defender strengthens with true skill: \(a.strength)→\(b.strength)")
        }
        // Inside the catalogue's range the skill-weighted level tracks better. Above
        // it (2300) puzzles stop at the strata ceilings, so evidence saturates;
        // there selection must simply stay at the top with a full-strength defense.
        for f in finals where f.skill<=1800 {check(f.newError<f.oldError,"Skill weighting tracks \(f.skill) better than the fixed 25%: \(f.newError) vs \(f.oldError)")}
        check(finals.last!.rating>=1850 && finals.last!.strength>=0.9,"A player above the catalogue gets its hardest puzzles and a full defense")
        check(finals.first!.strength<finals.last!.strength-0.3,"Weak players meet a clearly gentler defender")
        // A player who suddenly struggles eases off instead of drifting upward.
        var strong=play(bank,skill:2000,seed:9).final
        let peak=strong.challengeLevel(.tactics)
        for _ in 0..<12 {
            guard let p=strong.candidates(bank).first else{break}
            strong.begin(p);strong.session?.requiresAdmission=false;strong.session?.mistakes=3;strong.session?.extraPenalty=1.75;strong.finish(skipped:true);strong.session=nil
        }
        check(strong.challengeLevel(.tactics)<peak-150,"Twelve failures lower the level: \(peak)→\(strong.challengeLevel(.tactics))")
        summary["struggle"]=["peak":Int(peak),"afterTwelveFailures":Int(strong.challengeLevel(.tactics))]
        let data=try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"after40Puzzles":summary],options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
