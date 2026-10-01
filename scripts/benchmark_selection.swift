import Foundation
@main struct Bench {
 static func main() throws {
  let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  var coach=AdaptivePuzzleCoach();coach.begin(bank[0]);coach.finish()
  let prototype=coach.attempts[0]
  coach.attempts=(0..<2000).map {i in var a=prototype;a.id="attempt-\(i)";a.clean=i%3 != 0;a.kind=ChallengeKind.allCases[i%5];return a}
  var ids:[String]=[];let start=ProcessInfo.processInfo.systemUptime
  for _ in 0..<10 {ids+=coach.candidates(bank).map{$0.id}}
  let result:[String:Any]=["seconds":ProcessInfo.processInfo.systemUptime-start,"selections":10,"history":2000,"ids":ids]
  print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
 }
}
