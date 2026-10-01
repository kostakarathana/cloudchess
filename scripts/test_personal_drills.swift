import Foundation
@main struct Test {
 static func main() async throws {
  let pgn="""
  [White "tester"]
  [Black "opponent"]
  [WhiteElo "1100"]
  [BlackElo "1200"]
  [Result "0-1"]
  [Site "https://lichess.org/fixture"]
  [TimeControl "180+2"]

  1. f3 e5 2. g4 Qh4# 0-1
  """
  let service=OnDeviceProfiles.shared
  let job=try await service.testArchive(pgn,username:"tester"),id=job["id"] as! String
  await service.pause(userInitiated:true)
  for _ in 0..<30 {
   if try await service.status(id)["status"] as? String=="cancelled" {break}
   try await Task.sleep(for:.seconds(1))
  }
  let paused=try await service.upgradeIfNeeded(id)
  precondition(paused["status"] as? String=="cancelled","Explicit pause must stay paused")
  _ = try await service.resume(id)
  await service.pause()
  for _ in 0..<30 {
   if try await service.status(id)["status"] as? String=="cancelled" {break}
   try await Task.sleep(for:.seconds(1))
  }
  _ = try await service.upgradeIfNeeded(id)
  var resumed=false,firstCoverage:[String:Any]?
  for _ in 0..<240 {
   let status=try await service.status(id)
   if status["status"] as? String=="completed" {
    let report=try await service.report(id),coverage=report["coverage"] as! [String:Any]
    let games=coverage["importedGames"] as! Int
    precondition(coverage["allAnalysedMoves"] as? Int==games*4,"Both colors' every move analysed")
    precondition(coverage["completeGameDecisions"] as? Int==games*2,"Only player's decisions train weaknesses")
    if !resumed {firstCoverage=coverage;resumed=true;_ = try await service.resume(id);continue}
    precondition(NSDictionary(dictionary:coverage).isEqual(to:firstCoverage!),"Resume must not duplicate evidence or drills")
    let drills=try await service.drills(jobID:id)
    precondition(!drills.isEmpty,"Missed opportunities become playable drills")
    for p in drills {
     precondition(p.difficultyVersion==ModeDifficulty.version && p.difficultyFeatures?.count==17 && p.successLogits?.count==6,"Every extracted personal drill carries calibrated difficulty")
     precondition(p.kind == .personal && p.white && p.plies%2==1 && !p.line.isEmpty)
     let state=try await ChallengeEngine.state(p,moves:p.line)
     precondition((state["moves"] as? [String])==p.line,"Continuation is legal")
     let (_,best)=try await ChallengeEngine.evaluate(initial:p.fen,budget:100000)
     let (_,chosen)=try await ChallengeEngine.evaluate(initial:p.fen,root:best.line[0],budget:100000)
     precondition(best.cp-chosen.cp<=20,"Best move accepted")
    }
    let data=try JSONSerialization.data(withJSONObject:["status":"passed","analysedMoves":games*4,"playerDecisions":games*2,"resumeIdempotent":true,"manualAndBackgroundPause":true,"drills":drills.count,"report":report],options:[.sortedKeys,.prettyPrinted])
    print(String(data:data,encoding:.utf8)!);return
   }
   precondition(status["status"] as? String != "failed",String(describing:status))
   try await Task.sleep(for:.seconds(1))
  }
  fatalError("Timed out")
 }
}
