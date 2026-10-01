import Foundation
@main struct ImprovementHandoffTests {
 static func main() async throws {
    var checks=0
    func check(_ value:Bool,_ message:String) {checks+=1;precondition(value,message)}
    let begin=ProcessInfo.processInfo.systemUptime
    let archive=try await CertifiedChallengeBank.shared.load()
    check(archive.filter{$0.puzzle.kind == .tenMoves}.count>=32,"Balanced archive must contain at least 32 distinct starts")
    check(archive.filter{$0.puzzle.kind == .finish}.count>=32,"Conversion archive must contain at least 32 distinct starts")
    var seenPositions=Set<String>()
    for entry in archive {
        let p=entry.puzzle,e=try EngineAssessment(entry.response)
        check(e.nodes>=2_000_000 && e.mate==nil,"Full strength, nonterminal evidence")
        check(p.kind == .tenMoves ? abs(e.cp)<=10:(180...650).contains(e.cp),"Exact objective gate")
        check(seenPositions.insert(p.kind.rawValue+":"+p.fen.split(separator:" ").prefix(4).joined(separator:" ")).inserted,"Distinct archived position")
        let state=try await ChallengeEngine.state(p,moves:[])
        check(state["fen"] as? String==p.fen,"Starting FEN is legal")
        check(state["legal"] as? [String]==entry.response["legal"] as? [String],"Certified legal moves match shipping rules")
        let line=try await ChallengeEngine.state(p,moves:e.line)
        check(line["error"]==nil,"Entire certified PV is legal")
    }
    let validationSeconds=ProcessInfo.processInfo.systemUptime-begin
    var times:[Double]=[],ids=Set<String>(),blocked=Set<String>(),recent:[TrainingPuzzle]=[]
    let before=NativeChess.searchMetrics["executed"]!
    for i in 0..<400 {
        let kind:ChallengeKind=i%2==0 ? .tenMoves:.finish
        let rating=Double(400+(i*137)%2601),opponent=min(3000,max(100,rating-150)),start=ProcessInfo.processInfo.systemUptime
        let p=try await ChallengeEngine.generated(kind,rating:rating,seed:UInt64(i*19237),opponentElo:opponent,learner:rating,targetSuccess:0.67,opponentBounds:max(100,opponent-200)...min(3000,opponent+200),excluding:ids,avoiding:blocked)
        times.append(ProcessInfo.processInfo.systemUptime-start)
        check(p.kind==kind,"Selection preserves requested mode")
        check(p.repeatKeys.isDisjoint(with:blocked),"Never repeat any of last three puzzles")
        check(p.calibrationOpponent!>=max(100,opponent-200) && p.calibrationOpponent!<=min(3000,opponent+200),"Adaptive frozen opponent")
        check(p.rating.isFinite && (400...3000).contains(p.rating),"Calibrated points rating")
        if kind == .tenMoves {check(p.plies==12 && p.solverMoves==6 && p.difficultyFeatures![14]==0.6,"Six-turn feature, rules and reward horizon agree")}
        let e=ChallengeEngine.cached(initial:p.fen,moves:[],multipv:3)
        check(e?.nodes ?? 0>=2_000_000,"Starting assessment immediately available")
        check(ChallengeEngine.cached(initial:p.fen,moves:["invalid"],multipv:3)==nil,"Evidence never aliases other histories")
        ids.insert(p.id);recent.append(p);recent=Array(recent.suffix(3));blocked=Set(recent.flatMap{$0.repeatKeys})
    }
    check(NativeChess.searchMetrics["executed"]! == before,"No Stockfish search on certified cold handoff, even after archive exhaustion")
    let sample=archive[0]
    for alteration in 0..<4 {
        var result=sample.response
        switch alteration {
        case 0:result["limitedStrength"]=true
        case 1:result["fen"]="invalid"
        case 2:result["evaluations"]=[]
        default:
            var values=result["evaluations"] as! [[String:Any]];values[0]["nodes"]=1000;result["evaluations"]=values
        }
        do {try NativeChess.retainCertifiedStart(result,initial:sample.puzzle.fen);fatalError("Invalid evidence accepted")} catch {checks+=1}
    }
    let source=archive.first{$0.puzzle.kind == .tenMoves}!.puzzle
    for count in 0...24 {
        check(ImprovementChallenge.isComplete(plies:count)==(count>=12),"Ends after sixth reply, never fifth or sixth player move")
        var coach=AdaptivePuzzleCoach();var legacy=source;legacy.plies=20;coach.begin(legacy)
        coach.session?.moves=Array(repeating:"a1a2",count:count);coach.session?.undoCount=2
        let value=coach.session!.reward,history=coach.session!.moves,opponent=coach.session!.opponentElo
        coach.migrateDifficulty()
        check(coach.session!.puzzle.plies==12 && coach.session!.moves==history,"Legacy history retained with new limit")
        check(coach.session!.reward==value && coach.session!.opponentElo==opponent,"Frozen reward and opponent preserved")
        coach.migrateDifficulty();check(coach.session!.moves==history,"Migration idempotent")
    }
    for count in 1...12 {
        var session=PuzzleSession(puzzle:source);session.moves=Array(repeating:"a1a2",count:count)
        check(session.undoLastDecision(),"Undo remains available at every six-move turn")
        check(session.moves.count==(count-1)/2*2,"Undo removes last decision and reply")
        check(!ImprovementChallenge.isComplete(plies:session.moves.count),"Undo reopens final turn")
    }
    let foregroundSearches=NativeChess.searchMetrics["executed"]!-before
    let backgroundStart=ProcessInfo.processInfo.systemUptime
    let novel=try await NativeChess.$backgroundEpoch.withValue(CCBackgroundEpoch()) {
        try await ChallengeEngine.generated(.tenMoves,rating:1500,seed:42,opponentElo:1300,learner:1500,targetSuccess:0.67,opponentBounds:400...2200,excluding:Set(archive.map{$0.puzzle.id}))
    }
    check(!archive.contains{$0.puzzle.id==novel.id},"Idle preparation can still generate an unseen position beyond the archive")
    check(novel.plies==12 && novel.difficultyFeatures![14]==0.6,"Novel generation uses six-turn calibration")
    let freshAssessment=ChallengeEngine.cached(initial:novel.fen,moves:[],multipv:3)!
    check(abs(freshAssessment.cp)<=10 && freshAssessment.nodes>=2_000_000,"Novel position keeps exact balance and strength gates")
    let backgroundSeconds=ProcessInfo.processInfo.systemUptime-backgroundStart
    // Native engine bypasses the evidence cache: independently reproduce a sample.
    let network=ProcessInfo.processInfo.environment["CC_NETWORK_PATH"]!
    for index in stride(from:0,to:archive.count,by:max(1,archive.count/8)) {
        let entry=archive[index],request=ChallengeEngine.request(initial:archive[index].puzzle.fen,moves:[],multipv:3)
        let fresh=CCChess(request,network) as! [String:Any]
        check(NSDictionary(dictionary:fresh).isEqual(to:entry.response),"Baked response exactly matches a fresh shipping engine search")
    }
    times.sort()
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"certifiedStarts":archive.count,"handoffs":times.count,"archiveValidationSeconds":validationSeconds,"median":times[times.count/2],"p95":times[Int(Double(times.count)*0.95)],"max":times.last!,"foregroundSearches":foregroundSearches,"novelBackgroundSeconds":backgroundSeconds],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
