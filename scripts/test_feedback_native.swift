import Foundation
@main struct Checks {
 static func main() async throws {
    var checks=0,rows:[[String:Any]]=[]
    for (fen,bad) in [("7k/8/5KQ1/8/8/8/8/8 w - - 0 1","g6g8"),("8/8/8/8/8/5kq1/8/7K b - - 0 1","g3g1")] {
        let (_,best)=try await ChallengeEngine.evaluate(initial:fen,multipv:3)
        for move in [best.line[0],bad] {
            let decision=try await TurnAnalysis.assess(.tenMoves,initial:fen,history:[],move:move,baseline:best)
            let quality=try await MoveQualityJudge.grade(initial:fen,history:[],move:move,beforeFEN:fen,decision:decision,elo:1100)
            if move==bad {precondition(quality == .blunder)} else {precondition(quality == .best || quality == .great)}
            checks+=1
            rows.append(["fen":fen,"move":move,"quality":quality.rawValue,"bestCP":decision.best.cp,"playedCP":decision.played.cp,"nodes":decision.played.nodes])
        }
    }
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"fullStrengthExamples":rows],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
