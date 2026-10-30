import Foundation
/// Offline profile-import regression. Provider bodies are served from a
/// generated fixture directory through ProfileFixtureProtocol, so the real
/// URLSession, checkpoint, pause/resume and report pipeline run without a
/// network. Engine analysis uses the shipping full-strength budgets.
@main struct ProfileImportRegression {
 static let service=OnDeviceProfiles.shared
 static func write(_ path:URL,_ text:String)throws {try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try text.write(to:path,atomically:true,encoding:.utf8)}
 static func json(_ value:Any)->String {String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)!}
 static func pgn(_ white:String,_ black:String,_ result:String,_ moves:String,date:String)->String {
  "[White \"\(white)\"]\n[Black \"\(black)\"]\n[Result \"\(result)\"]\n[WhiteElo \"1200\"]\n[BlackElo \"1300\"]\n[TimeControl \"180+2\"]\n[UTCDate \"\(date)\"]\n\n\(moves) \(result)"
 }
 static func status(_ id:String)async throws->[String:Any] {try await service.status(id)}
 static func wait(_ seconds:Double,_ what:String,_ condition:([String:Any])->Bool,_ id:String)async throws->[String:Any] {
  let deadline=Date().addingTimeInterval(seconds)
  while Date()<deadline {
   let s=try await status(id);if condition(s){return s}
   precondition(s["status"] as? String != "failed","Job failed while waiting for \(what): \(s["error"] ?? "")")
   try await Task.sleep(for:.milliseconds(20))
  }
  fatalError("Timed out waiting for \(what)")
 }
 static func startWhenFree(_ link:String,limit:Int?=nil)async throws->String {
  for _ in 0..<200 {
   do {return try await service.start(link,limit:limit)["id"] as! String}
   catch {try await Task.sleep(for:.milliseconds(50))}
  }
  fatalError("Service never became free")
 }
 static func main() async throws {
  var checks=0
  let fixtures=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CC_PROFILE_FIXTURE_DIR"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("cc-profile-fixtures-"+UUID().uuidString).path)
  setenv("CC_PROFILE_FIXTURE_DIR",fixtures.path,1)
  precondition(ProfileFixtureProtocol.directory==fixtures.path)
  let foolsMate=pgn("Opp","tester","0-1","1. f3 e5 2. g4 Qh4#",date:"2026.10.01")
  let scholarsMate=pgn("tester","Opp","1-0","1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7#",date:"2026.09.01")
  // Chess.com "tester": 8 months x 20 raw games; two valid games, the rest skipped.
  let chessRoot="https://api.chess.com/pub/player/tester/games/"
  let months=["2026/10","2026/09","2026/08","2026/07","2026/06","2026/05","2026/04","2026/03"]
  try write(fixtures.appendingPathComponent("api.chess.com/pub/player/tester/games/archives"),json(["archives":months.map{chessRoot+$0}]))
  for (m,month) in months.enumerated() {
   var games:[[String:Any]]=[]
   for g in 0..<20 {
    var game:[String:Any]=["rules":"chess","time_class":"blitz","rated":true,"end_time":1_790_000_000-Double(m*2_600_000+g*3600),"url":"https://www.chess.com/game/live/\(m)\(g)","uuid":"tester-\(month)-\(g)"]
    if g==0,m==0 {game["pgn"]=foolsMate} else if g==0,m==1 {game["pgn"]=scholarsMate}
    games.append(game)
   }
   try write(fixtures.appendingPathComponent("api.chess.com/pub/player/tester/games/"+month),json(["games":games]))
  }
  // Chess.com "sparse": 8 months x 5 skipped games exercises the month cap.
  try write(fixtures.appendingPathComponent("api.chess.com/pub/player/sparse/games/archives"),json(["archives":months.map{"https://api.chess.com/pub/player/sparse/games/"+$0}]))
  for month in months {try write(fixtures.appendingPathComponent("api.chess.com/pub/player/sparse/games/"+month),json(["games":Array(repeating:["rules":"chess"],count:5)]))}
  // Chess.com "big": one ~2 MB archive with one valid game guards fetch speed.
  try write(fixtures.appendingPathComponent("api.chess.com/pub/player/big/games/archives"),json(["archives":["https://api.chess.com/pub/player/big/games/2026/10"]]))
  var bigGame:[String:Any]=["rules":"chess","time_class":"blitz","rated":true,"end_time":1_790_000_000.0,"url":"https://www.chess.com/game/live/big","uuid":"big-1","pgn":pgn("Opp","big","0-1","1. f3 e5 2. g4 Qh4#",date:"2026.10.01")]
  bigGame["padding"]=String(repeating:"x",count:2_100_000)
  try write(fixtures.appendingPathComponent("api.chess.com/pub/player/big/games/2026/10"),json(["games":[bigGame]]))
  // Lichess "streamer": 100 skipped games newest first.
  let lichessLines=(0..<100).map{i in json(["id":"li\(i)","rated":true,"variant":"standard","speed":"blitz","lastMoveAt":1_790_000_000_000.0-Double(i)*86_400_000])}
  try write(fixtures.appendingPathComponent("lichess.org/api/games/user/streamer"),lichessLines.joined(separator:"\n")+"\n")

  // 1. First import is capped at initialImportGames, newest archives first,
  //    and a pause mid-import does not refetch imported archives on resume.
  ProfileFixtureProtocol.configure(stall:0.3)
  let a=try await startWhenFree("https://www.chess.com/member/tester")
  _=try await wait(30,"first archive checkpoint",{(($0["importCheckpoint"] as? [String:Any])?["archives"] as? [String])?.count==1},a)
  await service.pause(userInitiated:true)
  _=try await wait(30,"cancelled",{$0["status"] as? String=="cancelled"},a)
  precondition(ProfileFixtureProtocol.requests.filter{$0==chessRoot+"2026/10"}.count==1);checks+=1
  let stayPaused=try await service.upgradeIfNeeded(a);precondition(stayPaused["status"] as? String=="cancelled","User pause stays paused");checks+=1
  _=try await service.resume(a)
  let imported=try await wait(60,"import complete",{$0["importComplete"] as? Bool==true},a)
  precondition(ProfileFixtureProtocol.requests.filter{$0==chessRoot+"2026/10"}.count==1,"Imported archive refetched after resume");checks+=1
  precondition(imported["received"] as? Int==OnDeviceProfiles.initialImportGames,"Game cap: \(imported["received"] ?? "nil")");checks+=1
  precondition(((imported["importCheckpoint"] as? [String:Any])?["archives"] as? [String])==[chessRoot+"2026/10",chessRoot+"2026/09",chessRoot+"2026/08"],"Newest three archives only");checks+=1
  precondition(!ProfileFixtureProtocol.requests.contains(chessRoot+"2026/07"),"No archive beyond the cap");checks+=1
  precondition(imported["limited"] as? Bool==true);checks+=1
  // Interim report right after import, before any game is analysed.
  let afterImport=try await service.report(a),coverage0=afterImport["coverage"] as! [String:Any]
  precondition(coverage0["importedGames"] as? Int==2 && coverage0["analysedGames"] as? Int==0);checks+=1
  precondition((afterImport["import"] as! [String:Any])["limited"] as? Bool==true);checks+=1
  // 2. Interim report after the first analysed game while status stays analysing.
  let firstGame=try await wait(900,"first analysed game",{($0["analysedGames"] as? Int ?? 0)>=1},a)
  precondition(firstGame["status"] as? String=="analysing");checks+=1
  let interim=try await service.report(a),coverage1=interim["coverage"] as! [String:Any]
  precondition(coverage1["analysedGames"] as? Int==1 && coverage1["importedGames"] as? Int==2,"Interim coverage \(coverage1)");checks+=1
  precondition(interim["version"] as? String==firstGame["config"] as? String);checks+=1
  // 3. Inactivity must not cancel the running Task; only background or user pause does.
  await service.pause(userInitiated:false,background:false)
  try await Task.sleep(for:.seconds(1))
  let stillRunning=try await status(a);precondition(stillRunning["status"] as? String=="analysing","Inactive scene phase cancelled the job");checks+=1
  _=try await service.cancel(a)
  _=try await wait(30,"cancelled after user pause",{$0["status"] as? String=="cancelled"},a)
  let pausedA=try await status(a)
  precondition(pausedA["userPaused"] as? Bool==true);checks+=1
  precondition(pausedA["report"] is String,"Interim report survives a pause");checks+=1

  // 4. Month cap for a thin account.
  ProfileFixtureProtocol.configure()
  let b=try await startWhenFree("https://www.chess.com/member/sparse")
  let sparse=try await wait(60,"sparse import",{$0["importComplete"] as? Bool==true},b)
  precondition(((sparse["importCheckpoint"] as? [String:Any])?["archives"] as? [String])?.count==OnDeviceProfiles.initialImportMonths,"Month cap");checks+=1
  precondition(sparse["received"] as? Int==5*OnDeviceProfiles.initialImportMonths && sparse["limited"] as? Bool==true);checks+=1
  _=try await wait(60,"sparse completion",{$0["status"] as? String=="completed"},b)

  // 5. Whole-body JSON fetch: a 2 MB archive must import in well under half a second.
  ProfileFixtureProtocol.resetLog()
  let bigStart=Date()
  let c=try await startWhenFree("https://www.chess.com/member/big",limit:1)
  _=try await wait(10,"big import",{$0["importComplete"] as? Bool==true},c)
  let bigSeconds=Date().timeIntervalSince(bigStart)
  precondition(bigSeconds<0.5,"2 MB archive took \(bigSeconds)s");checks+=1
  _=try await service.cancel(c);_=try await wait(30,"big settled",{["cancelled","completed"].contains($0["status"] as? String ?? "")},c)

  // 6. Lichess: max carries the cap, a mid-stream pause checkpoints the oldest
  //    game, and resume continues with until/max instead of refetching.
  ProfileFixtureProtocol.resetLog();ProfileFixtureProtocol.configure(chunk:(lines:10,delay:0.3))
  let d=try await startWhenFree("https://lichess.org/@/streamer")
  let mid=try await wait(30,"lichess checkpoint",{(($0["importCheckpoint"] as? [String:Any])?["received"] as? Int ?? 0)>=20},d)
  await service.pause(userInitiated:true)
  _=try await wait(30,"lichess cancelled",{$0["status"] as? String=="cancelled"},d)
  let checkpoint=try await status(d)["importCheckpoint"] as! [String:Any]
  let seen=checkpoint["received"] as! Int,oldest=checkpoint["oldest"] as! Double
  precondition(seen>=20 && seen%10==0 && oldest<1_790_000_000_000);checks+=1
  let first=ProfileFixtureProtocol.requests.first{$0.contains("lichess.org")}!
  precondition(first.contains("max=\(OnDeviceProfiles.initialImportGames)") && !first.contains("until="));checks+=1
  _=try await service.resume(d)
  let lichess=try await wait(60,"lichess import",{$0["importComplete"] as? Bool==true},d)
  let lichessRequests=ProfileFixtureProtocol.requests.filter{$0.contains("lichess.org")}
  precondition(lichessRequests.count==2,"\(lichessRequests)");checks+=1
  precondition(lichessRequests[1].contains("until=\(Int64(oldest)-1)") && lichessRequests[1].contains("max=\(OnDeviceProfiles.initialImportGames-seen)"),lichessRequests[1]);checks+=1
  precondition(lichess["received"] as? Int==OnDeviceProfiles.initialImportGames && lichess["limited"] as? Bool==true,"\(lichess["received"] ?? "nil")");checks+=1
  _=try await wait(60,"lichess completion",{$0["status"] as? String=="completed"},d)
  let report=try await service.report(d)
  precondition((report["import"] as! [String:Any])["received"] as? Int==OnDeviceProfiles.initialImportGames);checks+=1
  let result:[String:Any]=["status":"passed","checks":checks,"initialImportGames":OnDeviceProfiles.initialImportGames,"initialImportMonths":OnDeviceProfiles.initialImportMonths,"twoMegabyteArchiveSeconds":bigSeconds,"lichessResumeRequest":lichessRequests[1],"interimCoverage":coverage1,"scope":"Offline fixtures through ProfileFixtureProtocol; full 2M/4M analysis budgets on the development Mac."]
  print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
