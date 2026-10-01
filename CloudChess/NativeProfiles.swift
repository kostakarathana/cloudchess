import Foundation
import SQLite3
import CryptoKit

private func profileError(_ text:String)->NSError {NSError(domain:"CloudChess.Profile",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
private func jsonData(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])}
private func jsonObject(_ data:Data)throws->[String:Any] {guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw profileError("Invalid archive response")};return result}
extension SHA256.Digest {
    /// Same lowercase digest bytes as %02x, without 32 locale/formatter calls.
    var chessHex:String {
        let alphabet=Array("0123456789abcdef".utf8)
        var bytes=[UInt8]();bytes.reserveCapacity(64)
        for byte in self {bytes.append(alphabet[Int(byte>>4)]);bytes.append(alphabet[Int(byte&15)])}
        return String(decoding:bytes,as:UTF8.self)
    }
}
private func fingerprint(_ value:Any)throws->String {SHA256.hash(data:try jsonData(value)).chessHex}

enum ChessProfileProvider:String,CaseIterable {
    case chesscom,lichess
    var title:String {self == .chesscom ? "Chess.com":"Lichess"}
    func profileURL(username:String)->URL? {
        let name=username.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.utf8.count<=64,
              name.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45 || $0==95}) else{return nil}
        return URL(string:(self == .chesscom ? "https://www.chess.com/member/":"https://lichess.org/@/")+name)
    }
}

/// Reusable full-strength evidence, never game state or limited-strength replies.
/// Disk access happens exclusively on engine worker queues; cache failure is a miss.
/// Bump this namespace whenever the bridge, search policy or NNUE changes.
enum PersistentChessEvidence {
    static let namespace="sf19-nn1a298aa575a0-bridge14"
    private static let lock=NSLock()
    private static var writes=0
    private static var directory:URL? {
        #if DEBUG
        if let path=ProcessInfo.processInfo.environment["CC_EVIDENCE_CACHE"] {return URL(fileURLWithPath:path).appendingPathComponent(namespace)}
        if ProcessInfo.processInfo.arguments.contains("--uitesting") && !ProcessInfo.processInfo.arguments.contains("--evidence-audit") {return nil}
        #endif
        guard Bundle.main.bundleIdentifier != nil else{return nil}
        return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.appendingPathComponent("ChessEvidence/"+namespace,isDirectory:true)
    }
    static func eligible(_ request:[String:Any])->Bool {
        request["action"] as? String == "analyse" && (request["nodes"] as? Int ?? 0)>=2_000_000
    }
    static func load(_ key:String,request:[String:Any])->[String:Any]? {
        guard eligible(request),let directory else{return nil}
        lock.lock();defer{lock.unlock()}
        let url=directory.appendingPathComponent(key+".json")
        guard let data=try? Data(contentsOf:url),data.count<=131072,
              let record=try? jsonObject(data),record["key"] as? String==key,
              let result=record["result"] as? [String:Any],
              record["digest"] as? String == (try? fingerprint(result)),valid(result,request:request) else{return nil}
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)
        return result
    }
    static func valid(_ result:[String:Any],request:[String:Any])->Bool {
        guard eligible(request),result["error"]==nil,result["limitedStrength"] as? Bool != true,
              let rows=result["evaluations"] as? [[String:Any]],let row=rows.first,
              let pv=row["pv"] as? [String],!pv.isEmpty,
              (row["nodes"] as? Int ?? 0)>=(request["nodes"] as? Int ?? Int.max),
              (result["legal"] as? [String])?.contains(pv[0])==true else{return false}
        return true
    }
    static func store(_ result:[String:Any],key:String,request:[String:Any]) {
        guard valid(result,request:request),let directory,
              let digest=try? fingerprint(result),let data=try? jsonData(["key":key,"digest":digest,"result":result]),data.count<=131072 else{return}
        lock.lock();defer{lock.unlock()}
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try data.write(to:directory.appendingPathComponent(key+".json"),options:.atomic)
            writes+=1
            if writes==1 || writes%16==0 {
                let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])
                    .filter{$0.pathExtension=="json"}.sorted{a,b in
                        ((try? a.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                        ((try? b.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    }
                for file in files.dropFirst(256) {try? FileManager.default.removeItem(at:file)}
            }
        } catch { /* Storage pressure must never block play or weaken grading. */ }
    }
}

