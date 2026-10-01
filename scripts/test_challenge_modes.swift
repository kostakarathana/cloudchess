import Foundation
@main struct Tests {
 static func main() throws {
  var checks=0
  func check(_ x:Bool,_ message:String) {precondition(x,message);checks+=1}
  let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:"CloudChess/CloudChess/EngineResources/puzzles.json")))
  let p=bank[0]
  for rating in stride(from:400.0,through:3000,by:13) {
   for mistakes in 0...12 {for retry in [false,true] {for extra in [0.0,0.5,1.75] {
    let v=pow(rating,1.5)
    let d=ChallengeScore.delta(rating:rating,mistakes:mistakes,retry:retry,success:true,extraPenalty:extra)
    check(abs(d-v*((retry ? 0.5:1)-Double(mistakes)/4-extra))<0.000001,"Rewards and mistake/skip penalties")
    var s=PuzzleSession(puzzle:p);s.puzzle.rating=rating;s.mistakes=mistakes;s.extraPenalty=extra;s.reattempt=retry
    var score=ChallengeScore(total:1000);score.settle(s,success:true)
    check(score.total>=0,"Score never goes negative")
    check(abs(score.total-(max(0,1000-v*(Double(mistakes)/4+extra))+v*(retry ? 0.5:1)))<0.000001,"Penalties floor before reward; no hidden negative balance")
    let saved=score.total;score.settle(s,success:true);check(score.total==saved,"Idempotent settlement")
   }}}
  }
  for kind in ChallengeKind.allCases {
   var session=PuzzleSession(puzzle:p);session.puzzle.challengeType=kind.rawValue;session.mistakes=2
   var score=ChallengeScore();score.settle(session,success:true)
   check(score.total==ChallengeScore.value(rating:p.rating,kind:kind),"Success at zero earns the full value in every mode")
  }
  for kind in ChallengeKind.allCases {for rating in stride(from:400.0,through:3000,by:200) {for retry in [false,true] {
   var session=PuzzleSession(puzzle:p);session.puzzle.rating=rating;session.puzzle.challengeType=kind.rawValue;session.reattempt=retry
   let original=ChallengeScore.value(rating:rating,kind:kind)*(retry ? 0.5:1)
   for count in 1...20 {
    session.moves=["a1a2","b1b2","a2a3","b2b3"]
    check(session.undoLastDecision(),"A played turn can be undone")
    check(session.moves==["a1a2","b1b2"],"Undo removes last player decision and reply only")
    check(abs(session.reward-original*pow(0.8,Double(count)))<0.000001,"Every undo reduces remaining reward by 20 percent")
    session=try JSONDecoder().decode(PuzzleSession.self,from:JSONEncoder().encode(session))
    check(session.undoCount==count,"Undo discount survives persistence")
    var score=ChallengeScore();score.settle(session,success:true)
    check(abs(score.total-session.reward)<0.000001,"Settlement pays the reduced reward")
   }
  }}}
  var undo=PuzzleSession(puzzle:p)
  check(!undo.undoLastDecision() && undo.undoCount==nil,"An empty history is a no-op")
  undo.moves=["a1a2"];undo.mistakes=2;undo.extraPenalty=0.5
  check(undo.undoLastDecision() && undo.moves.isEmpty,"A final move without a reply removes one ply")
  check(undo.mistakes==2 && undo.extraPenalty==0.5,"Undo cannot erase unsettled mistake evidence")
  undo.moves=["a1a2","b1b2"];undo.recorded=true;undo.succeeded=false;let oldID=undo.id
  check(undo.undoLastDecision() && undo.id != oldID && !undo.recorded,"Failed settled attempt receives a fresh settlement identity")
  check(undo.mistakes==0 && undo.extraPenalty==nil && undo.undoCount==2,"Already settled penalties do not get charged twice; discount persists")
  undo.moves=["a1a2"];undo.succeeded=true
  check(!undo.undoLastDecision(),"A completed success cannot be rewound for duplicate rewards")
  var oldSession=try JSONSerialization.jsonObject(with:JSONEncoder().encode(undo)) as! [String:Any];oldSession.removeValue(forKey:"undoCount")
  let migrated=try JSONDecoder().decode(PuzzleSession.self,from:JSONSerialization.data(withJSONObject:oldSession))
  check(migrated.undoCount==nil && migrated.reward==ChallengeScore.value(rating:p.rating),"Old sessions have no invented undo discount")
  // Attempts are scoped to one puzzle; correct play/undo never replenishes them.
  for kind in ChallengeKind.allCases {for count in 0...12 {
   var c=AdaptivePuzzleCoach();var q=p;q.challengeType=kind.rawValue;c.begin(q)
   for i in 0..<count {let failed=c.mistakenMove();check(failed == (kind.usesHearts && i>=2),"Three attempts only in finite drills")}
   c=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(c))
   check(c.remainingHearts == (kind.usesHearts ? max(0,3-count):0),"Puzzle attempts persist")
   let before=c.session!.mistakes
   c.session?.moves=["a1a2","b1b2"];_ = c.session?.undoLastDecision()
   check(c.session!.mistakes==before,"Undo cannot replenish attempts")
   c.begin(q);check(c.remainingHearts == (kind.usesHearts ? 3:0),"Fresh puzzle resets attempts")
  }}
  // Different event orders, zero-floor and lifetime maximum across settled puzzles.
  for seed in 0..<1000 {
   var score=ChallengeScore(total:Double(seed*1700),best:Double(seed*1700)),high=score.best
   for i in 0..<20 {
    var s=PuzzleSession(puzzle:p);s.puzzle.challengeType=ChallengeKind.allCases[i%5].rawValue
    s.mistakes=(seed+i)%3;s.extraPenalty=i%3==0 ? 0.5:(i%3==1 ? 2:0)
    let before=score.total,penalty=ChallengeScore.penalty(s),success=i%3==2
    score.settle(s,success:success)
    check(abs(score.total-(max(0,before-penalty)+(success ? s.reward:0)))<0.00001,"Penalty floors before new reward")
    high=max(high,score.total);check(score.best==high,"All-time high never falls or resets")
    let once=score.total;score.settle(s,success:success);check(score.total==once,"No repeated penalty or reward")
   }
  }
  for rating in stride(from:300.0,through:3200,by:10) {
   check((3...5).contains(OpeningJudgement.moves(rating:rating)),"Opening drill lasts 3–5 moves")
   for best in stride(from:-1000.0,through:1000,by:25) {for loss in [-200.0,0,25,60,100,101,200,1000] {
    check(OpeningJudgement.punishes(best:best,played:best-loss)==(loss>100),"Only substantial CP losses reject an alternative")
   }}
  }
  var c=AdaptivePuzzleCoach();c.begin(p);c.session?.elapsed=1_000_000
  c.finish();check(c.scoring!.total==ChallengeScore.value(rating:p.rating),"Time never affects score")
  let saved=c.scoring!.total;check(!c.finish() && c.scoring!.total==saved,"No duplicate reward")
  c.begin(p);c.finish();check(c.scoring!.total==saved*1.5,"Retries pay half")
  var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as! [String:Any]
  legacy.removeValue(forKey:"hearts");legacy.removeValue(forKey:"introductions")
  let restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONSerialization.data(withJSONObject:legacy))
  check(restored.remainingHearts==3 && restored.total==c.total,"Legacy migration preserves progress")
  var a=PuzzleSession(puzzle:p);a.puzzle.mate=1
  var b=a;b.puzzle.mate=4;b.puzzle.columns=5
  check(a.instructionType==b.instructionType,"Mate type independent of distance/shape")
  b.puzzle.mate=0;check(a.instructionType != b.instructionType,"Material type separate")
  for kind in ChallengeKind.allCases {var q=p;q.challengeType=kind.rawValue;check(q.kind==kind,"Mode decoding")}
  print("{\"status\":\"passed\",\"checks\":\(checks)}")
 }
}
