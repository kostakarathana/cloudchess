import Foundation
@main struct SixMoveCalibration {
 static func main() async throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),destination=URL(fileURLWithPath:CommandLine.arguments[2])
    let model=try JSONDecoder().decode(ModeDifficulty.Model.self,from:Data(contentsOf:root.appendingPathComponent("CloudChess/EngineResources/mode-difficulty-v3.json")))
    let paths=["training/mode-v3-rollouts.jsonl","training/mode-v3-edge-rollouts.jsonl"]
    var rows:[[String:Any]]=[]
    for path in paths {
        for line in try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8).split(separator:"\n") {
            guard var row=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],row["kind"] as? String=="tenMoves" else{continue}
            let initial=row["fen"] as! String,moves=Array((row["moves"] as! [String]).prefix(12))
            let state=try await NativeChess.call(["action":"state","initial":initial,"moves":moves])
            guard moves.count==12 || state["result"] is String else{continue}
            let white=initial.split(separator:" ")[1]=="w"
            let success:Bool
            if let result=state["result"] as? String {success=result==(white ? "White wins":"Black wins")}
            else {
                let (_,start)=try await ChallengeEngine.evaluate(initial:initial,multipv:3)
                let (end,evaluation)=try await ChallengeEngine.evaluate(initial:initial,moves:moves)
                success=evaluation.forSolver(turn:end["turn"] as! String,white:white)>start.cp
                row["finalNodes"]=evaluation.nodes;row["initialCP"]=start.cp;row["finalCP"]=evaluation.forSolver(turn:end["turn"] as! String,white:white)
            }
            var features=row["features"] as! [Double]
            row["priorLogit"]=model.logit(Array(features.dropLast()),at:row["solver"] as! Double)
            features[14]=0.6;row["features"]=features;row["turns"]=6;row["moves"]=moves;row["status"]=success ? "solved":"failed"
            rows.append(row)
            if rows.count%32==0 {FileHandle.standardError.write(Data("\(rows.count) six-move outcomes verified\n".utf8))}
        }
    }
    let text=try rows.map{String(data:try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys),encoding:.utf8)!}.joined(separator:"\n")+"\n"
    try Data(text.utf8).write(to:destination,options:.atomic)
    print("Verified \(rows.count) recorded bot trajectories at six turns, using full-history 2M-node final evaluations")
 }
}
