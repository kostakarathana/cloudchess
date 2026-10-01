import Foundation
@main struct HandoffBenchmark {
 static func main() async throws {
    let fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    _ = try await NativeChess.call(["action":"analyse","initial":fen,"moves":[],"nodes":10000,"multipv":1])
    var records:[[String:Any]]=[]
    for (history,root) in [(["e2e4","e7e5"],"g1f3"),(["d2d4","d7d5"],"c2c4"),(["g1f3","g8f6"],"d2d4")] {
        let request=ChallengeEngine.request(initial:fen,moves:history,root:root)
        let epoch=CCBackgroundEpoch(),start=Date()
        let ponder=Task {try await NativeChess.$backgroundEpoch.withValue(epoch){try await NativeChess.call(request)}}
        try await Task.sleep(for:.seconds(0.9))
        ponder.cancel()
        #if HANDOFF_BASELINE
        NativeChess.cancelPreparation()
        #else
        NativeChess.cancelPreparation {r in (r["moves"] as? [String])==history && r["root"] as? String==root}
        #endif
        let drop=Date(),result=try await NativeChess.call(request)
        let elapsed=Date().timeIntervalSince(drop)
        let row=(result["evaluations"] as! [[String:Any]])[0]
        precondition((row["nodes"] as! Int)>=ChallengeEngine.nodes)
        precondition((row["pv"] as! [String]).first==root)
        do {_ = try await ponder.value;preconditionFailure("Canceled owner returned")}catch{}
        records.append(["history":history,"root":root,"afterDropSeconds":elapsed,"totalSeconds":Date().timeIntervalSince(start),"nodes":row["nodes"]!,"cp":row["cp"]!,"pv":row["pv"]!])
    }
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","measurements":records,"scope":"Development Mac, 2M-node exact root searches, 0.9s pondering before drop"],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
