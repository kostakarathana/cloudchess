import Foundation
@main struct Test {
 static func main() async throws {
  let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  var logs:[[String:Any]]=[]
  for seed:UInt64 in [71,218] {
   let p=try await ChallengeEngine.generated(.tenMoves,rating:1300,seed:seed)
   precondition(abs(p.initialEvaluation!)<=10)
   var moves:[String]=[]
   var state=try await ChallengeEngine.state(p,moves:[])
   for _ in 0..<10 {
    if state["result"] is String {break}
    let (_,e)=try await ChallengeEngine.evaluate(initial:p.fen,moves:moves)
    moves.append(e.line[0]);state=try await ChallengeEngine.state(p,moves:moves)
    if state["result"] is String {break}
    moves.append(try await ChallengeEngine.opponent(initial:p.fen,moves:moves,elo:1300))
    state=try await ChallengeEngine.state(p,moves:moves)
   }
   let (_,e)=try await ChallengeEngine.evaluate(initial:p.fen,moves:moves)
   let final=e.forSolver(turn:state["turn"] as! String,white:p.white)
   precondition(moves.count==20 || state["result"] is String)
   logs.append(["kind":"tenMoves","initial":p.fen,"startCP":p.initialEvaluation!,"finalCP":final,"moves":moves,"result":state["result"]!])
   FileHandle.standardError.write(Data("Ten-move playthrough: \(moves.count) plies, \(p.initialEvaluation!) → \(final)\n".utf8))
  }
  for white in [true,false] {
   let p=bank.first{$0.kind == .finish && $0.white==white}!
   var moves:[String]=[],state=try await ChallengeEngine.state(p,moves:[])
   for _ in 0..<120 {
    if state["result"] is String {break}
    let move:String
    if (state["turn"] as! String)==(white ? "white":"black") {move=try await ChallengeEngine.evaluate(initial:p.fen,moves:moves).1.line[0]}
    else {move=try await ChallengeEngine.opponent(initial:p.fen,moves:moves,elo:1150)}
    moves.append(move);state=try await ChallengeEngine.state(p,moves:moves)
   }
   precondition(state["result"] is String,"Must actually finish the game")
   precondition(state["result"] as? String==(white ? "White wins":"Black wins"),"Strong side converts")
   logs.append(["kind":"finish","initial":p.fen,"moves":moves,"result":state["result"]!])
   FileHandle.standardError.write(Data("Conversion: \(moves.count) plies, \(state["result"]!)\n".utf8))
  }
  print(String(data:try JSONSerialization.data(withJSONObject:["status":"passed","games":logs],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