/// A single local engine queue prevents concurrent searches and keeps work off UI.
enum NativeChess {
    @TaskLocal static var backgroundEpoch:UInt64?
    private static let queue=DispatchQueue(label:"CloudChess.Stockfish",qos:.userInitiated)
    private static let backgroundQueue=DispatchQueue(label:"CloudChess.Preparation",qos:.utility)
    private static let stateQueue=DispatchQueue(label:"CloudChess.Position",qos:.userInitiated,attributes:.concurrent)
    private static let puzzleQueue=DispatchQueue(label:"CloudChess.PuzzleProof",qos:.userInitiated)
    private static let cache:NSCache<NSString,NSDictionary> = {let c=NSCache<NSString,NSDictionary>();c.countLimit=192;c.totalCostLimit=8*1024*1024;return c}()
    private static let activityLock=NSLock()
    private static var playing=false
    static var gameplayActive:Bool {activityLock.lock();defer{activityLock.unlock()};return playing}
    static func setGameplayActive(_ active:Bool) {
        activityLock.lock();let becameActive=active && !playing;playing=active;activityLock.unlock()
        if becameActive {CCStopBackground()}
    }
    /// Imported-game analysis yields to live play rather than occupying the
    /// foreground Stockfish queue. Cancellation retries from the saved move.
    static func profileCall(_ request:[String:Any]) async throws->[String:Any] {
        while true {
            try Task.checkCancellation()
            while gameplayActive {try await Task.sleep(nanoseconds:250_000_000)}
            let epoch=CCBackgroundEpoch()
            do {return try await $backgroundEpoch.withValue(epoch) {try await call(request)}}
            catch is CancellationError {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds:150_000_000)
            }
        }
    }
    // Mutable flight fields are exclusively protected by flightLock.
    private final class Flight: @unchecked Sendable {
        let request:[String:Any],epoch:UInt64?
        var started=false
        var waiters:[CheckedContinuation<[String:Any],Error>]=[]
        init(_ request:[String:Any],epoch:UInt64?) {self.request=request;self.epoch=epoch}
    }
    private static let flightLock=NSLock()
    private static var flights:[String:Flight]=[:]
    private static var activeBackground:String?
    private static var searchesExecuted=0,cacheHits=0,joinedSearches=0,preservedSearches=0,diskHits=0
    static var searchMetrics:[String:Int] {
        flightLock.lock();defer{flightLock.unlock()}
        return ["executed":searchesExecuted,"cacheHits":cacheHits,"joined":joinedSearches,"preserved":preservedSearches,"diskHits":diskHits,"inFlight":flights.count]
    }
    /// Cancel unrelated speculation immediately. A running exact-position search
    /// needed by this pickup/drop may finish and be adopted by its foreground call.
    static func cancelPreparation(keeping:(([String:Any])->Bool)?=nil) {
        flightLock.lock();defer{flightLock.unlock()}
        if let key=activeBackground,let flight=flights[key],flight.epoch==CCBackgroundEpoch(),let keeping,keeping(flight.request) {
            preservedSearches+=1;return
        }
        CCStopBackground()
    }
    /// Read only: a finished exact-request result never interrupts useful pondering.
    static func cached(_ request:[String:Any])->[String:Any]? {
        guard let key=try? fingerprint(request) else{return nil}
        return cache.object(forKey:key as NSString) as? [String:Any]
    }
    /// Only used by the audited bundled archive. Retain the exact response under
    /// its exact request; never alias MultiPV, histories or search budgets.
    static func retainCertifiedStart(_ result:[String:Any],initial:String) throws {
        let request=ChallengeEngine.request(initial:initial,moves:[],multipv:3)
        guard result["fen"] as? String==initial,result["result"] is NSNull,
              PersistentChessEvidence.valid(result,request:request) else {throw profileError("Invalid certified position")}
        let key=try fingerprint(request)
        cache.setObject(result as NSDictionary,forKey:key as NSString,cost:try jsonData(result).count)
    }
    static func call(_ request:[String:Any]) async throws -> [String:Any] {
        // An adopted background request can still be invalidated by suspension.
        // Retry it as foreground work; never grade from a partial search.
        while true {
            try Task.checkCancellation()
            do {return try await perform(request)}
            catch is CancellationError {
                try Task.checkCancellation()
                if backgroundEpoch != nil {throw CancellationError()}
            }
        }
    }
    private static func perform(_ request:[String:Any]) async throws -> [String:Any] {
        let epoch=backgroundEpoch
        if let epoch,epoch != CCBackgroundEpoch() {throw CancellationError()}
        let action=request["action"] as? String ?? "state"
        let positionOnly=action=="puzzle" && (request["operation"] as? String ?? "position")=="position"
        let searches=["puzzle","analyse","bot"].contains(action) && !positionOnly
        // Full history, objective, dimensions, budget, MultiPV and root are part
        // of identity. Limited-strength bot decisions are never shared or cached.
        let key = searches && action != "bot" ? try fingerprint(request):nil
        let value:[String:Any]=try await withCheckedThrowingContinuation {continuation in
            flightLock.lock()
            if let key,let hit=cache.object(forKey:key as NSString) {
                cacheHits+=1;flightLock.unlock();continuation.resume(returning:hit as! [String:Any]);return
            }
            if let key,let existing=flights[key],
               existing.epoch==nil || (existing.epoch==CCBackgroundEpoch() && (existing.started || epoch != nil)) {
                existing.waiters.append(continuation);joinedSearches+=1;flightLock.unlock();return
            }
            if searches && epoch==nil {CCStopBackground()}
            let flight=Flight(request,epoch:epoch);flight.waiters=[continuation]
            if let key {flights[key]=flight}
            flightLock.unlock()
            let worker = !searches ? stateQueue:(epoch != nil ? backgroundQueue:(action=="puzzle" ? puzzleQueue:queue))
            worker.async {
                var outcome:Result<[String:Any],Error>
                if let epoch,epoch != CCBackgroundEpoch() {outcome = .failure(CancellationError())}
                else if let key,let hit=PersistentChessEvidence.load(key,request:request) {
                    if let epoch,epoch != CCBackgroundEpoch() {outcome = .failure(CancellationError())}
                    else {
                        cache.setObject(hit as NSDictionary,forKey:key as NSString,cost:(try? jsonData(hit).count) ?? 16384)
                        flightLock.lock();diskHits+=1;flightLock.unlock()
                        outcome = .success(hit)
                    }
                }
                else {
                    flightLock.lock();flight.started=true
                    if searches {searchesExecuted+=1}
                    if epoch != nil,let key {activeBackground=key}
                    flightLock.unlock()
                    var input=request;if let epoch {input["_backgroundEpoch"]=epoch}
                    let path=Bundle.main.url(forResource:"nn-1a298aa575a0",withExtension:"nnue",subdirectory:"EngineResources")?.path ?? ProcessInfo.processInfo.environment["CC_NETWORK_PATH"] ?? ""
                    let result=CCChess(input,path) as! [String:Any]
                    if let epoch,epoch != CCBackgroundEpoch() {outcome = .failure(CancellationError())}
                    else if let error=result["error"] as? String {outcome = .failure(profileError(error))}
                    else {
                        if let key {cache.setObject(result as NSDictionary,forKey:key as NSString,cost:(try? jsonData(result).count) ?? 16384)}
                        if let key {PersistentChessEvidence.store(result,key:key,request:request)}
                        outcome = .success(result)
                    }
                }
                flightLock.lock()
                if let key,flights[key] === flight {flights.removeValue(forKey:key)}
                if let key,activeBackground==key {activeBackground=nil}
                let waiters=flight.waiters;flight.waiters=[]
                flightLock.unlock()
                for waiter in waiters {waiter.resume(with:outcome)}
            }
        }
        try Task.checkCancellation();return value
    }
}

/// Each game and each analysed decision commits independently. The job receipt,
/// raw evidence, fitted report and training priorities live in the app sandbox.
final class NativeProfileStore {
    private var db:OpaquePointer?
    init(url:URL)throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {throw profileError("Cannot open local analysis storage")}
        sqlite3_busy_timeout(db,10000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS documents(kind TEXT, id TEXT, account TEXT, stamp REAL, payload BLOB, PRIMARY KEY(kind,id))")
        try execute("CREATE INDEX IF NOT EXISTS account_documents ON documents(kind,account,stamp)")
    }
    deinit {sqlite3_close(db)}
    private func statement(_ sql:String,_ args:[Any])throws->OpaquePointer {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else {throw profileError("Local analysis query failed")}
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (i,value) in args.enumerated() {
            if let data=value as? Data {_ = data.withUnsafeBytes{sqlite3_bind_blob(stmt,Int32(i+1),$0.baseAddress,Int32(data.count),transient)}}
            else if let value=value as? Double {sqlite3_bind_double(stmt,Int32(i+1),value)}
            else {sqlite3_bind_text(stmt,Int32(i+1),String(describing:value),-1,transient)}
        }
        return stmt
    }
    private func execute(_ sql:String,_ args:[Any]=[])throws {
        let stmt=try statement(sql,args);defer{sqlite3_finalize(stmt)}
        let status=sqlite3_step(stmt);guard status==SQLITE_DONE || status==SQLITE_ROW else {throw profileError("Cannot save local analysis progress")}
    }
    func put(_ kind:String,_ id:String,_ account:String,_ value:[String:Any],stamp:Double=0)throws {
        try execute("INSERT OR REPLACE INTO documents VALUES (?,?,?,?,?)",[kind,id,account,stamp,try jsonData(value)])
    }
    func get(_ kind:String,_ id:String)throws->[String:Any]? {
        let stmt=try statement("SELECT payload FROM documents WHERE kind=? AND id=?",[kind,id]);defer{sqlite3_finalize(stmt)}
        guard sqlite3_step(stmt)==SQLITE_ROW else{return nil}
        return try jsonObject(Data(bytes:sqlite3_column_blob(stmt,0),count:Int(sqlite3_column_bytes(stmt,0))))
    }
    func each(_ kind:String,_ account:String,_ consume:([String:Any])throws->Void)throws {
        let stmt=try statement("SELECT payload FROM documents WHERE kind=? AND account=? ORDER BY stamp DESC,id",[kind,account]);defer{sqlite3_finalize(stmt)}
        while sqlite3_step(stmt)==SQLITE_ROW {try consume(jsonObject(Data(bytes:sqlite3_column_blob(stmt,0),count:Int(sqlite3_column_bytes(stmt,0)))))}
    }
    func count(_ kind:String,_ account:String)throws->Int {
        let stmt=try statement("SELECT count(*) FROM documents WHERE kind=? AND account=?",[kind,account]);defer{sqlite3_finalize(stmt)}
        _=sqlite3_step(stmt);return Int(sqlite3_column_int(stmt,0))
    }
    func identifiers(_ kind:String,_ account:String)throws->[String] {
        let stmt=try statement("SELECT id FROM documents WHERE kind=? AND account=? ORDER BY stamp DESC,id",[kind,account]);defer{sqlite3_finalize(stmt)}
        var result:[String]=[];while sqlite3_step(stmt)==SQLITE_ROW {result.append(String(cString:sqlite3_column_text(stmt,0)))};return result
    }
    func removeDerivedDrills(account:String,source:String)throws {
        try execute("DELETE FROM documents WHERE kind='drill' AND account=? AND json_extract(CAST(payload AS TEXT),'$.source')=?",[account,source])
    }
}

