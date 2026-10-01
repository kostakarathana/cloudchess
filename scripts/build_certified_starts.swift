import Foundation
import CryptoKit

/// Reproducible full-strength positions for cold handoffs. Never stores bot/scout output.
@main struct BuildCertifiedStarts {
 static func main() async throws {
    let destination=URL(fileURLWithPath:CommandLine.arguments[1])
    let seeds=try await ChallengeBank.shared.load()
    var entries:[[String:Any]]=[],seen=Set<String>()
    for (index,original) in seeds.enumerated() {
        let (_,root)=try await ChallengeEngine.evaluate(initial:original.fen,multipv:3)
        for length in [0,2,4,6,8,10,12,14] where length<=root.line.count {
            let position=try await ChallengeEngine.state(original,moves:Array(root.line.prefix(length)))
            guard position["result"] is NSNull,let fen=position["fen"] as? String else{continue}
            let identity=fen.split(separator:" ").prefix(4).joined(separator:" ")
            guard !seen.contains(original.kind.rawValue+identity) else{continue}
            let (response,e)=try await ChallengeEngine.evaluate(initial:fen,multipv:3)
            guard response["result"] is NSNull,e.mate==nil,
                  PersistentChessEvidence.valid(response,request:ChallengeEngine.request(initial:fen,moves:[],multipv:3)),
                  original.kind == .tenMoves ? abs(e.cp)<=10:(180...650).contains(e.cp) else{continue}
            var p=original
            p.fen=fen;p.id=SHA256.hash(data:Data((p.kind.rawValue+fen).utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
            p.line=e.line;p.initialEvaluation=e.cp;p.nodes=e.nodes;p.source="generated:"+p.id
            p.complexity=min(100,12*log2(Double((response["legal"] as? [String])?.count ?? 20)+1)+Double(e.line.count))
            if p.kind == .tenMoves {p.plies=12;p.seconds=108}
            p=try ModeDifficulty.calibrated(p,response:response,opponent:1800)
            let puzzle=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p))
            let digest=SHA256.hash(data:try JSONSerialization.data(withJSONObject:response,options:.sortedKeys)).map{String(format:"%02x",$0)}.joined()
            entries.append(["puzzle":puzzle,"response":response,"digest":digest]);seen.insert(original.kind.rawValue+identity)
        }
        FileHandle.standardError.write(Data("\(index+1)/\(seeds.count): \(entries.count) verified positions\n".utf8))
    }
    let archive:[String:Any]=["namespace":PersistentChessEvidence.namespace,"schema":1,"entries":entries]
    try JSONSerialization.data(withJSONObject:archive,options:.sortedKeys).write(to:destination,options:.atomic)
    print("Saved \(entries.count) full-budget certified starts")
 }
}
