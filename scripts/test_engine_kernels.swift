import Foundation

@main struct EngineKernels {
    static func main() throws {
        let network=ProcessInfo.processInfo.environment["CC_NETWORK_PATH"]!
        let seeds=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"CloudChess/EngineResources/challenge-starts.json"))) as! [[String:Any]]
        var records:[[String:Any]]=[]
        var checks=0
        for (index,seed) in seeds.enumerated() where index%max(1,seeds.count/128)==0 {
            guard records.count<128,let fen=seed["fen"] as? String else{continue}
            let state=CCChess(["action":"analyse","initial":fen,"nodes":20000,"multipv":3],network) as! [String:Any]
            precondition(state["error"]==nil,"\(state)");checks+=1
            let legal=Set(state["legal"] as! [String])
            let evaluations=state["evaluations"] as? [[String:Any]] ?? []
            for row in evaluations {
                let line=row["pv"] as! [String]
                precondition(line.first.map{legal.contains($0)} ?? false);checks+=1
                let end=CCChess(["action":"state","initial":fen,"moves":line],network) as! [String:Any]
                precondition(end["error"]==nil,"PV legality");checks+=1
            }
            records.append(["fen":fen,"evaluations":evaluations,"kernel":state["kernel"] ?? "terminal"])
        }
        // Verify the strength switch always resets before a strong evaluation.
        let fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let request:[String:Any]=["action":"analyse","initial":fen,"nodes":100000,"multipv":1]
        let expected=CCChess(request,network)!["evaluations"] as! NSArray
        for elo in [100,600,1319,1320,1800,2400,3000] {
            let bot=CCChess(["action":"bot","initial":fen,"nodes":300000,"elo":elo,"multipv":1],network) as! [String:Any]
            precondition((bot["legal"] as! [String]).contains(bot["bestmove"] as! String));checks+=1
            let strong=CCChess(request,network)!["evaluations"] as! NSArray
            precondition(strong==expected,"Bot strength leaked into evaluator");checks+=1
        }
        print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"positions":records],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