struct NativePGN {
    let headers:[String:String]
    let san:[String]
    let clocks:[Double?]
    init(_ text:String)throws {
        guard text.utf8.count<=2_000_000 else {throw profileError("Oversized game")}
        let header=try NSRegularExpression(pattern:#"(?m)^\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"\\])*)"\]\s*$"#)
        let ns=text as NSString;var h:[String:String]=[:]
        for match in header.matches(in:text,range:NSRange(location:0,length:ns.length)) {h[ns.substring(with:match.range(at:1))]=ns.substring(with:match.range(at:2)).replacingOccurrences(of:#"\""#,with:"\"")}
        let body=header.stringByReplacingMatches(in:text,range:NSRange(location:0,length:ns.length),withTemplate:"")
        var tokens:[String]=[],times:[Double?]=[],buffer="",comment="",variation=0,inComment=false,inLine=false
        let numbering=try NSRegularExpression(pattern:#"^\d+\.(?:\.\.)?"#)
        func flush() {
            var token=buffer;buffer=""
            token=numbering.stringByReplacingMatches(in:token,range:NSRange(token.startIndex...,in:token),withTemplate:"")
            if token.isEmpty || token.hasPrefix("$") || ["1-0","0-1","1/2-1/2","*","...","e.p."].contains(token){return}
            tokens.append(token);times.append(nil)
        }
        for ch in body {
            if inLine {if ch=="\n"{inLine=false};continue}
            if inComment {
                if ch=="}" {
                    inComment=false
                    if variation==0,!times.isEmpty,let start=comment.range(of:"[%clk "),let end=comment[start.upperBound...].firstIndex(of:"]") {
                        let parts=comment[start.upperBound..<end].split(separator:":").compactMap{Double($0)}
                        if parts.count==3 {times[times.count-1]=parts[0]*3600+parts[1]*60+parts[2]}
                    }
                    comment=""
                } else {comment.append(ch)}
                continue
            }
            if ch=="{" {if variation==0{flush()};inComment=true;continue}
            if ch==";" {if variation==0{flush()};inLine=true;continue}
            if ch=="(" {if variation==0{flush()};variation+=1;continue}
            if ch==")" {variation=max(0,variation-1);continue}
            if variation>0 {continue}
            if ch.isWhitespace {flush()} else {buffer.append(ch)}
        }
        flush()
        guard !inComment,variation==0,!tokens.isEmpty,["1-0","0-1","1/2-1/2"].contains(h["Result"] ?? ""),["Standard","Chess"].contains(h["Variant"] ?? "Standard") else {throw profileError("Unsupported or unfinished game")}
        headers=h;san=tokens;clocks=times
    }
}

actor OnDeviceProfiles {
    static let shared=OnDeviceProfiles()
    private var archive:NativeProfileStore?
    private var task:Task<Void,Never>?
    private var current:String?
    private var stop=false
    private var pausedByUser=false
    private let config="ios-stockfish19-nn1a298aa575a0-allplies-2m-4m-v2"
    private let session:URLSession
    init() {
        let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=40;c.timeoutIntervalForResource=86400
        session=URLSession(configuration:c)
    }
    private func store()throws->NativeProfileStore {
        if let archive{return archive}
        let base=ProcessInfo.processInfo.environment["CC_PROFILE_DIRECTORY"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CloudChess")
        let result=try NativeProfileStore(url:base.appendingPathComponent("profiles.sqlite3"));archive=result;return result
    }
    func resetArchive() async {
        pause(userInitiated:true)
        let running=task;await running?.value
        archive=nil;current=nil;task=nil
        let base=ProcessInfo.processInfo.environment["CC_PROFILE_DIRECTORY"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CloudChess")
        for name in ["profiles.sqlite3","profiles.sqlite3-wal","profiles.sqlite3-shm"] {try? FileManager.default.removeItem(at:base.appendingPathComponent(name))}
    }
    static func identity(_ link:String)throws->(String,String) {
        guard let u=URLComponents(string:link),u.scheme=="https",u.port==nil,u.user==nil,u.password==nil,u.query==nil,u.fragment==nil else {throw profileError("Use a Chess.com or Lichess HTTPS profile link")}
        let parts=u.path.split(separator:"/").map(String.init);let host=u.host?.lowercased() ?? ""
        guard parts.count==2 else {throw profileError("Invalid profile link")}
        let provider:String
        if ["chess.com","www.chess.com"].contains(host),parts[0]=="member" {provider="chesscom"}
        else if ["lichess.org","www.lichess.org"].contains(host),parts[0]=="@" {provider="lichess"}
        else {throw profileError("Invalid profile link")}
        guard parts[1].range(of:#"^[A-Za-z0-9_-]{1,50}$"#,options:.regularExpression) != nil else {throw profileError("Invalid username")}
        return(provider,parts[1].lowercased())
    }
    func start(_ link:String,limit:Int?=nil)throws->[String:Any] {
        guard current==nil else {throw profileError("An analysis is already running")}
        let (provider,user)=try Self.identity(link),id=UUID().uuidString.lowercased()
        let job:[String:Any]=["id":id,"account":provider+":"+user,"provider":provider,"username":user,"status":"queued","error":NSNull(),"limit":limit as Any? ?? NSNull(),"config":config]
        try store().put("job",id,provider+":"+user,job);begin(job);return job
    }
    private func begin(_ job:[String:Any]) {
        current=job["id"] as? String;stop=false;pausedByUser=false
        task=Task{await run(job)}
    }
    func status(_ id:String)throws->[String:Any] {
        guard var job=try store().get("job",id) else {throw profileError("Saved analysis was not found")}
        if current != id,job["config"] as? String != config,job["status"] as? String=="completed" {
            job["status"]="interrupted";job["error"]="Resume to analyse every move and build personal drills."
            try store().put("job",id,job["account"] as! String,job)
        }
        if current != id,["queued","importing","analysing","modelling"].contains(job["status"] as? String ?? "") {
            job["status"]="interrupted";job["error"]="Analysis paused. Resume from the saved checkpoint."
            try store().put("job",id,job["account"] as! String,job)
        }
        return job
    }
    func resume(_ id:String)throws->[String:Any] {
        guard current==nil else {throw profileError("An analysis is already running")}
        var job=try status(id);job["status"]="queued";job["error"]=NSNull();job["config"]=config;try store().put("job",id,job["account"] as! String,job);begin(job);return job
    }
    func upgradeIfNeeded(_ id:String)throws->[String:Any] {
        let job=try status(id)
        if current==nil,job["config"] as? String != config {return try resume(id)}
        if current==nil,["cancelled","interrupted"].contains(job["status"] as? String ?? ""),job["userPaused"] as? Bool != true {return try resume(id)}
        return job
    }
    func pause(userInitiated:Bool=false) {
        stop=true;pausedByUser = pausedByUser || userInitiated;task?.cancel()
        // Do not globally stop the shared engine: it may currently be judging
        // a foreground challenge. Bounded searches finish; cancelled evidence
        // is discarded by NativeChess.call before it can be persisted.
    }
    func cancel(_ id:String)throws->[String:Any] {if current==id{pause(userInitiated:true)};return try status(id)}
    func report(_ id:String)throws->[String:Any] {
        let job=try status(id)
        guard let reportID=job["report"] as? String,let result=try store().get("report",reportID) else {throw profileError("Report is not ready")};return result
    }
    /// Every missed engine continuation is retained; near-equal alternatives
    /// are accepted during play, rather than falsely called unique solutions.
    static func drill(_ evidence:[String:Any],game:[String:Any],id:String)->[String:Any]? {
        guard evidence["playerDecision"] as? Bool==true,
              let best=evidence["best"] as? [String:Any],let line=best["pv"] as? [String],!line.isEmpty,
              line.first != evidence["played"] as? String,
              (evidence["centipawnLoss"] as? Double ?? 0)>0,
              let fen=evidence["fen"] as? String else{return nil}
        let cp=NativeSkillModel.score(best),length=min(5,line.count%2==0 ? line.count-1:line.count)
        var result:[String:Any] = ["id":id,"fen":fen,"columns":8,"rows":8,"mate":0,"gain":0,"plies":max(1,length),
                "rating":1400,"uncertainty":650,"complexity":evidence["complexity"] ?? 60,
                "seconds":90,"tags":evidence["tags"] ?? [],"line":Array(line.prefix(max(1,length))),
                "source":game["id"]!,"sourceURL":game["source"]!,"nodes":best["nodes"] ?? 0,
                "challengeType":"personal","initialEvaluation":cp,"difficultyVersion":"personal-unmeasured"]
        if let features=evidence["difficultyFeatures"] as? [Double] {
            result["difficultyFeatures"]=features
            if let data=try? jsonData(result),let puzzle=try? JSONDecoder().decode(TrainingPuzzle.self,from:data),
               let measured=try? ModeDifficulty.rerated(puzzle),let encoded=try? JSONEncoder().encode(measured),let value=try? jsonObject(encoded) {return value}
        }
        return result
    }
    func drills(jobID:String)throws->[TrainingPuzzle] {
        let job=try status(jobID),account=job["account"] as! String
        var result:[TrainingPuzzle]=[]
        try store().each("drill",account){value in
            if let p=try? JSONDecoder().decode(TrainingPuzzle.self,from:jsonData(value)){result.append(p)}
        }
        return result
    }
    func hasDrills(jobID:String,avoiding:Set<String>=[])throws->Bool {
        let job=try status(jobID),account=job["account"] as! String
        if avoiding.isEmpty {return try store().count("drill",account)>0}
        var available=false
        try store().each("drill",account) {value in
            guard !available,let p=try? JSONDecoder().decode(TrainingPuzzle.self,from:jsonData(value)) else{return}
            available=p.repeatKeys.isDisjoint(with:avoiding)
        }
        return available
    }
    func selectDrill(jobID:String,learner:AdaptivePuzzleCoach,excluding:String?=nil) async throws->TrainingPuzzle? {
        let job=try status(jobID),account=job["account"] as! String
        let counts=Dictionary(grouping:learner.attempts,by:{$0.puzzle}).mapValues{$0.count}
        var shortlist:[(Double,TrainingPuzzle)]=[]
        let target=learner.targetRating(for:.personal)
        func rank(_ p:TrainingPuzzle)->Double {
            let distance=p.difficultyVersion==ModeDifficulty.version ? abs(p.rating-target):180
            return Double(counts[p.id] ?? 0)*1200+distance-p.tags.reduce(0){$0+learner.weakness($1)}*100
        }
        try store().each("drill",account){value in
            guard let p=try? JSONDecoder().decode(TrainingPuzzle.self,from:jsonData(value)),p.id != excluding,learner.allowsNextPuzzle(p) else{return}
            shortlist.append((rank(p),p));shortlist.sort{$0.0 == $1.0 ? $0.1.id<$1.1.id:$0.0<$1.0}
            if shortlist.count>12 {shortlist.removeLast()}
        }
        var measured:[TrainingPuzzle]=[]
        // Legacy archives migrate lazily in small bounded batches. A game rating
        // is never presented or scored as the difficulty of a missed opportunity.
        for (_,candidate) in shortlist.prefix(4) {
            if candidate.difficultyVersion==ModeDifficulty.version {measured.append(candidate);continue}
            let p=try await ChallengeEngine.calibrated(candidate)
            try store().put("drill",p.id,account,jsonObject(JSONEncoder().encode(p)))
            measured.append(p)
        }
        return measured.min{rank($0)==rank($1) ? $0.id<$1.id:rank($0)<rank($1)}
    }
    #if DEBUG
    /// Offline integration fixture goes through the same normalization, move
    /// analysis, checkpointing, drill extraction and model pipeline as downloads.
    func testArchive(_ pgn:String,username:String)async throws->[String:Any] {
        guard current==nil else{throw profileError("Analysis running")}
        let id=UUID().uuidString,account="fixture:"+username
        let job:[String:Any]=["id":id,"account":account,"provider":"lichess","username":username,"status":"queued","config":config,"importComplete":true,"received":1,"skipped":0]
        let game=try await normalize(["pgn":pgn,"id":id,"lastMoveAt":1700000000000.0],job)
        try store().put("job",id,account,job);try store().put("game",account+":"+id,account,game,stamp:1700000000)
        begin(job);return job
    }
    #endif
    private func check()throws {if stop || Task.isCancelled {throw CancellationError()}}
    private func update(_ original:[String:Any],_ status:String,_ extra:[String:Any]=[:])throws->[String:Any] {
        var job=original;job["status"]=status;for(k,v) in extra{job[k]=v};try store().put("job",job["id"] as! String,job["account"] as! String,job);return job
    }
    private func request(_ url:URL,stream:Bool=false)async throws->(URLSession.AsyncBytes,HTTPURLResponse) {
        for attempt in 0..<6 {
            try check();var req=URLRequest(url:url);req.setValue("CloudChess/1.0 (on-device personal analysis)",forHTTPHeaderField:"User-Agent")
            if stream{req.setValue("application/x-ndjson",forHTTPHeaderField:"Accept")}
            let (bytes,response)=try await session.bytes(for:req)
            guard let response=response as? HTTPURLResponse else{throw profileError("Invalid provider response")}
            // Only the constructed provider endpoints may supply imported data.
            guard response.url?.host==url.host else{throw profileError("Unexpected provider redirect")}
            if response.statusCode==429 || response.statusCode>=500 {
                bytes.task.cancel()
                guard attempt<5 else{throw profileError("Provider is busy. Resume later.")}
                let delay=max(response.statusCode==429 ? 60:2,Double(response.value(forHTTPHeaderField:"Retry-After") ?? "") ?? pow(2,Double(attempt)))
                try await Task.sleep(for:.seconds(delay));continue
            }
            guard response.statusCode==200 else {bytes.task.cancel();throw profileError("Profile download returned \(response.statusCode)")}
            return(bytes,response)
        }
        throw profileError("Profile download failed")
    }
    private func fetchJSON(_ url:URL)async throws->[String:Any] {
        let(bytes,_)=try await request(url);var data=Data()
        for try await byte in bytes {data.append(byte);if data.count>128_000_000{bytes.task.cancel();throw profileError("Archive too large")}}
        return try jsonObject(data)
    }
    private func normalize(_ raw:[String:Any],_ job:[String:Any])async throws->[String:Any] {
        let user=job["username"] as! String,provider=job["provider"] as! String
        guard (raw["rules"] as? String ?? "chess")=="chess",(raw["variant"] as? String ?? "standard")=="standard",let pgn=raw["pgn"] as? String else{throw profileError("Unsupported game")}
        let parsed=try NativePGN(pgn),h=parsed.headers
        guard (h["White"]?.lowercased()==user) != (h["Black"]?.lowercased()==user) else{throw profileError("Game identity mismatch")}
        let white=h["White"]?.lowercased()==user
        let initial=h["FEN"] ?? "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let board=try await NativeChess.call(["action":"parse","initial":initial,"moves":parsed.san])
        let moves=board["moves"] as! [String]
        var clocks:[Any]=parsed.clocks.map{$0 as Any? ?? NSNull()}
        if provider=="lichess",let values=raw["clocks"] as? [Double]{for i in 0..<min(values.count,clocks.count){clocks[i]=values[i]/100}}
        let control=(h["TimeControl"] ?? "?").split(separator:"+").compactMap{Double($0)}
        let base=control.count>=1 ? control[0]:nil,increment=control.count==2 ? control[1]:(control.count==1 ? 0:nil)
        let seconds=(base ?? 0)+40*(increment ?? 0)
        let speed=raw["time_class"] as? String ?? raw["speed"] as? String ?? (base==nil ? "unknown":seconds<180 ? "bullet":seconds<600 ? "blitz":seconds<1800 ? "rapid":"classical")
        var ended=raw["end_time"] as? Double ?? (raw["lastMoveAt"] as? Double ?? 0)/1000
        if ended==0 {let formatter=DateFormatter();formatter.dateFormat="yyyy.MM.dd";formatter.timeZone=TimeZone(secondsFromGMT:0);ended=formatter.date(from:h["UTCDate"] ?? h["Date"] ?? "")?.timeIntervalSince1970 ?? 0}
        let id=try raw["uuid"] as? String ?? raw["id"] as? String ?? raw["url"] as? String ?? h["Site"] ?? (try fingerprint([initial,moves,h["Date"] ?? "",h["White"] ?? "",h["Black"] ?? ""] as [Any]))
        return ["id":id,"account":job["account"]!,"initial":initial,"moves":moves,"clocks":clocks,"color":white ? "white":"black","ended":ended,"speed":speed,"base":base as Any? ?? NSNull(),"increment":increment as Any? ?? NSNull(),"rated":raw["rated"] as? Bool ?? false,"rating":Int(h[white ? "WhiteElo":"BlackElo"] ?? "") as Any? ?? NSNull(),"opponentRating":Int(h[white ? "BlackElo":"WhiteElo"] ?? "") as Any? ?? NSNull(),"result":h["Result"]!,"eco":h["ECO"] as Any? ?? NSNull(),"opening":h["Opening"] as Any? ?? NSNull(),"source":raw["url"] as? String ?? h["Site"] ?? ""]
    }
    private func run(_ original:[String:Any])async {
        var job=original;let account=job["account"] as! String
        defer{current=nil;task=nil}
        do {
            var received=job["received"] as? Int ?? 0,skipped=job["skipped"] as? Int ?? 0
            let limit=job["limit"] as? Int
            if job["importComplete"] as? Bool != true {
            job=try update(job,"importing");received=0;skipped=0
            func accept(_ raw:[String:Any])async throws {
                try check();received+=1
                var normalized:[String:Any]?
                do {normalized=try await normalize(raw,job)}
                catch is CancellationError {throw CancellationError()}
                catch {skipped+=1}
                if let game=normalized {
                    let key=account+":"+(game["id"] as! String)
                    try store().put("game",key,account,game,stamp:game["ended"] as! Double)
                }
                if received%10==0 {job=try update(job,"importing",["received":received,"skipped":skipped])}
            }
            // Complete archives are always rechecked; engine evidence is keyed
            // by normalized game content so corrected games cannot reuse labels.
            if job["provider"] as! String=="lichess" {
                var url=URLComponents(string:"https://lichess.org/api/games/user/"+(job["username"] as! String))!
                url.queryItems=[URLQueryItem(name:"pgnInJson",value:"true"),URLQueryItem(name:"clocks",value:"true"),URLQueryItem(name:"opening",value:"true"),URLQueryItem(name:"ongoing",value:"false"),URLQueryItem(name:"finished",value:"true")]
                if let limit{url.queryItems?.append(URLQueryItem(name:"max",value:String(limit)))}
                let(bytes,_)=try await request(url.url!,stream:true)
                for try await line in bytes.lines where !line.isEmpty {try await accept(jsonObject(Data(line.utf8)))}
            } else {
                let root="https://api.chess.com/pub/player/"+(job["username"] as! String)+"/games/"
                let catalog=try await fetchJSON(URL(string:root+"archives")!)
                for archive in (catalog["archives"] as? [String] ?? []).sorted().reversed() {
                    try check();guard archive.hasPrefix(root),archive.dropFirst(root.count).range(of:#"^\d{4}/\d{2}$"#,options:.regularExpression) != nil else{throw profileError("Invalid archive URL")}
                    let page=try await fetchJSON(URL(string:archive)!)
                    for game in (page["games"] as? [[String:Any]] ?? []).sorted(by:{($0["end_time"] as? Double ?? 0)>($1["end_time"] as? Double ?? 0)}) {
                        if let limit,received>=limit{break};try await accept(game)
                    }
                    if let limit,received>=limit{break}
                }
            }
            job=try update(job,"analysing",["received":received,"skipped":skipped,"limited":limit != nil,"importComplete":true])
            }
            job=try update(job,"analysing")
            for key in try store().identifiers("game",account) {
                try check();guard let game=try store().get("game",key) else{continue}
                let hash=try fingerprint([config,game] as [Any]);if try store().get("complete",key)?["hash"] as? String==hash {continue}
                // Rebuild only derived opportunities for this game. Raw moves
                // remain intact, and resumed evidence recreates drills below.
                try store().removeDerivedDrills(account:account,source:game["id"] as! String)
                let moves=game["moves"] as! [String]
                
                for i in 0..<moves.count {
                    try check();let eid=hash+":"+String(i)
                    if let saved=try store().get("move",eid) {
                        if let drill=Self.drill(saved,game:game,id:eid) {try store().put("drill",eid,account,drill,stamp:game["ended"] as! Double)}
                        continue
                    }
                    let evidence=try await analyse(game,index:i)
                    try check();try store().put("move",eid,hash,evidence,stamp:Double(i))
                    if let drill=Self.drill(evidence,game:game,id:eid) {try store().put("drill",eid,account,drill,stamp:game["ended"] as! Double)}
                    job=try update(job,"analysing",["game":game["id"]!,"ply":i+1,"analysedGames":try store().count("complete",account)])
                }
                try store().put("complete",key,account,["hash":hash],stamp:game["ended"] as! Double)
            }
            try check();job=try update(job,"modelling")
            let report=try buildReport(account,job:job)
            try check();let reportID=try fingerprint(report);try store().put("report",reportID,account,report)
            _=try update(job,"completed",["report":reportID,"error":NSNull()])
        } catch {
            let paused=stop || Task.isCancelled || error is CancellationError
            _=try? update(job,paused ? "cancelled":"failed",["error":paused ? "Paused. Resume from the saved checkpoint.":error.localizedDescription,"userPaused":pausedByUser])
        }
    }
    private func analyse(_ game:[String:Any],index:Int)async throws->[String:Any] {
        let history=Array((game["moves"] as! [String]).prefix(index)),move=(game["moves"] as! [String])[index]
        let initial=game["initial"] as! String
        func evaluate(_ nodes:Int)async throws->([String:Any],[[String:Any]],[String:Any],[String:Any]) {
            let state=try await NativeChess.profileCall(["action":"analyse","initial":initial,"moves":history,"nodes":nodes,"multipv":3])
            let rows=state["evaluations"] as? [[String:Any]] ?? []
            guard !rows.isEmpty else{throw profileError("The local engine returned no continuation")}
            var played=rows.first{($0["pv"] as? [String])?.first==move}
            if played==nil {
                let restricted=try await NativeChess.profileCall(["action":"analyse","initial":initial,"moves":history,"nodes":nodes,"multipv":1,"root":move])
                played=(restricted["evaluations"] as? [[String:Any]])?.first
            }
            guard let played else{throw profileError("The local engine was interrupted")}
            let best=(rows+[played]).max(by:{NativeSkillModel.score($0)<NativeSkillModel.score($1)})!
            return(state,rows,best,played)
        }
        var (state,rows,best,played)=try await evaluate(2000000)
        let shallowLoss=NativeSkillModel.loss(best,played),shallowBest=(best["pv"] as! [String])[0]
        let tags=best["tags"] as? [String] ?? []
        let deep=shallowBest != move || shallowLoss>=0.045 || NativeSkillModel.score(best)-NativeSkillModel.score(played)>=65 || best["mate"] is Int || played["mate"] is Int || !Set(tags).isDisjoint(with:["fork","royalFork","doubleCheck","promotion"])
        if deep {(state,rows,best,played)=try await evaluate(4000000)}
        let loss=NativeSkillModel.loss(best,played)
        let stable = !deep || ((shallowLoss>=0.08)==(loss>=0.08) && (shallowBest==(best["pv"] as! [String])[0] || loss<0.04))
        let fen=state["fen"] as! String,placement=String(fen.split(separator:" ")[0])
        let pieces=placement.filter{$0.isLetter};let nonpawn=pieces.reduce(0){$0+(["n":3,"b":3,"r":5,"q":9][String($1).lowercased()] ?? 0)}
        let phase=nonpawn<=20 || pieces.count<=10 ? "endgame":history.count<24 ? "opening":"middlegame"
        var skills=Set(best["tags"] as? [String] ?? []);skills.insert("phase:"+phase)
        if phase=="opening" {if let eco=game["eco"] as? String{skills.insert("eco:"+eco)};if let opening=game["opening"] as? String{skills.insert("opening:"+opening)}}
        if NativeSkillModel.utility(best)>=0.8{skills.insert("conversion")}
        else if NativeSkillModel.utility(best)<=0.2{skills.insert("defense")}
        if let mate=best["mate"] as? Int,mate>0{skills.insert("plan:mate"+(mate<=3 ? String(mate):"4plus"))}
        else if skills.contains("quietMove"){skills.insert("plan:improvement")}
        let legal=(state["legal"] as! [String]).count
        let ambiguity=rows.reduce(0.0){$0+exp(-min(2000,max(0,NativeSkillModel.score(best)-NativeSkillModel.score($1)))/100)}/Double(rows.count)
        let complexity=min(100,12*log2(Double(legal+1))+18*ambiguity+(skills.contains("quietMove") ? 10:0))
        let clocks=game["clocks"] as! [Any],base=game["base"] as? Double,increment=game["increment"] as? Double
        let before=index>=2 ? clocks[index-2] as? Double:base,current=clocks[index] as? Double
        var elapsed:Double?,pressure:Bool?
        if index>=2,let before,let current,let increment {let delta=before+increment-current;if delta>=0 && delta<=before+increment{elapsed=delta}}
        if let before,let base,!["daily","correspondence","unknown"].contains(game["speed"] as! String){pressure=before<=max(10,base*0.1,(increment ?? 0)*3)}
        let turns=max(1,min(3,((best["pv"] as? [String] ?? []).count+1)/2))
        let difficulty=try ModeDifficulty.features(fen:fen,kind:.personal,turns:turns,response:state,opponent:0)
        return ["difficultyFeatures":difficulty,"playerDecision":(fen.split(separator:" ")[1]=="w")==((game["color"] as! String)=="white"),"game":game["id"]!,"source":game["source"]!,"ply":index+1,"fen":fen,"played":move,"best":best,"playedEvaluation":played,"scoreLoss":loss,"centipawnLoss":min(2000,max(0,NativeSkillModel.score(best)-NativeSkillModel.score(played))),"error":loss>=0.08 && legal>1,"forced":legal==1,"stable":stable,"deepened":deep,"complexity":complexity,"tags":skills.sorted(),"ended":game["ended"]!,"speed":game["speed"]!,"color":game["color"]!,"clock":["seconds":elapsed as Any? ?? NSNull(),"pressure":pressure as Any? ?? NSNull()]]
    }
    private func buildReport(_ account:String,job:[String:Any])throws->[String:Any] {
        var games:[[String:Any]]=[],sample:[[String:Any]]=[],total=0,allMoves=0,mistakes=0,deep=0
        try store().each("game",account){game in
            games.append(game.filter{!["moves","clocks"].contains($0.key)})
            let key=account+":"+(game["id"] as! String)
            guard let complete=try store().get("complete",key),let hash=complete["hash"] as? String else{return}
            try store().each("move",hash){evidence in
                allMoves+=1
                guard evidence["playerDecision"] as? Bool != false else{return}
                total+=1;mistakes+=(evidence["error"] as? Bool ?? false) ? 1:0;deep+=(evidence["deepened"] as? Bool ?? false) ? 1:0
                // Deterministic reservoir independent of outcome; every move is
                // stored even when model fitting uses a bounded sample.
                if sample.count<25000 {sample.append(evidence)}
                else {
                    let hex=try fingerprint([evidence["game"]!,evidence["ply"]!] as [Any])
                    let index=Int(UInt64(hex.prefix(15),radix:16)!%UInt64(total))
                    if index<25000{sample[index]=evidence}
                }
            }
        }
        let now=games.map{$0["ended"] as? Double ?? 0}.max() ?? 0
        let model=NativeSkillModel.diagnose(sample,now:now)
        return ["account":account,"version":config,"engine":"Stockfish 19 NNUE, on device, one thread, 64 MB hash","coverage":["importedGames":games.count,"analysedGames":try store().count("complete",account),"completeGameDecisions":total,"allAnalysedMoves":allMoves,"drills":try store().count("drill",account),"modelSampleDecisions":sample.count],"ratings":NativeSkillModel.ratings(games,now:now),"skills":model["skills"]!,"model":model,"summary":["mistakes":mistakes,"deepRechecks":deep],"import":["received":job["received"] ?? 0,"skipped":job["skipped"] ?? 0,"limited":job["limited"] ?? false],"trainingPrior":model["trainingPrior"]!,"limits":["Engine-defined mistakes, not human-validated diagnoses.","Performance estimates remain specific to site and time control; not puzzle or FIDE Elo.","Sparse and overlapping tags remain uncertain. All games analysed; statistical fitting samples at most 25,000 decisions.","Clock pressure and decision complexity are contextual estimates."]]
    }
}

/// On-device Bayesian contextual logistic regression. Correlated tags share
/// the same sparse design row; ridge priors and the full Hessian account for
/// dependence. Imported evidence never manufactures puzzle outcomes or Elo.
enum NativeSkillModel {
    static func score(_ row:[String:Any])->Double {if let mate=row["mate"] as? Double{return (mate>0 ? 1:-1)*(100000-min(999,abs(mate)))};return row["cp"] as? Double ?? 0}
    static func utility(_ row:[String:Any])->Double {if let mate=row["mate"] as? Double{return mate>0 ? 1:0};return sigmoid((row["cp"] as? Double ?? 0)/250)}
    static func loss(_ best:[String:Any],_ played:[String:Any])->Double {
        if let a=best["mate"] as? Double,let b=played["mate"] as? Double,a*b>0{return 0};return max(0,utility(best)-utility(played))
    }
    static func sigmoid(_ x:Double)->Double {1/(1+exp(-max(-35,min(35,x))))}
    static func age(_ time:Double,_ now:Double)->Double {time>0 ? pow(2,-max(0,now-time)/(180*86400)):0.25}
    struct Observation {let features:[(Int,Double)];let y:Double;let weight:Double;let row:[String:Any]}
    static func cholesky(_ matrix:[Double],_ n:Int)->[Double] {
        var a=matrix
        for i in 0..<n {for j in 0...i {
            var value=a[i*n+j];if j>0{for k in 0..<j{value-=a[i*n+k]*a[j*n+k]}}
            a[i*n+j]=i==j ? sqrt(max(1e-10,value)):value/a[j*n+j]
        }}
        return a
    }
    static func solve(_ l:[Double],_ b:[Double],_ n:Int)->[Double] {
        var x=b
        for i in 0..<n {if i>0{for j in 0..<i{x[i]-=l[i*n+j]*x[j]}};x[i]/=l[i*n+i]}
        for i in (0..<n).reversed(){if i+1<n{for j in (i+1)..<n{x[i]-=l[j*n+i]*x[j]}};x[i]/=l[i*n+i]};return x
    }
    static func fit(_ rows:[Observation],_ names:[String])->([Double],[Double]) {
        let n=names.count
        let precision=names.map{$0=="intercept" ? 0.25:$0.hasPrefix("tag:") ? 1/(0.7*0.7):1.0}
        var beta=[Double](repeating:0,count:n);beta[0]=log(0.15/0.85);let prior=beta
        func derivatives(_ beta:[Double])->([Double],[Double]) {
            var h=[Double](repeating:0,count:n*n),g=[Double](repeating:0,count:n)
            for i in 0..<n{h[i*n+i]=precision[i];g[i]=precision[i]*(beta[i]-prior[i])}
            for row in rows {
                let p=sigmoid(row.features.reduce(0){$0+beta[$1.0]*$1.1}),v=row.weight*p*(1-p),error=row.weight*(p-row.y)
                for (i,xi) in row.features {g[i]+=error*xi;for(j,xj) in row.features{h[i*n+j]+=v*xi*xj}}
            };return(h,g)
        }
        for _ in 0..<24 {
            let(h,g)=derivatives(beta),delta=solve(cholesky(h,n),g,n),largest=delta.map{abs($0)}.max() ?? 0
            let scale=max(1,largest)
            for i in 0..<n{beta[i]-=delta[i]/scale}
            if largest<1e-5{break}
        }
        let h=cholesky(derivatives(beta).0,n)
        var sd:[Double]=[]
        for i in 0..<n{var unit=[Double](repeating:0,count:n);unit[i]=1;sd.append(sqrt(max(0,solve(h,unit,n)[i])))}
        return(beta,sd)
    }
    static func diagnose(_ input:[[String:Any]],now:Double)->[String:Any] {
        let rows=input.filter{!($0["forced"] as? Bool ?? false)}.sorted{let a=$0["ended"] as? Double ?? 0,b=$1["ended"] as? Double ?? 0;return a==b ? String(describing:$0["game"]!)<String(describing:$1["game"]!):a<b}
        guard !rows.isEmpty else{return ["skills":[],"trainingPrior":[:],"validation":["status":"insufficient_data"]]}
        var tagGames:[String:Set<String>]=[:],gameCount:[String:Int]=[:],repeats:[String:Int]=[:]
        for r in rows{let game=r["game"] as! String;gameCount[game,default:0]+=1;repeats[game+":"+(r["fen"] as! String).split(separator:" ").prefix(2).joined(separator:" "),default:0]+=1;for tag in r["tags"] as! [String]{tagGames[tag,default:[]].insert(game)}}
        let tags=tagGames.keys.sorted{tagGames[$0]!.count==tagGames[$1]!.count ? $0<$1:tagGames[$0]!.count>tagGames[$1]!.count}.prefix(192)
        let names=["intercept","complexity","timePressure","clockMissing","black"]+Set(rows.map{"speed:"+($0["speed"] as! String)}).sorted()+tags.map{"tag:"+$0}
        let indices=Dictionary(uniqueKeysWithValues:names.enumerated().map{($0.element,$0.offset)})
        let observations:[Observation]=rows.map{r in
            let clock=r["clock"] as! [String:Any],tagList=r["tags"] as! [String],game=r["game"] as! String
            var features:[String:Double]=["intercept":1,"complexity":((r["complexity"] as! Double)-60)/20,"timePressure":(clock["pressure"] as? Bool)==true ? 1:0,"clockMissing":clock["pressure"] is NSNull ? 1:0,"black":(r["color"] as! String)=="black" ? 1:0,"speed:"+(r["speed"] as! String):1]
            for tag in tagList{features["tag:"+tag]=1/sqrt(Double(max(1,tagList.count)))}
            let repeatCount=repeats[game+":"+(r["fen"] as! String).split(separator:" ").prefix(2).joined(separator:" ")]!
            let weight=age(r["ended"] as! Double,now)*min(1,4/Double(gameCount[game]!))*((r["stable"] as! Bool) ? 1:0.25)/Double(repeatCount)
            return Observation(features:features.compactMap{key,value in guard let i=indices[key],value != 0 else{return nil};return(i,value)}.sorted{$0.0<$1.0},y:(r["error"] as! Bool) ? 1:0,weight:weight,row:r)
        }
        var orderedGames:[String]=[];var seen=Set<String>()
        for row in rows{let id=row["game"] as! String;if seen.insert(id).inserted{orderedGames.append(id)}}
        var validation:[String:Any]=["status":"insufficient_data"]
        if orderedGames.count>=30 {
            let trainGames=Set(orderedGames.prefix(Int(Double(orderedGames.count)*0.8)))
            let train=observations.filter{trainGames.contains($0.row["game"] as! String)},test=observations.filter{!trainGames.contains($0.row["game"] as! String)}
            let coefficients=fit(train,names).0,baseline=(train.reduce(0){$0+$1.weight*$1.y}+1)/(train.reduce(0){$0+$1.weight}+2)
            let total=test.reduce(0){$0+$1.weight}
            let brier=test.reduce(0){sum,r in let p=sigmoid(r.features.reduce(0){$0+coefficients[$1.0]*$1.1});return sum+r.weight*pow(p-r.y,2)}/max(1e-10,total)
            let base=test.reduce(0){$0+$1.weight*pow(baseline-$1.y,2)}/max(1e-10,total)
            validation=["status":"chronological_game_holdout","trainGames":trainGames.count,"testGames":orderedGames.count-trainGames.count,"brier":brier,"baselineBrier":base]
        }
        let(beta,sd)=fit(observations,names)
        var skills:[[String:Any]]=[],prior:[String:Double]=[:]
        for tag in tags {
            let j=indices["tag:"+tag]!,related=observations.filter{($0.row["tags"] as! [String]).contains(tag)},games=tagGames[tag]!.count
            let effective=related.reduce(0){$0+$1.weight},probability=0.5*(1+erf(beta[j]/max(1e-10,sd[j]*sqrt(2))))
            let confidence=max(0,2*probability-1)*min(1,Double(games)/12)*effective/(effective+3)
            let priority=min(1,max(0,beta[j])/1.2)*confidence
            let status=games<8 ? "insufficient_evidence":probability>=0.95 ? "likely_weakness":probability>=0.75 ? "possible_focus":"no_clear_deficit"
            skills.append(["tag":tag,"games":games,"opportunities":related.count,"effectiveEvidence":effective,"errorRate":related.reduce(0){$0+$1.y}/Double(related.count),"priority":priority,"status":status,"conditionalLogOdds":beta[j],"interval95":[beta[j]-1.96*sd[j],beta[j]+1.96*sd[j]],"probabilityAbovePersonalBaseline":probability])
            if games>=8{prior[tag]=min(0.6,priority)}
        }
        skills.sort{let a=$0["priority"] as! Double,b=$1["priority"] as! Double;return a==b ? ($0["tag"] as! String)<($1["tag"] as! String):a>b}
        return ["skills":skills,"features":names,"coefficients":beta,"posteriorSD":sd,"validation":validation,"trainingPrior":prior,"decisions":rows.count,"tagLimit":192,"halfLifeDays":180]
    }
    static func ratings(_ games:[[String:Any]],now:Double)->[String:Any] {
        let valid=games.filter{($0["rated"] as? Bool)==true && ($0["opponentRating"] as? Double ?? 0)>=100 && ($0["opponentRating"] as? Double ?? 0)<=4000 && ($0["initial"] as? String)=="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" && ($0["speed"] as? String) != "unknown"}
        var result:[String:Any]=[:];let scale=400/log(10.0)
        for speed in Set(valid.map{$0["speed"] as! String}).sorted() {
            let rows=valid.filter{($0["speed"] as! String)==speed}.sorted{($0["ended"] as! Double)>($1["ended"] as! Double)}
            let center=rows.first?["rating"] as? Double ?? 1500
            var theta=center,h=1/(400.0*400),days:[Int:Int]=[:]
            for r in rows{days[Int((r["ended"] as! Double)/86400),default:0]+=1}
            for _ in 0..<30 {
                var g=(theta-center)/(400*400);h=1/(400*400)
                for r in rows {
                    let p=sigmoid((theta-(r["opponentRating"] as! Double))/scale),score=(r["result"] as! String)=="1/2-1/2" ? 0.5:(r["result"] as! String)==((r["color"] as! String)=="white" ? "1-0":"0-1") ? 1.0:0.0
                    let w=age(r["ended"] as! Double,now)*min(1,8/Double(days[Int((r["ended"] as! Double)/86400)]!))
                    g+=w*(p-score)/scale;h+=w*p*(1-p)/(scale*scale)
                }
                let delta=g/h;theta=min(4000,max(100,theta-max(-300,min(300,delta))));if abs(delta)<0.001{break}
            }
            let sd=max(75,sqrt(1/h))
            result[speed]=["performanceEstimate":Int(theta.rounded()),"interval95":[Int(max(100,theta-1.96*sd).rounded()),Int(min(4000,theta+1.96*sd).rounded())],"games":rows.count,"reportedRating":center,"provisional":true]
        };return result
    }
}
