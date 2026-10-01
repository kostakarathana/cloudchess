import Foundation
@main struct LandingBenchmark {
 static func main() async throws {
    let serial=CommandLine.arguments.contains("--serial")
    let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    _ = try await NativeChess.call(["action":"analyse","initial":initial,"nodes":10000,"moves":[],"multipv":1])
    var records:[[String:Any]]=[]
    for (history,move) in [(["e2e4","e7e5"],"g1f3"),(["d2d4","d7d5"],"c2c4"),(["g1f3","g8f6"],"d2d4")] {
        let start=ProcessInfo.processInfo.systemUptime
        if serial {try await Task.sleep(for:.milliseconds(600))}
        let r=try await NativeChess.call(ChallengeEngine.request(initial:initial,moves:history,root:move))
        if !serial {
            let remaining=0.6-(ProcessInfo.processInfo.systemUptime-start)
            if remaining>0 {try await Task.sleep(for:.seconds(remaining))}
        }
        let row=(r["evaluations"] as! [[String:Any]])[0]
        precondition((row["nodes"] as! Int)>=2_000_000)
        records.append(["history":history,"root":move,"placementToVerdictSeconds":ProcessInfo.processInfo.systemUptime-start,"nodes":row["nodes"]!,"cp":row["cp"]!,"pv":row["pv"]!])
    }
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","serial":serial,"measurements":records,"scope":"Development Mac, cold 2M-node root searches plus 0.6s landing; not physical-phone timings"],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
