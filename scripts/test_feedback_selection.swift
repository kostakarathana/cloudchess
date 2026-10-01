import Foundation
@main struct Tests {
 static func main() async throws {
    var checks=0
    func check(_ b:Bool,_ why:String){precondition(b,why);checks+=1}
    var distributions:[[String:Any]]=[]
    for available in [false,true] {
        var low=AdaptivePuzzleCoach(),high=AdaptivePuzzleCoach(),counts:[String:Int]=[:],pairs:[String:[String:Int]]=[:]
        high.ability.mean=2900;high.scoring=ChallengeScore(total:10000000,best:10000000)
        var previous:ChallengeKind?,repeats=0
        for _ in 0..<140000 {
            let kind=low.selectChallengeKind(personalAvailable:available)
            check(kind==high.selectChallengeKind(personalAvailable:available),"Skill and score must not weight mode selection")
            check(available || kind != .personal,"No unavailable personal mode")
            counts[kind.rawValue,default:0]+=1
            if let previous {pairs[previous.rawValue,default:[:]][kind.rawValue,default:0]+=1;if previous==kind {repeats+=1}}
            previous=kind
            low.recentChallengeKinds=[kind];high.recentChallengeKinds=[kind]
        }
        let modes=available ? 7:6,expected=140000.0/Double(modes)
        check(counts.count==modes,"All eligible modes appear")
        let chi=counts.values.reduce(0){$0+pow(Double($1)-expected,2)/expected}
        check(chi<25,"Uniform distribution goodness-of-fit")
        for row in pairs.values {
            let mean=Double(row.values.reduce(0,+))/Double(modes-1)
            check(row.count==modes-1 && row.values.allSatisfy{abs(Double($0)-mean)<mean*0.08},"Equal probability among nonrepeating modes")
        }
        check(repeats==0,"Adjacent modes never repeat")
        let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(low))
        var continuation=restored;check(low.selectChallengeKind(personalAvailable:available)==continuation.selectChallengeKind(personalAvailable:available),"Sequence persists deterministically")
        distributions.append(["personalAvailable":available,"counts":counts,"chiSquared":chi])
    }
    for elo in stride(from:400.0,through:3000,by:100) {
        var previous=0.0
        for cp in stride(from:-3000.0,through:3000,by:5) {
            let p=MoveQualityJudge.expected(cp,elo:elo)
            check(p>=previous && p>=0 && p<=1,"Smooth monotonic expected score")
            check(abs(p+MoveQualityJudge.expected(-cp,elo:elo)-1)<1e-12,"Side symmetric")
            previous=p
        }
    }
    func grade(_ best:Double,_ played:Double,_ exact:Bool=false,_ runner:Double?=nil,_ sacrifice:Bool=false,_ book:Bool=false)->MoveQuality {
        MoveQualityJudge.classify(best:best,played:played,isBest:exact,runnerUp:runner,sacrifice:sacrifice,book:book,elo:1400)
    }
    check(grade(30,30,true) == .best,"Ordinary best move")
    check(grade(30,20) == .excellent,"Small preference")
    check(grade(30,-10) == .good,"Reasonable alternative")
    check(grade(30,-50) == .inaccuracy,"Inaccuracy band")
    check(grade(30,-120) == .mistake,"Mistake band")
    check(grade(30,-300) == .blunder,"Severe loss")
    check(grade(210,45) == .miss,"Lost winning opportunity")
    check(grade(50,50,true,-160) == .great,"Only good move from verified alternatives")
    check(grade(50,45,false,-30,true) == .brilliant,"Sound, nontrivial sacrifice")
    check(grade(700,700,true,600,true) != .brilliant,"Already winning alternatives are not brilliant")
    check(grade(50,-300,false,-20,true) == .blunder,"An unsound sacrifice is not brilliant")
    check(grade(30,28,false,nil,false,true) == .book,"Sound book continuation")
    check(grade(30,-300,false,nil,false,true) == .blunder,"Book membership never blesses a bad move")
    check(MoveQuality.allCases.count==10 && Set(MoveQuality.allCases.map{$0.annotation ?? $0.symbol}).count==10,"Ten distinct symbols")
    // Legal Greek-gift PV: native replay must distinguish a real piece sacrifice
    // from a queen exchange or an ordinary capture. Engine values here isolate
    // the material-evidence branch, not a claim that this position is brilliant.
    let fen="r1bq1rk1/ppp2ppp/2n1pn2/3p4/3P4/2PB1N2/PP1N1PPP/R1BQ1RK1 w - - 0 1"
    let line=["d3h7","g8h7","f3g5"]
    let legal=try await NativeChess.call(["action":"state","initial":fen,"moves":line])
    check(MoveQualityJudge.material(legal["fen"] as! String,white:true)==MoveQualityJudge.material(fen,white:true)-2,"Net bishop-for-pawn sacrifice via native rules")
    func assessment(_ cp:Int,_ pv:[String],_ second:Int?=nil)throws->EngineAssessment {
        var rows:[[String:Any]]=[["cp":cp,"pv":pv,"depth":24,"nodes":2000000]]
        if let second {rows.append(["cp":second,"pv":["d1c2"],"depth":24,"nodes":2000000])}
        return try EngineAssessment(["evaluations":rows])
    }
    let best=try assessment(50,line,-30)
    let decision=TurnAnalysis.Decision(best:best,played:best,rejected:false,deepRecheck:false)
    let quality=try await MoveQualityJudge.grade(initial:fen,history:[],move:line[0],beforeFEN:fen,decision:decision,elo:1400)
    check(quality == .brilliant,"Sacrifice classification replays actual legal captures")
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"modeDistributions":distributions],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
