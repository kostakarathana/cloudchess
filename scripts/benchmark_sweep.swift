import Foundation
import CryptoKit
@main struct Sweep {
 static func main() async throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),resources=root.appendingPathComponent("CloudChess/EngineResources")
  let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:resources.appendingPathComponent("puzzles.json")))
  var coach=AdaptivePuzzleCoach();coach.begin(bank[0]);coach.finish()
  let prototype=coach.attempts[0]
  coach.attempts=(0..<2000).map {i in var a=prototype;a.id="attempt-\(i)";a.clean=i%3 != 0;a.kind=ChallengeKind.allCases[i%7];return a}
  coach.seen=bank.prefix(1800).map(\.id)
  for (i,tag) in Set(bank.flatMap(\.tags)).sorted().enumerated() {coach.skills[tag]=PuzzleAbility(mean:Double(i%17-8)*20,variance:Double(3000+i%7*1000),evidence:i%13)}
  var timings:[String:Double]=[:],selection:[String]=[],starts:[String]=[],ratings:[Double]=[]
  func now()->Double {ProcessInfo.processInfo.systemUptime}
  var t=now()
  for _ in 0..<30 {selection += coach.candidates(bank).map(\.id)}
  timings["selectionMs"]=(now()-t)*1000/30
  t=now();let entries=try await CertifiedChallengeBank.shared.load();timings["archiveColdMs"]=(now()-t)*1000
  precondition(!entries.isEmpty)
  t=now()
  for i in 0..<60 {
   let kind:ChallengeKind=i%2==0 ? .finish:.tenMoves
   let p=try await CertifiedChallengeBank.shared.select(kind,rating:Double(900+i%9*175),seed:UInt64(i*7919),opponent:1300,learner:1500,target:0.67,bounds:400...2200,excluding:[],avoiding:[])!
   let e=ChallengeEngine.cached(initial:p.fen,moves:[],multipv:3)!
   precondition(e.nodes>=ChallengeEngine.nodes)
   starts.append(p.id);ratings += [p.rating,p.calibrationOpponent ?? 0]+(p.successLogits ?? [])
  }
  timings["certifiedSelectMs"]=(now()-t)*1000/60
  t=now()
  for i in 0..<120 {
   let entry=entries[i%min(entries.count,12)]
   let p=try ModeDifficulty.calibrated(entry.puzzle,response:entry.response,opponent:Double(400+i%37*50))
   let q=try ModeDifficulty.tuneOpponent(p,learner:Double(500+i%19*100),target:0.67,bounds:100...3000,preferred:1300)
   ratings += [q.rating,q.calibrationOpponent ?? 0]+(q.successLogits ?? [])
  }
  timings["tuneOpponentMs"]=(now()-t)*1000/120
  t=now()
  for i in 0..<3000 {
   let entry=entries[i%entries.count]
   try NativeChess.retainCertifiedStart(entry.response,initial:entry.puzzle.fen)
   precondition(ChallengeEngine.cached(initial:entry.puzzle.fen,moves:[],multipv:3) != nil)
  }
  timings["cacheRoundtripMs"]=(now()-t)*1000/3000
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID())")
  defer{try? FileManager.default.removeItem(at:temp)}
  let store=PuzzleCoachStore(url:temp.appendingPathComponent("coach.json"))
  t=now()
  for _ in 0..<20 {try store.save(coach);let loaded=try store.load();precondition(loaded.attempts.count==2000 && loaded.scoring?.total==coach.scoring?.total)}
  timings["saveLoadMs"]=(now()-t)*1000/20
  let evidence=try JSONSerialization.data(withJSONObject:["selection":selection,"starts":starts,"ratings":ratings],options:.sortedKeys)
  let digest=SHA256.hash(data:evidence).map{String(format:"%02x",$0)}.joined()
  print(String(data:try JSONSerialization.data(withJSONObject:["timings":timings,"evidence":digest,"entries":entries.count],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
