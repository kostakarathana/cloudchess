import Foundation
/// Failed, lost and skipped tactical puzzles rest behind a growing completion
/// AND wall-clock cooldown that covers every reflection and composition.
@main struct FailureCooldownTests {
 static func main() throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ value:Bool,_ reason:String) {precondition(value,reason);checks+=1}
    let wall=Date().timeIntervalSince1970,past=wall-100_000
    // Progression level equal to the item rating keeps reviews inside the 0.25–0.95 band.
    func calibrated(_ rating:Double)->AdaptivePuzzleCoach {
        var c=AdaptivePuzzleCoach();c.ability.mean=rating;c.ability.variance=40000
        c.scoring=ChallengeScore(total:max(0,10*(pow(2,(rating-850)/300)-1)),best:0);return c
    }
    func composition(_ p:TrainingPuzzle)->TrainingPuzzle {
        for seed in UInt64(1)...4000 {if let q=p.composition(seed:seed) {return q}}
        preconditionFailure("No composition for \(p.id)")
    }
    let x=bank.first{$0.mate>0 && $0.columns==6 && $0.rows==6 && $0.rating>1150 && $0.rating<1500 && $0.difficultyVersion=="challenge-v2"}!
    let plan=FocusedPuzzleSelection(columns:x.columns,rows:x.rows,mate:true)
    let others=bank.filter{$0.source != x.source && $0.difficultyVersion=="challenge-v2" && abs($0.rating-x.rating)<200 && $0.columns==x.columns && $0.rows==x.rows}
    check(others.count>=12,"Enough neighbours in the bank")
    func succeed(_ c:inout AdaptivePuzzleCoach,_ p:TrainingPuzzle,now:Double) {c.begin(p);c.session?.elapsed=30;check(c.finish(now:now),"Recorded success")}
    func fail(_ c:inout AdaptivePuzzleCoach,_ p:TrainingPuzzle,now:Double) {
        c.begin(p);c.session?.mistakes=3;c.session?.extraPenalty=1.75;c.session?.elapsed=20
        check(c.finish(skipped:true,now:now),"Recorded failure")
    }

    // 1. Third mistake: both gates must open before any reflection/composition returns.
    var c=calibrated(x.rating)
    let settledAt=c.total
    fail(&c,x,now:past)
    let first=c.failureCooldowns!.first{$0.source==x.source}!
    check(first.until==settledAt+1+12 && first.notBefore==past+15*60 && first.failures==1,"First failure: 12 completions and 15 minutes")
    check(c.reviews.last!.puzzle.id==x.id && c.reviews.last!.due==first.until && first.until>=settledAt+7,"Review deadline never precedes the cooldown")
    check(!c.eligibleReview(c.reviews.last!),"Review ineligible while cooling")
    for p in others.prefix(3) {succeed(&c,p,now:past)}
    check(c.recencyPuzzleKeys.isDisjoint(with:x.repeatKeys),"Last-three exclusion has released the failed puzzle")
    let composed=composition(x)
    for v in 0..<4 {check(!c.allowsNextPuzzle(x.variant(v),now:wall),"Reflection \(v) blocked by the completion gate")}
    check(!c.allowsNextPuzzle(composed,now:wall),"Composition blocked by the completion gate")
    check(!c.allowsNextPuzzle(x),"Default clock also blocks")
    check(!c.eligibleReview(c.reviews.last!),"Review stays ineligible while cooling")
    var opened=c;opened.total=first.until
    check(!opened.allowsNextPuzzle(x,now:past+899),"Completion gate alone does not release")
    for v in 0..<4 {check(opened.allowsNextPuzzle(x.variant(v),now:past+900),"Reflection \(v) returns once both gates open")}
    check(opened.allowsNextPuzzle(composed,now:past+900),"Composition returns once both gates open")
    var timeOnly=c;check(!timeOnly.allowsNextPuzzle(x,now:past+100_000),"Time gate alone does not release");timeOnly.total=0
    check(opened.eligibleReview(opened.reviews.last!),"Review becomes eligible when the cooldown ends")

    // 2. Candidate shortlists and the prepared gate never return the cooled source.
    var ranking=c;ranking.focusedSelection=plan
    for _ in 0..<12 {
        ranking.focusedSelection=plan
        let picks=ranking.candidates(bank)
        check(!picks.isEmpty && picks.allSatisfy{$0.source != x.source},"Shortlist excludes the cooled source")
    }
    ranking.focusedSelection=plan
    check(PreparedChallengeGate.revalidate(x.variant(1),ability:ranking.challengeLevel(.tactics),age:0,coach:ranking,excluded:nil,instruction:nil,parent:x)==nil,"Prepared mirror rejected while cooling")
    var released=ranking;released.total=(first.until...first.until+3).first{$0%4<2}!;released.reviews=[]
    check(!released.reviewSlot,"Chosen total is not a review slot")
    check(PreparedChallengeGate.revalidate(x.variant(1),ability:released.challengeLevel(.tactics),age:0,coach:released,excluded:nil,instruction:nil,parent:x) != nil,"Prepared mirror accepted after the cooldown")
    // A fresh failure keeps blocking shortlists by wall clock even after enough completions.
    var clock=calibrated(x.rating);fail(&clock,x,now:wall)
    for p in others.prefix(3) {succeed(&clock,p,now:wall)}
    clock.total=clock.failureCooldowns!.first!.until
    check(!clock.allowsNextPuzzle(x),"Wall-clock gate holds after enough completions")
    clock.focusedSelection=plan
    check(clock.candidates(bank).allSatisfy{$0.source != x.source},"Shortlist honours the wall-clock gate")

    // 3. Repeated failure doubles both gates; a clean success clears the entry.
    var again=opened
    let secondAt=again.total
    fail(&again,x,now:past+5000)
    let second=again.failureCooldowns!.first{$0.source==x.source}!
    check(again.failureCooldowns!.filter{$0.source==x.source}.count==1,"One entry per source")
    check(second.until==secondAt+1+24 && second.notBefore==past+5000+30*60 && second.failures==2,"Second failure: 24 completions and 30 minutes")
    var third=again;third.total=second.until;fail(&third,x.variant(2),now:past+9000)
    let thirdEntry=third.failureCooldowns!.first{$0.source==x.source}!
    check(thirdEntry.until==second.until+1+48 && thirdEntry.notBefore==past+9000+3600 && thirdEntry.failures==3,"Mirrored failure grows the same source: 48 completions and 1 hour")
    var capped=third
    for i in 0..<4 {capped.total=capped.failureCooldowns!.first{$0.source==x.source}!.until;fail(&capped,x,now:past+20_000+Double(i))}
    let cap=capped.failureCooldowns!.first{$0.source==x.source}!
    check(cap.until-capped.total==96 && cap.notBefore-(past+20_003)==4*3600,"Caps: 96 completions and 4 hours")
    var cleared=again;cleared.total=second.until
    succeed(&cleared,x,now:past+100_000)
    check(!cleared.failureCooldowns!.contains{$0.source==x.source},"Clean success clears the cooldown")
    check(cleared.reviews.allSatisfy{$0.puzzle.id != x.id},"Clean success retires the review")
    var assisted=again;assisted.total=second.until;assisted.begin(x);assisted.session?.mistakes=1;assisted.session?.elapsed=30;assisted.finish(now:past+100_000)
    check(assisted.failureCooldowns!.contains{$0.source==x.source && $0.failures==2},"A success with a mistake keeps the growth")
    // Explicit skip and loss also cool down; a non-tactical finish never does.
    var skipper=calibrated(x.rating);skipper.begin(x);skipper.finish(skipped:true,now:past)
    check(skipper.failureCooldowns?.count==1,"Explicit skip records a cooldown")
    var mode=calibrated(x.rating);var open=x;open.challengeType=ChallengeKind.finish.rawValue;mode.begin(open);mode.finish(skipped:true,now:past)
    check(mode.failureCooldowns?.isEmpty==true,"Open-play loss records no cooldown")
    // Bounded list.
    var many=calibrated(x.rating)
    for p in bank.filter({$0.difficultyVersion=="challenge-v2"}).prefix(80) {fail(&many,p,now:wall)}
    check(many.failureCooldowns!.count==PuzzleCooldown.limit,"Cooldown list bounded to \(PuzzleCooldown.limit)")

    // 4. A snapshot without the new field decodes and behaves as before.
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as! [String:Any]
    check(object["failureCooldowns"] != nil,"Field persisted")
    object.removeValue(forKey:"failureCooldowns")
    var legacy=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONSerialization.data(withJSONObject:object))
    check(legacy.failureCooldowns==nil && legacy.total==c.total,"Legacy snapshot decodes")
    check(legacy.allowsNextPuzzle(x) && legacy.blockedPuzzleKeys==legacy.recencyPuzzleKeys,"Legacy save uses the last-three exclusion only")
    legacy.focusedSelection=plan
    check(!legacy.candidates(bank).isEmpty,"Legacy ranking works")
    fail(&legacy,others[5],now:wall)
    check(legacy.failureCooldowns?.count==1,"Legacy save starts recording cooldowns")
    let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(c))
    check(restored.failureCooldowns==c.failureCooldowns && restored.blockedPuzzleKeys(now:wall)==c.blockedPuzzleKeys(now:wall),"Cooldowns survive relaunch")

    // 5. Starvation guard: cooling every source of the drawn stratum still serves it.
    for plan in [plan,FocusedPuzzleSelection(columns:4,rows:7,mate:false)] {
        let stratum=bank.filter{plan.matches($0)}
        var sources:[String:TrainingPuzzle]=[:];for p in stratum where sources[p.source]==nil {sources[p.source]=p}
        func cooled(_ items:[TrainingPuzzle])->[PuzzleCooldown] {items.map{PuzzleCooldown(keys:$0.repeatKeys.sorted(),source:$0.source,until:10_000,notBefore:wall+10_000,failures:1)}}
        var starved=calibrated(x.rating);starved.focusedSelection=plan;starved.failureCooldowns=cooled(Array(sources.values))
        let picks=starved.candidates(bank)
        check(!picks.isEmpty && picks.allSatisfy{plan.matches($0)} && starved.focusedSelection==plan,"Starvation guard keeps the frozen draw servable")
        check(picks.allSatisfy{starved.recencyPuzzleKeys.isDisjoint(with:$0.repeatKeys)},"Relaxation never touches recency")
        starved.begin(picks[0]);starved.focusedSelection=plan;starved.session=nil
        check(starved.candidates(bank).allSatisfy{starved.allowsNextPuzzle($0,now:wall) || starved.recencyPuzzleKeys.isDisjoint(with:$0.repeatKeys)},"Last three stay excluded under relaxation")
        let ordered=sources.values.sorted{$0.id<$1.id}
        var eight=calibrated(x.rating);eight.focusedSelection=plan;eight.failureCooldowns=cooled(Array(ordered.dropFirst(8)))
        let kept=Set(ordered.prefix(8).map{$0.source})
        check(eight.candidates(bank).allSatisfy{kept.contains($0.source)},"Eight remaining sources need no relaxation")
        var seven=calibrated(x.rating);seven.focusedSelection=plan;seven.failureCooldowns=cooled(Array(ordered.dropFirst(7)))
        check(seven.candidates(bank).count>7,"Fewer than eight sources relaxes cooldowns")
    }

    // 6. Review-slot parity: every settling parity gets its exact review served.
    for parity in 0..<4 {
        // Hold the score-driven progression still so the slot mechanics, not point growth, decide.
        var p=calibrated(x.rating);p.preferredColumns=x.columns;p.preferredRows=x.rows
        let frozen=p.scoring!.total
        var pool=others.makeIterator()
        while p.total%4 != parity {succeed(&p,pool.next()!,now:past);p.scoring?.total=frozen}
        p.focusedSelection=plan;fail(&p,x,now:past);p.scoring?.total=frozen
        let entry=p.failureCooldowns!.first{$0.source==x.source}!
        var served:Int?
        for presentation in 1...(entry.until-p.total+8) {
            let pick=p.candidates(bank)[0]
            if pick.id==x.id {served=presentation;break}
            check(pick.source != x.source,"No reflection/composition of the failed source before the review")
            check(p.total<entry.until || !p.reviewSlot || !p.eligibleReview(p.reviews.first{$0.puzzle.id==x.id}!),"Eligible review on a slot is served first")
            succeed(&p,pick,now:past);p.scoring?.total=frozen
        }
        check(served != nil && p.total>=entry.until,"Parity \(parity): exact review served after the cooldown (\(served ?? -1))")
        check(p.reviewSlot,"Served on a review slot")
    }
    for t in 0..<12 {var s=AdaptivePuzzleCoach();s.total=t;check(s.reviewSlot==(t%4>=2),"Review slots are totals 2 and 3 modulo 4")}
    print("{\"status\":\"passed\",\"checks\":\(checks),\"source\":\"\(x.source)\"}")
 }
}
