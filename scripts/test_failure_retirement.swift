import Foundation
/// A failed, lost or skipped tactical puzzle is never repeated: not as a review,
/// a reflection or a composition of its source. Its tags carry the weakness.
@main struct FailureRetirementTests {
 static func main() throws {
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var checks=0
    func check(_ value:Bool,_ reason:String) {precondition(value,reason);checks+=1}
    let wall=Date().timeIntervalSince1970
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
    func succeed(_ c:inout AdaptivePuzzleCoach,_ p:TrainingPuzzle,mistakes:Int=0) {c.begin(p);c.session?.mistakes=mistakes;c.session?.elapsed=30;check(c.finish(now:wall),"Recorded success")}
    func fail(_ c:inout AdaptivePuzzleCoach,_ p:TrainingPuzzle) {
        c.begin(p);c.session?.mistakes=3;c.session?.extraPenalty=1.75;c.session?.elapsed=20
        check(c.finish(skipped:true,now:wall),"Recorded failure")
    }

    // 1. Third lost heart: skills learn the weakness; the puzzle never returns.
    var c=calibrated(x.rating)
    let before=x.tags.map{c.tagAbility($0).mean}
    fail(&c,x)
    check(c.retiredPuzzleKeys==["tactical-source:"+x.source],"One retirement key per source")
    check(c.reviews.allSatisfy{$0.puzzle.source != x.source},"No review is scheduled for a failure")
    check(c.failureCooldowns?.isEmpty ?? true,"Retirement replaces the timed cooldown")
    check(zip(before,x.tags.map{c.tagAbility($0).mean}).allSatisfy{$1<$0},"Every tag of the failed puzzle is marked weaker")
    for p in others.prefix(200) {succeed(&c,p)}
    check(c.recencyPuzzleKeys.isDisjoint(with:x.repeatKeys),"Long past the last-three window")
    for v in 0..<4 {check(!c.allowsNextPuzzle(x.variant(v),now:wall+1e9),"Reflection \(v) never returns")}
    check(!c.allowsNextPuzzle(composition(x),now:wall+1e9),"Composition never returns")
    var ranking=c
    for _ in 0..<12 {
        ranking.focusedSelection=plan
        let picks=ranking.candidates(bank)
        check(!picks.isEmpty && picks.allSatisfy{$0.source != x.source},"Shortlist excludes the retired source")
    }
    ranking.focusedSelection=plan
    check(PreparedChallengeGate.revalidate(x.variant(1),ability:ranking.challengeLevel(.tactics),age:0,coach:ranking,excluded:nil,instruction:nil,parent:x)==nil,"Prepared mirror rejected")
    // A later clean success of some other source never un-retires it.
    succeed(&c,others[0])
    check(c.retired(x),"Retirement is permanent")

    // 2. Explicit skips retire too; assisted successes still return as reviews.
    var skipper=calibrated(x.rating);skipper.begin(x);skipper.finish(skipped:true,now:wall)
    check(skipper.retired(x) && skipper.reviews.isEmpty,"Explicit skip retires without review")
    var assisted=calibrated(x.rating);succeed(&assisted,x,mistakes:1)
    check(!assisted.retired(x) && assisted.reviews.contains{$0.puzzle.id==x.id},"A success with a lost heart is reviewed later")
    var mode=calibrated(x.rating);var open=x;open.challengeType=ChallengeKind.finish.rawValue;mode.begin(open);mode.finish(skipped:true,now:wall)
    check(mode.retiredPuzzleKeys?.isEmpty ?? true,"Open-play losses retire nothing")

    // 3. Older saves: cooldowns and failure reviews migrate to retirement once.
    var legacy=calibrated(x.rating)
    legacy.failureCooldowns=[PuzzleCooldown(keys:x.repeatKeys.sorted(),source:x.source,until:legacy.total+12,notBefore:wall,failures:1)]
    let y=others[3];legacy.begin(y);legacy.session?.mistakes=3;legacy.finish(skipped:true,now:wall)
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
    object.removeValue(forKey:"retiredPuzzleKeys")
    object["reviews"]=[try JSONSerialization.jsonObject(with:JSONEncoder().encode(PuzzleReview(puzzle:y,due:0)))]
    object["failureCooldowns"]=[try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy.failureCooldowns![0]))]
    var migrated=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONSerialization.data(withJSONObject:object))
    check(migrated.retiredPuzzleKeys==nil,"Legacy snapshot decodes without the field")
    migrated.migrateDifficulty()
    check(migrated.retired(x) && migrated.retired(y),"Cooled and failed-review sources retire")
    check(migrated.reviews.isEmpty && migrated.failureCooldowns==nil,"Failure reviews and cooldowns are removed")
    let total=migrated.total;migrated.migrateDifficulty()
    check(migrated.total==total && migrated.retiredPuzzleKeys?.count==2,"Migration runs once")
    let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(migrated))
    check(restored.retiredPuzzleKeys==migrated.retiredPuzzleKeys,"Retirement survives relaunch")

    // 4. Starvation guard: a fully retired 32-source stratum still serves, retired last.
    for plan in [plan,FocusedPuzzleSelection(columns:4,rows:7,mate:false)] {
        let stratum=bank.filter{plan.matches($0)}
        var sources:[String:TrainingPuzzle]=[:];for p in stratum where sources[p.source]==nil {sources[p.source]=p}
        let ordered=sources.values.sorted{$0.id<$1.id}
        var starved=calibrated(x.rating);starved.focusedSelection=plan
        starved.retiredPuzzleKeys=Set(ordered.map{"tactical-source:"+$0.source})
        let picks=starved.candidates(bank)
        check(!picks.isEmpty && picks.allSatisfy{plan.matches($0)} && starved.focusedSelection==plan,"Starvation guard keeps the frozen draw servable")
        check(picks.allSatisfy{starved.recencyPuzzleKeys.isDisjoint(with:$0.repeatKeys)},"Relaxation never touches recency")
        var eight=calibrated(x.rating);eight.focusedSelection=plan
        eight.retiredPuzzleKeys=Set(ordered.dropFirst(8).map{"tactical-source:"+$0.source})
        let kept=Set(ordered.prefix(8).map{$0.source})
        check(eight.candidates(bank).allSatisfy{kept.contains($0.source)},"Eight unretired sources need no relaxation")
        var seven=calibrated(x.rating);seven.focusedSelection=plan
        seven.retiredPuzzleKeys=Set(ordered.dropFirst(7).map{"tactical-source:"+$0.source})
        let ranked=seven.candidates(bank);let fresh=Set(ordered.prefix(7).map{$0.source})
        let freshCount=ranked.filter{fresh.contains($0.source)}.count
        check(ranked.count>7 && freshCount>0 && ranked.prefix(freshCount).allSatisfy{fresh.contains($0.source)},"Unretired sources rank before retired ones")
    }

    // 5. Material balance for improve-in-x (P1 N3 B3 R5 Q9, either side).
    check(MaterialBalance.of("8/8/r7/3k4/8/PK6/2N5/8 w - - 0 1",white:true) == -1,"White: pawn+knight vs rook")
    check(MaterialBalance.of("8/8/r7/3k4/8/PK6/2N5/8 w - - 0 1",white:false) == 1,"Black's view is the negation")
    check(MaterialBalance.of("8/8/N7/2k5/8/PK6/8/8 b - - 0 1",white:true) == 4,"Rook won")

    // 6. Off-track bookkeeping: undo past the deviation clears it; a free rewind keeps prior turns.
    var session=PuzzleSession(puzzle:x);session.moves=["a1a2","b1b2","c1c2","d1d2"];session.offTrack=2
    var rewound=session;rewound.rewindMissedTurn()
    check(rewound.moves.count==2 && rewound.offTrack==nil && rewound.undoCount==nil && rewound.hints==0,"Free rewind after a lost heart")
    var kept=session;kept.offTrack=0;kept.rewindMissedTurn()
    check(kept.offTrack==0,"Earlier deviation survives a rewind")
    var undone=session;check(undone.undoLastDecision() && undone.offTrack==nil && undone.undoCount==1,"Undo past the deviation clears it and is charged")
    // 7. Undo tips: the first three proven-unsolvable misses, then one every 2–3.
    var tips=calibrated(x.rating);var shownAt:[Int]=[]
    for event in 1...40 {if tips.noteUnsolvableMiss() {shownAt.append(event)}}
    check(Array(shownAt.prefix(3))==[1,2,3],"First three always show")
    let gaps=zip(shownAt.dropFirst(2),shownAt.dropFirst(3)).map{$1-$0}
    check(!gaps.isEmpty && gaps.allSatisfy{$0==2 || $0==3},"Then every 2–3 events: \(gaps)")
    check(tips.undoTips?.events==40 && tips.undoTips?.shown==shownAt.count,"Counts persist")
    let saved=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(tips))
    check(saved.undoTips==tips.undoTips,"Schedule survives relaunch")
    print("{\"status\":\"passed\",\"checks\":\(checks),\"source\":\"\(x.source)\"}")
 }
}
