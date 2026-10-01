import Foundation
@main struct TurnLatencyRegression {
 static func main() async throws {
    let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    var checks=0,records:[[String:Any]]=[]
    for (history,move) in [([],"d2d4"),(["e2e4"],"c7c5"),(["e2e4","e7e5","g1f3","b8c6"],"f1c4")] {
        let (_,best)=try await ChallengeEngine.evaluate(initial:initial,moves:history,multipv:history.isEmpty ? 3:1)
        let coldStart=Date()
        let decision=try await TurnAnalysis.assess(.opening,initial:initial,history:history,move:move,baseline:best)
        let cold=Date().timeIntervalSince(coldStart)
        precondition(!decision.rejected);checks+=1
        let after=try await NativeChess.call(["action":"state","initial":initial,"moves":history+[move]])
        let legal=after["legal"] as! [String]
        let reply=TurnAnalysis.reply(move:move,assessment:decision.played,legal:legal)!
        let finalHistory=history+[move,reply]
        let successor=try await ChallengeEngine.evaluate(initial:initial,moves:finalHistory).1
        precondition(!successor.line.isEmpty);checks+=1
        // These were additional serial searches in the old drop path.
        let oldStart=Date()
        let oldBest=try await ChallengeEngine.evaluate(initial:initial,moves:history+[move]).1
        if let other=legal.first(where:{$0 != oldBest.line.first}) {
            _ = try await ChallengeEngine.evaluate(initial:initial,moves:history+[move],root:other)
        }
        let redundant=Date().timeIntervalSince(oldStart)
        let warmStart=Date()
        for _ in 0..<1000 {
            let warm=try await TurnAnalysis.assess(.opening,initial:initial,history:history,move:move,baseline:best)
            precondition(warm.rejected==decision.rejected && warm.played.cp==decision.played.cp)
            precondition(TurnAnalysis.reply(move:move,assessment:warm.played,legal:legal)==reply)
            precondition(ChallengeEngine.cached(initial:initial,moves:finalHistory)?.cp==successor.cp)
            checks+=3
        }
        let warmMean=Date().timeIntervalSince(warmStart)/1000
        precondition(warmMean<0.01);checks+=1
        precondition(TurnAnalysis.reply(move:"a1a8",assessment:decision.played,legal:legal)==nil)
        precondition(TurnAnalysis.reply(move:move,assessment:decision.played,legal:[])==nil);checks+=2
        records.append(["history":history,"move":move,"reply":reply,"coldGradingSeconds":cold,"warmGradingMeanSeconds":warmMean,"removedReplySearchSeconds":redundant])
    }
    // Fool's mate must still receive the full 8M/8M rejection recheck.
    let history=["f2f3","e7e5"]
    let baseline=try await ChallengeEngine.evaluate(initial:initial,moves:history).1
    let bad=try await TurnAnalysis.assess(.opening,initial:initial,history:history,move:"g2g4",baseline:baseline)
    precondition(bad.rejected && bad.deepRecheck && bad.played.mate != nil);checks+=3
    for _ in 0..<1000 {
        let roots=TurnAnalysis.candidates(best:"e2e4",book:["d2d4":99,"g1f3":50,"e2e4":10,"invalid":999],legal:["d2d4","e2e4","g1f3"])
        precondition(roots==["e2e4","d2d4","g1f3"]);checks+=1
    }
    // Import analysis must wait while playing, then yield if play resumes.
    NativeChess.setGameplayActive(true)
    let profile=Task {try await NativeChess.profileCall(["action":"analyse","initial":initial,"moves":["b1c3"],"nodes":8000000,"multipv":3])}
    try await Task.sleep(nanoseconds:50_000_000)
    let state=try await NativeChess.call(["action":"state","initial":initial,"moves":[]])
    precondition((state["legal"] as! [String]).count==20);checks+=1
    NativeChess.setGameplayActive(false)
    try await Task.sleep(nanoseconds:300_000_000)
    let yieldStart=Date();NativeChess.setGameplayActive(true)
    _ = try await NativeChess.call(["action":"analyse","initial":initial,"moves":["h2h3"],"nodes":10000,"multipv":1])
    let yieldTime=Date().timeIntervalSince(yieldStart)
    precondition(yieldTime<1);checks+=1
    profile.cancel();do {_ = try await profile.value;preconditionFailure("Cancelled profile returned evidence")}catch{checks+=1}
    NativeChess.setGameplayActive(false)
    let report:[String:Any]=["status":"passed","checks":checks,"openings":records,"profileYieldSeconds":yieldTime,"scope":"Development Mac. Full 2M grading and 8M rejection budgets; timing excludes UI animation."]
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
