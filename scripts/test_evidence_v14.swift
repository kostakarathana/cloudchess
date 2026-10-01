import Foundation
@main struct EvidenceChecks {
 static func main() async throws {
    let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    let request=ChallengeEngine.request(initial:initial,moves:[],multipv:3)
    let state=try await NativeChess.call(request)
    precondition(PersistentChessEvidence.valid(state,request:request))
    precondition(!PersistentChessEvidence.eligible(["action":"bot","nodes":2000000]))
    precondition(!PersistentChessEvidence.eligible(["action":"analyse","nodes":180000]))
    var partial=state
    var rows=state["evaluations"] as! [[String:Any]];rows[0]["nodes"]=400;partial["evaluations"]=rows
    precondition(!PersistentChessEvidence.valid(partial,request:request))
    partial=state;partial["error"]="cancelled"
    precondition(!PersistentChessEvidence.valid(partial,request:request))
    partial=state;partial["limitedStrength"]=true
    precondition(!PersistentChessEvidence.valid(partial,request:request))
    PersistentChessEvidence.store(state,key:"integrity-test",request:request)
    precondition(PersistentChessEvidence.load("integrity-test",request:request) != nil)
    let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CC_EVIDENCE_CACHE"]!).appendingPathComponent(PersistentChessEvidence.namespace)
    let file=base.appendingPathComponent("integrity-test.json")
    try Data("broken".utf8).write(to:file)
    precondition(PersistentChessEvidence.load("integrity-test",request:request)==nil)
    // Valid JSON with a changed score must fail its integrity digest.
    PersistentChessEvidence.store(state,key:"integrity-test",request:request)
    var record=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
    var altered=state;rows=state["evaluations"] as! [[String:Any]];rows[0]["cp"]=99999;altered["evaluations"]=rows
    record["result"]=altered;try JSONSerialization.data(withJSONObject:record).write(to:file)
    precondition(PersistentChessEvidence.load("integrity-test",request:request)==nil)
    // Request keys cover root, history, MultiPV and budgets. A root-only result
    // must never become the unconstrained baseline or its deeper recheck.
    let before=NativeChess.searchMetrics["executed"]!
    _ = try await ChallengeEngine.evaluate(initial:initial,root:"e2e4",budget:2000000)
    precondition(NativeChess.searchMetrics["executed"]!>before)
    precondition(ChallengeEngine.cached(initial:initial,moves:[],root:"e2e4",budget:8000000)==nil)
    precondition(ChallengeEngine.cached(initial:initial,moves:["e2e4"],multipv:3)==nil)
    precondition(ChallengeEngine.cached(initial:initial,moves:[],multipv:1)==nil)
    // Bounded storage remains bounded after many different exact requests.
    for i in 0..<300 {PersistentChessEvidence.store(state,key:"quota-\(i)",request:request)}
    let files=try FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
    precondition(files.count<=271)
    var checks=15
    for source in ChessProfileProvider.allCases {
        for valid in ["Kosta","alpha_123","name-1","  player  "] {precondition(source.profileURL(username:valid) != nil);checks+=1}
        for invalid in [""," ","https://lichess.org/@/user","foo/bar","a?b","a#b","a@b","a b",String(repeating:"x",count:65)] {precondition(source.profileURL(username:invalid)==nil);checks+=1}
    }
    precondition(ChessProfileProvider.lichess.profileURL(username:"Kosta")?.absoluteString=="https://lichess.org/@/Kosta")
    precondition(ChessProfileProvider.chesscom.profileURL(username:"Kosta")?.absoluteString=="https://www.chess.com/member/Kosta")
    print("Passed \(checks+2) evidence integrity, request isolation and username checks")
 }
}
