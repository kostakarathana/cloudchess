import Foundation
@main struct GenerationBenchmark {
 static func main() async throws {
    var rows:[[String:Any]]=[]
    for kind in [ChallengeKind.tenMoves,.finish] {
      for seed:UInt64 in [42,101,202] {
        let start=ProcessInfo.processInfo.systemUptime,metrics=NativeChess.searchMetrics
        let p=try await ChallengeEngine.generated(kind,rating:1500,seed:seed,opponentElo:1300,learner:1500,targetSuccess:0.67,opponentBounds:400...2200)
        let e=ChallengeEngine.cached(initial:p.fen,moves:[],multipv:3)!
        precondition(e.nodes>=ChallengeEngine.nodes && e.mate==nil)
        precondition(kind == .tenMoves ? abs(e.cp)<=10 : (180...650).contains(e.cp))
        let row:[String:Any]=["kind":kind.rawValue,"seed":seed,"seconds":ProcessInfo.processInfo.systemUptime-start,"searches":NativeChess.searchMetrics["executed"]!-metrics["executed"]!,"fen":p.fen,"cp":e.cp,"nodes":e.nodes,"rating":p.rating]
        rows.append(row)
        FileHandle.standardError.write(Data("\(kind.rawValue) \(seed): \(row["seconds"]!)s\n".utf8))
      }
    }
    print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
