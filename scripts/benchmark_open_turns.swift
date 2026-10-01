import Foundation

/// Real cold full-budget searches, bypassing Swift's result cache. Run the same
/// binary in separate processes with/without CC_FORCE_BASELINE_ENGINE=1.
@main struct OpenTurnBenchmark {
    static func main() throws {
        let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let network=ProcessInfo.processInfo.environment["CC_NETWORK_PATH"]!
        var records:[[String:Any]]=[]
        let histories=[
            ["e2e4","e7e5"],
            ["d2d4","d7d5","c2c4","e7e6","b1c3","g8f6"],
            ["e2e4","c7c5","g1f3","d7d6","d2d4","c5d4","f3d4","g8f6","b1c3","a7a6"],
            ["e2e4","e7e5","g1f3","b8c6","f1b5","a7a6","b5a4","g8f6","e1g1","f8e7","f1e1","b7b5","a4b3","d7d6"]
        ]
        _=CCChess(["action":"analyse","initial":initial,"nodes":10000,"multipv":1],network)
        for (history,move) in zip(histories,["f1c4","c1g5","f1e2","c2c3"]) {
            for (stage,root,budget) in [("baseline",nil,2_000_000),("played",Optional(move),2_000_000)] {
                var request:[String:Any]=["action":"analyse","initial":initial,"moves":history,"nodes":budget,"multipv":1]
                if let root {request["root"]=root}
                let start=ProcessInfo.processInfo.systemUptime
                let result=CCChess(request,network) as! [String:Any]
                let elapsed=ProcessInfo.processInfo.systemUptime-start
                precondition(result["error"]==nil,"\(result)")
                let row=(result["evaluations"] as! [[String:Any]])[0]
                precondition((row["nodes"] as! Int)>=budget)
                records.append(["stage":stage,"history":history,"root":root ?? "","seconds":elapsed,"cp":row["cp"]!,"nodes":row["nodes"]!,"depth":row["depth"]!,"pv":row["pv"]!])
            }
        }
        let probe=CCChess(["action":"analyse","initial":initial,"nodes":1000,"multipv":1],network) as! [String:Any]
        print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","kernel":probe["kernel"] ?? "unknown","measurements":records,"scope":"Development Mac; identical cold single-thread full 2M-node searches, not physical iPhone timings"],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
