import Foundation
@main struct Test {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),decoder=JSONDecoder()
  func data(_ p:String)throws->Data {try Data(contentsOf:root.appendingPathComponent(p))}
  let model=try decoder.decode(ModeDifficulty.Model.self,from:data("CloudChess/EngineResources/mode-difficulty-v3.json"))
  let probes=try JSONSerialization.jsonObject(with:data("training/mode-v3-parity.json")) as! [[String:Any]]
  let bank=try decoder.decode([TrainingPuzzle].self,from:data("CloudChess/EngineResources/puzzles.json"))
  var checks=0
  func check(_ b:Bool,_ note:String){checks+=1;precondition(b,note)}
  for row in probes {
   let x=row["features"] as! [Double],expected=row["logit"] as! Double
   check(abs(model.raw(x)-expected)<1e-10,"Exported forest equals independent sklearn predictions")
   var features=Array(x.dropLast());if features[1]==1 {features[14]=0.6};var previous = -Double.infinity
   var p=bank[0];p.challengeType=row["kind"] as? String;p.fen=row["fen"] as! String;p.difficultyFeatures=features
   let measured=try ModeDifficulty.rerated(p,opponent:features[16]*1000)
   for level in stride(from:400.0,through:3000,by:25) {
    let logit=model.logit(features,at:level)
    check(logit>=previous-1e-10,"Skill cannot reduce predicted success");previous=logit
    check(abs(logit-measured.successLogit(at:level)!)<1e-10,"Coach uses measured success curve")
   }
   if !p.kind.usesHearts {
    var easier=try ModeDifficulty.rerated(p,opponent:300)
    for opponent in stride(from:400.0,through:2600,by:100) {
     let harder=try ModeDifficulty.rerated(p,opponent:opponent)
     check(harder.rating>=easier.rating,"Stronger opponent cannot make the puzzle easier")
     easier=harder
    }
   }
   var untrusted=p;untrusted.rating=400;let low=try ModeDifficulty.rerated(untrusted,opponent:features[16]*1000)
   untrusted.rating=3000;let high=try ModeDifficulty.rerated(untrusted,opponent:features[16]*1000)
   check(low.rating==high.rating,"Source or learner rating cannot inflate points")
   check(ChallengeScore.value(rating:low.rating,kind:p.kind)==ChallengeScore.value(rating:high.rating,kind:p.kind),"Identical challenge has identical value")
   let encoded=try JSONEncoder().encode(measured),restored=try decoder.decode(TrainingPuzzle.self,from:encoded)
   check(restored.rating==measured.rating && restored.successLogits==measured.successLogits,"Calibration survives relaunch")
  }
  let features=try JSONSerialization.jsonObject(with:data("training/mode-v3-feature-parity.json")) as! [[String:Any]]
  for row in features {
   let kind=ChallengeKind(rawValue:row["kind"] as! String)!,fen=row["fen"] as! String,response=row["response"] as! [String:Any]
   let actual=try ModeDifficulty.features(fen:fen,kind:kind,turns:row["turns"] as! Int,response:response,opponent:row["opponent"] as! Double)
   let expected=row["features"] as! [Double]
   for (a,b) in zip(actual,expected){check(abs(a-b)<1e-10,"Swift geometry/tactical features match python-chess")}
   var limited=response;limited["limitedStrength"]=true
   do {_ = try ModeDifficulty.features(fen:fen,kind:kind,turns:3,response:limited,opponent:0);fatalError("Weak bot cannot rate a puzzle")} catch {checks+=1}
  }
  let starts=try decoder.decode([TrainingPuzzle].self,from:data("CloudChess/EngineResources/challenge-starts.json"))
  for p in starts {check(p.difficultyVersion==ModeDifficulty.version && p.difficultyFeatures?.count==17,"Every open seed has measured evidence")}
  for p in starts {
   for learner in [600.0,1100,1800,2600] {
    let tuned=try ModeDifficulty.tuneOpponent(p,learner:learner,target:0.67,bounds:100...3000,preferred:1100)
    let error=abs(tuned.successLogit(at:learner)!-log(0.67/0.33))
    for opponent in stride(from:100.0,through:3000,by:100) {
     let alternative=try ModeDifficulty.rerated(p,opponent:opponent)
     check(error<=abs(alternative.successLogit(at:learner)!-log(0.67/0.33))+0.025,"Opponent matches target at least as well as the strength grid")
    }
   }
  }
  var learner=AdaptivePuzzleCoach()
  learner.begin(starts[0]);learner.session?.extraPenalty=2;learner.finish(skipped:true)
  let old=learner.previousOpponents![starts[0].kind.rawValue]!,lossRange=learner.opponentBounds(for:starts[0].kind)
  check(lossRange.upperBound<old || old==100,"A loss lowers the next bot")
  learner.begin(starts[0]);learner.finish()
  let winRange=learner.opponentBounds(for:starts[0].kind)
  check(winRange.lowerBound>old || old==3000,"Mastery raises the next bot")
  let book=try JSONSerialization.jsonObject(with:data("CloudChess/EngineResources/opening-book.json")) as! [String:Any]
  for p in book["starts"] as! [[String:Any]] {
   let r=p["ratingsByMoves"] as! [String:Double]
   check(r.count==3 && r["3"]!<=r["4"]! && r["4"]!<=r["5"]!,"Longer opening drill is never easier")
  }
  print("{\"status\":\"passed\",\"checks\":\(checks),\"heldoutParityRows\":\(probes.count),\"independentFeaturePositions\":\(features.count)}")
 }
}
