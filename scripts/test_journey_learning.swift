import Foundation
@main struct Tests {
 static func main() async throws {
    var checks=0
    func check(_ b:Bool,_ why:String) {precondition(b,why);checks+=1}
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:"CloudChess/EngineResources/puzzles.json")))
    for p in bank.prefix(250) {
        for kind in ChallengeKind.allCases {
            var puzzle=p;puzzle.challengeType=kind.rawValue
            var s=PuzzleSession(puzzle:puzzle),score=ChallengeScore(total:100000,best:100000)
            let base=s.reward
            // Saves written before the feature preserve the original reward.
            let legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(s)) as! [String:Any]
            check(legacy["hintDiscounts"]==nil,"Absent optional fields remain compatible")
            s=try JSONDecoder().decode(PuzzleSession.self,from:JSONSerialization.data(withJSONObject:legacy))
            for stage in 1...3 {
                check(s.nextHintStage==stage,"Hint progression bound to decision")
                s.revealHint()
                check(abs(s.reward-base*pow(0.9,Double(stage)))<0.00001,"Compounding visible reward discount")
                check(s.moves.isEmpty && s.mistakes==0,"Assistance never becomes a move or a mistake")
                check(ChallengeScore.penalty(s)==0,"No banked point penalty")
            }
            s.revealHint();check(s.hintDiscounts==3 && s.hints==3,"Repeated step cannot charge twice")
            s.moves=["a1a2","a4a3"];check(s.nextHintStage==1,"New history has fresh hint steps")
            s.revealHint();check(s.hintDiscounts==4,"Discounts aggregate across decisions")
            check(s.undoLastDecision(),"Undo available")
            check(abs(s.reward-base*pow(0.9,4)*0.8)<0.00001,"Undo and hint discounts remain independent")
            let restored=try JSONDecoder().decode(PuzzleSession.self,from:JSONEncoder().encode(s))
            check(restored.hintDiscounts==4 && restored.reward==s.reward,"Persistence preserves cumulative discounts")
            score.settle(s,success:true);let settled=score.total
            score.settle(s,success:true);check(score.total==settled,"Replaying a solved puzzle cannot regrant its reward")
            check(abs(settled-(100000+s.reward))<0.00001,"Only discounted success reward is awarded")
        }
    }
    // Frame generation for demonstration uses legal state transitions only, even
    // on rectangular boards, castling/en-passant lines and black orientation.
    var positions=0
    for p in bank.prefix(300) {
        var history:[String]=[]
        for move in p.line.prefix(6) {
            let before=try await NativeChess.call(p.request(moves:history))
            check((before["legal"] as? [String] ?? []).contains(move),"Replay line is legal in native rules")
            history.append(move)
            let after=try await NativeChess.call(p.request(moves:history))
            check((after["moves"] as? [String])==history,"State-only replay preserves exact history")
            positions+=1
        }
    }
    for (fen,moves) in [
        ("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",["e1g1","e8c8"]),
        ("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",["e5d6"]),
        ("k7/4P3/8/8/8/8/8/4K3 w - - 0 1",["e7e8n"])
    ] {
        var history:[String]=[]
        for move in moves {
            let before=try await NativeChess.call(["action":"state","initial":fen,"moves":history])
            check((before["legal"] as? [String] ?? []).contains(move),"Special move replay legality")
            history.append(move)
            let after=try await NativeChess.call(["action":"state","initial":fen,"moves":history])
            check(after["fen"] as? String != before["fen"] as? String,"Special move reaches a new valid frame")
            positions+=1
        }
    }
    let json:[String:Any]=["status":"passed","checks":checks,"nativeReplayPositions":positions,"sessions":min(250,bank.count)*ChallengeKind.allCases.count]
    print(String(data:try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
