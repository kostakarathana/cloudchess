import Foundation
@main struct SearchHandoffTests {
 static func main() async throws {
    var checks=0
    func check(_ value:Bool,_ why:String){precondition(value,why);checks+=1}
    let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:"CloudChess/EngineResources/puzzles.json")))
    for seed in bank.prefix(100) {
        for kind in ChallengeKind.allCases {
            var p=seed;p.challengeType=kind.rawValue;p.fen=initial
            let history=["e2e4","e7e5"],known:Set<String>=["g1f3"]
            func keep(_ r:[String:Any],_ source:String?="g1",_ move:String?=nil)->Bool {
                TurnAnalysis.keepsPreparation(r,puzzle:p,history:history,known:known,source:source,move:move)
            }
            let allowed=kind != .tactics && kind != .whosWinning
            check(keep(ChallengeEngine.request(initial:initial,moves:history))==allowed,"Current baseline preserved only in applicable modes")
            check(keep(ChallengeEngine.request(initial:initial,moves:history,root:"g1f3"))==allowed,"Selected piece's root can continue")
            check(!keep(ChallengeEngine.request(initial:initial,moves:history,root:"f1c4")),"Different piece never holds foreground work")
            check(!keep(ChallengeEngine.request(initial:initial,moves:history,root:"g1h3"),nil,"g1f3"),"Exact drop overrides pickup source")
            check(!keep(ChallengeEngine.request(initial:initial,moves:history,budget:12000)),"Scouts are expendable")
            check(!keep(ChallengeEngine.request(initial:initial,moves:["d2d4","d7d5"])),"Same-ply different history cannot alias")
            let future=ChallengeEngine.request(initial:initial,moves:history+["g1f3","b8c6"])
            check(keep(future)==(kind == .opening || kind == .personal),"Book successor kept only for a completed candidate")
            if kind == .finish || kind == .tenMoves {
                func successor(_ r:[String:Any],_ replies:[String:String])->Bool {
                    TurnAnalysis.keepsPreparation(r,puzzle:p,history:history,known:known,source:nil,move:"g1f3",replies:replies)
                }
                check(successor(future,["g1f3":"b8c6"]),"Exact prepared bot successor survives drop")
                check(!successor(future,["g1f3":"g8f6"]),"Different opponent move never aliases")
                check(!successor(future,[:]),"Unprepared bot future never survives")
                var root=future;root["root"]="f1c4"
                check(!successor(root,["g1f3":"b8c6"]),"Only future baseline is preserved")
                let reply=TurnAnalysis.PreparedReply(initial:initial,history:history+["g1f3"],elo:1500,move:"b8c6")
                check(reply.matches(initial:initial,history:history+["g1f3"],elo:1500,legal:["b8c6"]),"Frozen reply matches exact turn")
                check(!reply.matches(initial:initial,history:history,elo:1500,legal:["b8c6"]),"Reply history must match")
                check(!reply.matches(initial:initial,history:history+["g1f3"],elo:1600,legal:["b8c6"]),"Reply strength must match")
                check(!reply.matches(initial:initial,history:history+["g1f3"],elo:1500,legal:["g8f6"]),"Reply must remain legal")
            }
            let probe=ChallengeEngine.request(initial:initial,moves:history+["g1f3"],root:"a7a6")
            check(keep(probe)==(kind == .blunderPunish),"Blunder probe kept only for the matching candidate")
            let unknown=ChallengeEngine.request(initial:initial,moves:history+["g1h3","b8c6"])
            check(!keep(unknown),"Unverified future discarded")
            check(!keep(ChallengeEngine.request(initial:initial,moves:[])),"Short histories rejected safely")
        }
    }
    for p in bank.prefix(200) {
        guard let move=p.line.first else{continue}
        var r=p.request("judge");r["candidate"]=move;r["budget"]=1_000_000
        func keep(_ r:[String:Any],source:String?=nil,chosen:String?=nil)->Bool {
            TurnAnalysis.keepsPreparation(r,puzzle:p,history:[],known:[],source:source,move:chosen)
        }
        check(keep(r,source:String(move.prefix(2))),"Picked tactical proof is preserved")
        check(keep(r,chosen:move),"Exact tactical drop adopts its proof")
        check(!keep(r,chosen:"z9z8"),"Unrelated tactical proof is canceled")
        for (key,value) in [("moves",[move] as Any),("budget",10000 as Any),("plies",999 as Any),("columns",3 as Any),("initial",initial as Any)] {
            var altered=r;altered[key]=value
            check(!keep(altered,chosen:move),"Tactical identity includes \(key)")
        }
    }
    let request=ChallengeEngine.request(initial:initial,moves:["e2e4","e7e5"],root:"g1f3")
    let before=NativeChess.searchMetrics
    let copies=try await withThrowingTaskGroup(of:Data.self) {group in
        for _ in 0..<64 {group.addTask {
            let r=try await NativeChess.call(request)
            return try JSONSerialization.data(withJSONObject:r,options:.sortedKeys)
        }}
        var results:[Data]=[];for try await result in group {results.append(result)};return results
    }
    check(copies.count==64 && Set(copies).count==1,"Concurrent callers get identical complete evidence")
    check(NativeChess.searchMetrics["executed"]!-before["executed"]! == 1,"Exactly one native search for 64 simultaneous consumers")
    check(NativeChess.searchMetrics["joined"]!-before["joined"]!>=60,"In-flight requests coalesce")
    let next=ChallengeEngine.request(initial:initial,moves:["d2d4","d7d5"],root:"c2c4")
    let epoch=CCBackgroundEpoch(),executed=NativeChess.searchMetrics["executed"]!
    let bg=Task {try await NativeChess.$backgroundEpoch.withValue(epoch){try await NativeChess.call(next)}}
    try await Task.sleep(for:.milliseconds(200))
    bg.cancel();NativeChess.cancelPreparation{($0["moves"] as? [String]) == ["d2d4","d7d5"]}
    let result=try await NativeChess.call(next)
    check(NativeChess.searchMetrics["executed"]!-executed==1,"Canceled speculative owner does not restart useful native work")
    check((try EngineAssessment(result)).nodes>=2_000_000,"Adoption keeps the full budget")
    do {_ = try await bg.value;preconditionFailure("Canceled owner resumed")}catch{checks+=1}
    // A prepared limited-strength reply's full-strength successor can also be
    // adopted while its speculative owner is canceled by the actual drop.
    var open=bank[0];open.challengeType=ChallengeKind.tenMoves.rawValue;open.fen=initial
    let future=ChallengeEngine.request(initial:initial,moves:["e2e4","e7e5","g1f3","b8c6"])
    let futureEpoch=CCBackgroundEpoch(),futureCount=NativeChess.searchMetrics["executed"]!
    let pondering=Task {try await NativeChess.$backgroundEpoch.withValue(futureEpoch){try await NativeChess.call(future)}}
    try await Task.sleep(for:.milliseconds(200));pondering.cancel()
    NativeChess.cancelPreparation {TurnAnalysis.keepsPreparation($0,puzzle:open,history:["e2e4","e7e5"],known:["g1f3"],source:nil,move:"g1f3",replies:["g1f3":"b8c6"])}
    let successor=try await NativeChess.call(future)
    check((try EngineAssessment(successor)).nodes>=2_000_000,"Future evaluation retains full budget")
    check(NativeChess.searchMetrics["executed"]!-futureCount==1,"Prepared bot successor does not restart after placement")
    do {_ = try await pondering.value;preconditionFailure("Canceled future owner resumed")}catch{checks+=1}
    // An interruption AFTER adoption must retry, not expose partial evidence.
    let retryRequest=ChallengeEngine.request(initial:initial,moves:["c2c4"],root:"e7e5")
    let retryEpoch=CCBackgroundEpoch()
    let old=Task {try await NativeChess.$backgroundEpoch.withValue(retryEpoch){try await NativeChess.call(retryRequest)}}
    try await Task.sleep(for:.milliseconds(150))
    let foreground=Task {try await NativeChess.call(retryRequest)}
    try await Task.sleep(for:.milliseconds(100));NativeChess.cancelPreparation()
    let verified=try await foreground.value
    check((try EngineAssessment(verified)).nodes>=2_000_000,"Foreground safely retries a superseded background search")
    do {_ = try await old.value;preconditionFailure("Old epoch accepted")}catch{checks+=1}
    // Never attach to unrelated history, MultiPV, root or work budget.
    for (key,value) in [("nodes",10000 as Any),("multipv",3 as Any),("root","b1c3" as Any),("moves",["d2d4","d7d5"] as Any)] {
        var r=request;r[key]=value
        check(NativeChess.cached(r)==nil,"Exact request identity includes \(key)")
    }
    // Rules-only input stays available while an expensive search runs.
    let e=CCBackgroundEpoch()
    let long=Task {try await NativeChess.$backgroundEpoch.withValue(e){try await NativeChess.call(ChallengeEngine.request(initial:initial,moves:["a2a3"],budget:8_000_000,multipv:3))}}
    try await Task.sleep(for:.milliseconds(100));var worst=0.0
    for _ in 0..<500 {
        let t=Date();let state=try await NativeChess.call(["action":"state","initial":initial,"moves":["e2e4"]])
        worst=max(worst,Date().timeIntervalSince(t));check((state["legal"] as? [String])?.count==20,"Input position remains legal during analysis")
    }
    let canceledAt=Date();NativeChess.cancelPreparation()
    do {_ = try await long.value;preconditionFailure("Canceled search escaped")}catch{checks+=1}
    check(Date().timeIntervalSince(canceledAt)<1,"Unrelated work yields promptly")
    check(worst<0.25,"Position-only input is not serialized behind Stockfish")
    check(NativeChess.searchMetrics["inFlight"]==0,"No orphaned flights/continuations")
    print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","checks":checks,"metrics":NativeChess.searchMetrics,"maxStateSeconds":worst],options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
 }
}
