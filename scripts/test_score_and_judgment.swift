import Foundation
@main struct Checks {
 static func main() async throws {
    var checks=0
    func check(_ b:Bool,_ why:String){precondition(b,why);checks+=1}
    var counts:[String:Int]=[:]
    for i in 0..<90000 {let v=JudgmentVerdict.draw(i);counts[v.rawValue,default:0]+=1;check(v==JudgmentVerdict.draw(i),"Reproducible answer")}
    for n in counts.values {check(abs(n-30000)<600,"Uniform independent answer distribution")}
    for tenth in -2000...2000 {
        let cp=Double(tenth)/10,v=JudgmentVerdict.classify(cp)
        check(v==(cp>50 ? .white:(cp < -50 ? .black:.even)),"Exact 50cp classification boundary")
    }
    var targets:[[String:Any]]=[]
    for kind in ChallengeKind.allCases {
        for skill in stride(from:400.0,through:3000,by:100) {
            var c=AdaptivePuzzleCoach();c.ability.mean=skill
            var previous=0.0
            for score in [0.0,10000,25000,50000,100000,200000,500000,1000000,2000000,5000000,10000000,1000000000] {
                c.scoring=ChallengeScore(total:score,best:score)
                let target=c.targetRating(for:kind)
                check(target>=previous,"Score must never make selection easier at fixed skill/history")
                check((400...3000).contains(target),"Finite target")
                check(c.modeAbility(kind)==max(350,min(3000,skill)),"Score must not manufacture Elo evidence")
                previous=target
            }
        }
        var c=AdaptivePuzzleCoach();let initial=c.targetRating(for:kind)
        c.scoring=ChallengeScore(total:2000000,best:2000000)
        check(c.targetRating(for:kind)>initial+750,"Every mode materially responds to current score")
        let high=c.targetRating(for:kind);c.scoring?.total=0
        check(c.targetRating(for:kind)<high,"Losses can ease difficulty; lifetime high cannot trap the player")
        targets.append(["kind":kind.rawValue,"zeroScoreTarget":initial,"twoMillionTarget":high])
    }
    let rows=try await JudgmentLibrary.shared.load()
    var selection:[[String:Any]]=[]
    for label in JudgmentVerdict.allCases {
        let draw=(0..<100).first{JudgmentVerdict.draw($0)==label}!
        var lowRatings:[Double]=[],highRatings:[Double]=[],lowMargins:[Double]=[],highMargins:[Double]=[]
        for seed:UInt64 in 0..<100 {
            let low=try await JudgmentLibrary.shared.generate(rating:750,draw:draw,seed:seed,excluding:[])
            let high=try await JudgmentLibrary.shared.generate(rating:2800,draw:draw,seed:seed,excluding:[])
            check(low.judgment!.verdict==label && high.judgment!.verdict==label,"Class selection never falls back to a different answer")
            lowRatings.append(low.rating);highRatings.append(high.rating);lowMargins.append(abs(low.judgment!.whiteCP));highMargins.append(abs(high.judgment!.whiteCP))
        }
        func mean(_ a:[Double])->Double {a.reduce(0,+)/Double(a.count)}
        check(mean(highRatings)>mean(lowRatings)+400,"Each answer gets a genuinely harder position pool")
        if label != .even {check(mean(highMargins)<mean(lowMargins),"Hard winning judgments get closer to equality")}
        selection.append(["answer":label.rawValue,"lowRating":mean(lowRatings),"highRating":mean(highRatings),"lowAbsCP":mean(lowMargins),"highAbsCP":mean(highMargins)])
    }
    for row in rows {
        let state=try await NativeChess.call(["action":"state","initial":row.initial,"moves":row.history])
        check(state["fen"] as? String==row.fen,"Full legal history matches rendered board")
        check(state["capturedWhite"] as? [String]==row.capturedWhite && state["capturedBlack"] as? [String]==row.capturedBlack,"Captured arrays come from actual moves")
        check(JudgmentVerdict.classify(row.whiteCP)==row.verdict,"Strong certificate answer")
        check(JudgmentVerdict.classify(row.screenCP)==row.verdict,"Stable label across search depths")
    }
    check(CapturedMaterial.value(["P","N","B","R","Q"])==21,"Conventional material points")
    check(CapturedMaterial.value(["K"])==0,"Kings are never material points")
    for seed:UInt64 in 0..<10000 {
        check((2...3).contains(BlunderEngine.targetTurn(seed:seed)),"Injection timing is bounded")
        check(BlunderEngine.retained(51) && !BlunderEngine.retained(50),"Three-move advantage boundary")
    }
    let base=try await JudgmentLibrary.shared.generate(rating:1200,draw:0,seed:42,excluding:[])
    var coach=AdaptivePuzzleCoach();coach.begin(base)
    check(coach.judgmentDraws==1,"Only displayed questions consume a deterministic draw")
    let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(coach))
    check(restored.judgmentDraws==1 && restored.session?.puzzle.judgment?.id==base.judgment?.id,"Restart preserves answer class and certificate")
    var blunder=base;blunder.challengeType=ChallengeKind.blunderPunish.rawValue;blunder.blunderSeed=12
    var session=PuzzleSession(puzzle:blunder);session.moves=["e2e4","e7e5","g1f3","b8c6","f1b5","a7a6"];session.blunderPly=4;session.mistakes=2
    let reward=session.reward
    check(session.undoLastDecision() && session.moves.count==4 && session.blunderPly==4,"Rewind after injection retains its marker")
    check(abs(session.reward-reward*0.8)<0.001 && session.mistakes==2,"Undo discounts reward and preserves attempt evidence")
    check(session.undoLastDecision() && session.moves.count==2 && session.blunderPly==nil,"Rewind before injection restores the scheduled blunder")
    let saved=try JSONDecoder().decode(PuzzleSession.self,from:JSONEncoder().encode(session))
    check(saved.puzzle.blunderSeed==12 && saved.blunderPly==nil && saved.undoCount==2,"Blunder timing and undo state survive persistence")
    coach.scoring=ChallengeScore(total:1000000,best:1000000);coach.session?.mistakes=3;coach.session?.extraPenalty=1.75
    let cost=ChallengeScore.value(rating:base.rating,kind:.whosWinning)*2.5
    check(coach.finish(skipped:true),"Third failed judgment settles once")
    check(abs(coach.scoring!.total-max(0,1000000-cost))<0.01,"Failure charges prior two mistakes plus loss, never wipes banked points")
    check(!coach.finish(skipped:true),"Relaunch cannot double-charge a failed answer")
    let result:[String:Any]=["status":"passed","checks":checks,"drawCounts":counts,"scoreTargets":targets,"judgmentSelection":selection,"certifiedPositions":rows.count]
    print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
