import Foundation
@main struct Test {
 static func main() {
  var checks=0
  func check(_ b:Bool,_ note:String){checks+=1;precondition(b,note)}
  for rate in [30,60,120] {
   for gate in 0...10 {
    var p=KingDominoPhysics()
    for _ in 0..<(rate*12) {
     p.advance(seconds:1.0/Double(rate),completed:gate)
     for i in 0..<10 {
      check(p.angles[i].isFinite && p.angles[i]>=0 && p.angles[i]<=Double.pi/2,"bounded angle")
      check(p.velocities[i].isFinite && abs(p.velocities[i])<8,"bounded energy")
      if i>=gate {check(p.angles[i]==0,"unfinished stage never falls")}
     }
    }
    if gate>0 {check(p.angles[gate-1]>0.3,"cascade reached completed stage")}
    if gate==10 {check(p.collisions==9,"all nine real neighboring contacts")}
    // An arbitrarily long generation pause must not strand the next domino.
    for _ in 0..<(rate*12) {p.advance(seconds:1.0/Double(rate),completed:10)}
    check(p.angles.allSatisfy{$0>0.3},"cascade resumes")
   }
  }
  var a=KingDominoPhysics(),b=KingDominoPhysics()
  for _ in 0..<300 {a.advance(seconds:1.0/30,completed:10)}
  for _ in 0..<600 {b.advance(seconds:1.0/60,completed:10)}
  for i in 0..<10 {check(abs(a.angles[i]-b.angles[i])<1e-8,"frame rate independent")}
  print("{\"status\":\"passed\",\"checks\":\(checks),\"contacts\":\(a.collisions),\"angles\":\(a.angles)}")
 }
}
