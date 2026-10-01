import Foundation
struct ArenaResult:Decodable {let id:String,bot:String,status:String}
@main struct BotAdaptation {
    static func main()throws {
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let rows=try String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8).split(separator:"\n").map{try JSONDecoder().decode(ArenaResult.self,from:Data($0.utf8))}
        let names=Set(rows.map{$0.bot}).sorted();var result:[[String:Any]]=[]
        for name in names {
            let outcomes=Dictionary(uniqueKeysWithValues:rows.filter{$0.bot==name && $0.status != "unknown"}.map{($0.id,$0.status=="solved")})
            let pool=bank.filter{outcomes[$0.id] != nil};var model=AdaptivePuzzleCoach();var levels:[Double]=[];var wins=0
            for i in 0..<180 {
                let p=model.candidates(pool)[0],id=String(p.id.split(separator:"-")[0]);let success=outcomes[id]!
                model.begin(p);model.session?.elapsed=p.seconds*(success ? 0.65:1.8)
                model.session?.mistakes=success ? 0:3;model.finish(skipped:!success)
                if i>=120 {levels.append(p.rating);wins+=success ? 1:0}
            }
            result.append(["bot":name,"selectedDifficulty":levels.reduce(0,+)/Double(levels.count),"solveRate":Double(wins)/60,"learnedAbility":model.ability.mean])
        }
        func level(_ name:String)->Double {result.first{$0["bot"] as? String==name}!["selectedDifficulty"] as! Double}
        precondition(level("native-4")>level("native-1")+250,"A stronger independent player must get harder items")
        precondition(level("fairy-8192")>level("fairy-128")+100,"Difficulty must separate independent Fairy strengths")
        let json=try JSONSerialization.data(withJSONObject:["status":"passed","attempts":180*names.count,"bots":result],options:[.prettyPrinted,.sortedKeys]);print(String(decoding:json,as:UTF8.self))
    }
}
