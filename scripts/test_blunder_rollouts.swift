import Foundation
@main struct Rollouts {
 static func main() async throws {
    let seeds=CommandLine.arguments.dropFirst().compactMap{UInt64($0)}
    for seed in seeds {
        let puzzle=try await BlunderEngine.generate(rating:1400,seed:seed,opponent:1400,excluding:[])
        var history:[String]=[],opportunity:BlunderEngine.Opportunity?,injected=0
        var checks=0
        for turn in 1...3 {
            let best=try await ChallengeEngine.evaluate(initial:puzzle.fen,moves:history).1
            precondition(best.cp >= -50 && best.mate==nil);checks+=1
            let move=best.line[0];history.append(move)
            if turn>=BlunderEngine.targetTurn(seed:seed) {opportunity=try await BlunderEngine.find(initial:puzzle.fen,moves:history,seed:seed)}
            if let opportunity {history.append(opportunity.move);injected=turn;break}
            let defense=try await ChallengeEngine.evaluate(initial:puzzle.fen,moves:history).1
            history.append(defense.line[0])
        }
        guard let opportunity else{throw ModeDifficulty.failure("No significant blunder at turn 2–3 for seed \(seed)")}
        precondition((2...3).contains(injected) && opportunity.loss>=250 && opportunity.advantage>=200);checks+=3
        let forcedHistory=history
        for skill in [600.0,1400,2600] {
            history=forcedHistory
            var kept=true,turns=0,losses:[Double]=[]
            for _ in 0..<3 {
                let state=try await ChallengeEngine.state(puzzle,moves:history)
                if let result=state["result"] as? String {kept=result==(puzzle.white ? "White wins":"Black wins");break}
                let move=try await ChallengeEngine.opponent(initial:puzzle.fen,moves:history,elo:skill)
                precondition((state["legal"] as! [String]).contains(move));checks+=1
                let decision=try await TurnAnalysis.assess(.blunderPunish,initial:puzzle.fen,history:history,move:move)
                var cp=decision.played.cp
                if !BlunderEngine.retained(cp) {cp=try await ChallengeEngine.evaluate(initial:puzzle.fen,moves:history,root:move,budget:8000000).1.cp}
                losses.append(cp);history.append(move);turns+=1
                if !BlunderEngine.retained(cp) {kept=false;break}
                if turns==3 {break}
                let after=try await ChallengeEngine.state(puzzle,moves:history)
                if let result=after["result"] as? String {kept=result==(puzzle.white ? "White wins":"Black wins");break}
                history.append(try await ChallengeEngine.opponent(initial:puzzle.fen,moves:history,elo:1400))
            }
            let row:[String:Any]=["seed":seed,"initial":puzzle.fen,"solver":skill,"opponent":1400,"injectedTurn":injected,"blunder":opportunity.move,"loss":opportunity.loss,"advantage":opportunity.advantage,"held":kept,"solverTurns":turns,"evaluations":losses,"history":history,"checks":checks]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),encoding:.utf8)!)
            fflush(stdout)
        }
    }
 }
}
