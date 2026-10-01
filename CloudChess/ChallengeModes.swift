import Foundation
import CryptoKit

struct EngineAssessment {
    let cp:Double,mate:Int?,line:[String],depth:Int,nodes:Int
    let runnerUpCP:Double?
    let alternativeMoves:[String]
    init(_ response:[String:Any])throws {
        if let result=response["result"] as? String {
            cp=result=="Draw" ? 0:-100000;mate=result=="Draw" ? nil:0;line=[];depth=0;nodes=0;runnerUpCP=nil;alternativeMoves=[];return
        }
        guard response["limitedStrength"] as? Bool != true,
              let row=(response["evaluations"] as? [[String:Any]])?.first,
              let pv=row["pv"] as? [String],!pv.isEmpty else {throw NSError(domain:"CloudChess.Challenge",code:1,userInfo:[NSLocalizedDescriptionKey:"Full-strength evaluation unavailable"])}
        let rows=response["evaluations"] as? [[String:Any]] ?? []
        runnerUpCP=rows.dropFirst().first.map{NativeSkillModel.score($0)}
        alternativeMoves=rows.compactMap{($0["pv"] as? [String])?.first}
        mate=row["mate"] as? Int
        cp=mate.map{$0>0 ? 100000-Double($0):(-100000-Double($0))} ?? (row["cp"] as? Double ?? 0)
        line=pv;depth=row["depth"] as? Int ?? 0;nodes=row["nodes"] as? Int ?? 0
    }
    func forSolver(turn:String,white:Bool)->Double {cp*((turn=="white")==white ? 1:-1)}
}

/// Strong evaluations and deliberately limited sparring are separate requests.
/// UCI strength settings are reset by the bridge before each search.
enum ChallengeEngine {
    static let nodes=2_000_000
    static func evaluate(initial:String,moves:[String]=[],root:String?=nil,budget:Int=nodes,multipv:Int=1) async throws -> ([String:Any],EngineAssessment) {
        let state=try await NativeChess.call(request(initial:initial,moves:moves,root:root,budget:budget,multipv:multipv))
        return (state,try EngineAssessment(state))
    }
    static func request(initial:String,moves:[String],root:String?=nil,budget:Int=nodes,multipv:Int=1)->[String:Any] {
        var r:[String:Any]=["action":"analyse","initial":initial,"moves":moves,"nodes":budget,"multipv":multipv]
        if let root {r["root"]=root};return r
    }
    static func cached(initial:String,moves:[String],root:String?=nil,budget:Int=nodes,multipv:Int=1)->EngineAssessment? {
        guard let value=NativeChess.cached(request(initial:initial,moves:moves,root:root,budget:budget,multipv:multipv)) else{return nil}
        return try? EngineAssessment(value)
    }
    static func opponent(initial:String,moves:[String],elo:Double) async throws ->String {
        let state=try await NativeChess.call(["action":"bot","initial":initial,"moves":moves,"nodes":300000,"elo":Int(elo),"multipv":1])
        guard let move=state["bestmove"] as? String,(state["legal"] as? [String])?.contains(move)==true else {throw NSError(domain:"CloudChess.Challenge",code:2,userInfo:[NSLocalizedDescriptionKey:"Opponent search interrupted"])}
        return move
    }
    static func state(_ p:TrainingPuzzle,moves:[String]) async throws->[String:Any] {try await NativeChess.call(["action":"state","initial":p.fen,"moves":moves])}
    static func calibrated(_ puzzle:TrainingPuzzle,opponent:Double=0) async throws->TrainingPuzzle {
        let (state,e)=try await evaluate(initial:puzzle.fen,multipv:3)
        guard state["result"] is NSNull else{throw ModeDifficulty.failure("This challenge is already over")}
        var p=try ModeDifficulty.calibrated(puzzle,response:state,opponent:opponent)
        p.line=e.line
        return p
    }
    static func generated(_ kind:ChallengeKind,rating:Double,seed:UInt64,opponentElo:Double?=nil,learner:Double?=nil,targetSuccess:Double=0.67,opponentBounds:ClosedRange<Double>?=nil,excluding:Set<String>=[],avoiding:Set<String>=[],progress:((Int) async->Void)?=nil) async throws->TrainingPuzzle {
        // Foreground handoffs never run the descendant rejection loop when
        // certified evidence is available. Idle preparation still makes novel
        // descendants, retaining every full-strength check below.
        if NativeChess.backgroundEpoch==nil,
           let ready=try await CertifiedChallengeBank.shared.select(kind,rating:rating,seed:seed,opponent:opponentElo,learner:learner,target:targetSuccess,bounds:opponentBounds,excluding:excluding,avoiding:avoiding) {
            await progress?(7);return ready
        }
        let bank=try await ChallengeBank.shared.load()
        await progress?(3)
        let opponent=opponentElo ?? max(100,min(3000,rating-(kind == .finish ? 150:0)))
        let pool=try bank.filter{$0.kind==kind}.map {p in
            p.difficultyVersion==ModeDifficulty.version ? try ModeDifficulty.rerated(p,opponent:opponent):p
        }.sorted {abs($0.rating-rating)==abs($1.rating-rating) ? $0.id<$1.id:abs($0.rating-rating)<abs($1.rating-rating)}
        guard !pool.isEmpty else{throw NSError(domain:"CloudChess.Challenge",code:4)}
        // Re-measure every displayed start. Advance through independently searched
        // legal branches to generate fresh descendants of the offline seeds.
        var rng=seed
        func random(_ n:Int)->Int {rng=rng &* 6364136223846793005 &+ 1442695040888963407;return Int((rng>>24)%UInt64(n))}
        var closest:TrainingPuzzle?,measuredCount=0
        for trial in 0..<32 {
            await progress?(min(7,4+trial/3))
            var p=pool[(Int(seed%UInt64(min(8,pool.count)))+trial)%pool.count]
            var history:[String]=[]
            if trial<8 {
                for _ in 0..<(2+2*random(4)) {
                    let r=try await NativeChess.call(["action":"analyse","initial":p.fen,"moves":history,"nodes":60000,"multipv":3])
                    let rows=r["evaluations"] as? [[String:Any]] ?? []
                    guard r["result"] is NSNull,!rows.isEmpty else{break}
                    let best=NativeSkillModel.score(rows[0])
                    let reasonable=rows.filter{best-NativeSkillModel.score($0)<=75}
                    guard let move=(reasonable[random(reasonable.count)]["pv"] as? [String])?.first else{break};history.append(move)
                }
            }
            let advanced=try await NativeChess.call(["action":"state","initial":p.fen,"moves":history])
            guard let start=advanced["fen"] as? String,advanced["result"] is NSNull else{continue}
            let positionID=SHA256.hash(data:Data((kind.rawValue+start).utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
            guard PuzzleVariety.keys(id:positionID,fen:start,columns:p.columns,rows:p.rows).isDisjoint(with:avoiding) else{continue}
            await progress?(5)
            let (state,e)=try await evaluate(initial:start,multipv:3)
            guard state["result"] is NSNull,e.mate==nil else{continue}
            // The new side to move becomes the solver, so cp is already in their perspective.
            guard kind == .tenMoves ? abs(e.cp)<=10:(e.cp>=180 && e.cp<=650) else{continue}
            let fen=state["fen"] as! String
            p.fen=fen;p.id=SHA256.hash(data:Data((kind.rawValue+fen).utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
            guard !excluding.contains(p.id),p.repeatKeys.isDisjoint(with:avoiding) else{continue}
            // Sparring difficulty includes opponent strength, branching and
            // conversion margin. This is an explicit provisional mode estimate,
            // not the human-trained tactical rating model.
            let branching=Double((state["legal"] as? [String])?.count ?? 20)
            p.complexity=min(100,12*log2(branching+1)+Double(e.line.count))
            p.initialEvaluation=e.cp;p.line=e.line;p.nodes=e.nodes;p.challengeType=kind.rawValue
            p.source="generated:"+p.id;p.seconds=kind == .tenMoves ? 108:300
            if kind == .tenMoves {p.plies=ImprovementChallenge.plies}
            var measured=try ModeDifficulty.calibrated(p,response:state,opponent:opponent)
            if let learner,let opponentBounds {measured=try ModeDifficulty.tuneOpponent(measured,learner:learner,target:targetSuccess,bounds:opponentBounds,preferred:opponent)}
            measuredCount+=1
            if closest==nil || abs(measured.rating-rating)<abs(closest!.rating-rating) {closest=measured}
            if abs(measured.rating-rating)<=225 {return measured}
            if measuredCount>=4 {return closest!}
        }
        if let closest {return closest}
        throw NSError(domain:"CloudChess.Challenge",code:5,userInfo:[NSLocalizedDescriptionKey:"No position passed the evaluation gate. Try again."])
    }
}

/// Complete SF19 evidence baked with the shipping bridge; no shallow estimates.
/// Decoding, integrity validation and adaptive selection run off the UI actor.
actor CertifiedChallengeBank {
    static let shared=CertifiedChallengeBank()
    struct Entry {let puzzle:TrainingPuzzle,response:[String:Any]}
    private var entries:[Entry]?
    func load() throws->[Entry] {
        if let entries {return entries}
        var url=Bundle.main.url(forResource:"certified-challenge-starts",withExtension:"json",subdirectory:"EngineResources")
        #if DEBUG
        if let path=ProcessInfo.processInfo.environment["CC_CERTIFIED_STARTS_PATH"] {url=URL(fileURLWithPath:path)}
        #endif
        guard let url,let data=try? Data(contentsOf:url),
              let archive=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              archive["namespace"] as? String==PersistentChessEvidence.namespace,
              archive["schema"] as? Int==1,let records=archive["entries"] as? [[String:Any]] else {entries=[];return []}
        var valid:[Entry]=[]
        for record in records {
            try Task.checkCancellation()
            guard let object=record["puzzle"],let response=record["response"] as? [String:Any],
                  let encoded=try? JSONSerialization.data(withJSONObject:object),
                  let puzzle=try? JSONDecoder().decode(TrainingPuzzle.self,from:encoded),
                  puzzle.kind == .tenMoves || puzzle.kind == .finish,
                  response["fen"] as? String==puzzle.fen,response["result"] is NSNull,
                  let encodedResponse=try? JSONSerialization.data(withJSONObject:response,options:.sortedKeys),
                  record["digest"] as? String==SHA256.hash(data:encodedResponse).chessHex,
                  PersistentChessEvidence.valid(response,request:ChallengeEngine.request(initial:puzzle.fen,moves:[],multipv:3)),
                  (response["evaluations"] as? [[String:Any]])?.count==min(3,(response["legal"] as? [String])?.count ?? 0),
                  let evaluation=try? EngineAssessment(response),evaluation.mate==nil,
                  puzzle.kind == .tenMoves ? abs(evaluation.cp)<=10:(180...650).contains(evaluation.cp) else {continue}
            var descriptor=puzzle
            descriptor.difficultyFeatures=try ModeDifficulty.features(fen:puzzle.fen,kind:puzzle.kind,turns:puzzle.kind == .finish ? 20:ImprovementChallenge.turns,response:response,opponent:0)
            valid.append(Entry(puzzle:descriptor,response:response))
        }
        entries=valid;return valid
    }
    func select(_ kind:ChallengeKind,rating:Double,seed:UInt64,opponent:Double?,learner:Double?,target:Double,bounds:ClosedRange<Double>?,excluding:Set<String>,avoiding:Set<String>) throws->TrainingPuzzle? {
        let strength=opponent ?? max(100,min(3000,rating-(kind == .finish ? 150:0)))
        let eligible=try load().filter{$0.puzzle.kind==kind && $0.puzzle.repeatKeys.isDisjoint(with:avoiding)}
        // Prefer unseen items; after archive exhaustion permit spaced review,
        // never a recent repeat or a blocking foreground search marathon.
        let unseen=eligible.filter{!excluding.contains($0.puzzle.id)}
        let pool=try (unseen.isEmpty ? eligible:unseen).map {entry in
            (entry,try ModeDifficulty.rerated(entry.puzzle,opponent:strength))
        }.sorted {a,b in
            let da=abs(a.1.rating-rating),db=abs(b.1.rating-rating)
            return da==db ? a.1.id<b.1.id:da<db
        }
        guard !pool.isEmpty else{return nil}
        var selected:(Entry,TrainingPuzzle)?
        let offset=Int(seed%UInt64(min(8,pool.count)))
        for trial in 0..<min(4,pool.count) {
            try Task.checkCancellation()
            let (entry,prior)=pool[(offset+trial)%pool.count]
            let measured:TrainingPuzzle
            if let learner,let bounds {measured=try ModeDifficulty.tuneOpponent(prior,learner:learner,target:target,bounds:bounds,preferred:strength)} else {measured=prior}
            if selected==nil || abs(measured.rating-rating)<abs(selected!.1.rating-rating) {selected=(entry,measured)}
            if abs(measured.rating-rating)<=225 {break}
        }
        guard let (entry,puzzle)=selected else{return nil}
        try NativeChess.retainCertifiedStart(entry.response,initial:puzzle.fen)
        return puzzle
    }
}

struct OpeningStart:Decodable {
    let id:String,fen:String,name:String,eco:String
    let ply:Int,visits:Int,rating:Double
    let difficultyFeatures:[Double]?
    let ratingsByMoves:[String:Double]?
}
struct OpeningArchive:Decodable {
    let starts:[OpeningStart]
    let moves:[String:[String:Int]]
}
/// Actor-owned cache: decoding and book lookups never block scene input/rendering.
actor OpeningLibrary {
    static let shared=OpeningLibrary()
    private var cached:OpeningArchive?
    func archive() throws->OpeningArchive {
        if let cached {return cached}
        guard let url=Bundle.main.url(forResource:"opening-book",withExtension:"json",subdirectory:"EngineResources") else{throw NSError(domain:"CloudChess.Openings",code:1)}
        let value=try JSONDecoder().decode(OpeningArchive.self,from:Data(contentsOf:url));cached=value;return value
    }
    func continuations(fen:String) throws->[String:Int] {
        let key=fen.split(separator:" ").prefix(4).joined(separator:" ")
        return try archive().moves[key] ?? [:]
    }
    func generate(rating:Double,seed:UInt64,excluding:Set<String>,avoiding:Set<String>=[],skills:[String:PuzzleAbility],progress:((Int) async->Void)?) async throws->TrainingPuzzle {
        let book=try archive();await progress?(3)
        let count=OpeningJudgement.moves(rating:rating)
        // Offline position-based priors shortlist the book; each displayed
        // position receives a fresh full-strength measurement below.
        var ranked:[(OpeningStart,Double)]=[]
        for start in book.starts {
            guard PuzzleVariety.keys(id:"opening-"+start.id,fen:start.fen).isDisjoint(with:avoiding) else{continue}
            let estimate=start.ratingsByMoves?[String(count)] ?? start.rating
            let weakness=skills["opening:"+start.name]?.mean ?? 0.0
            let repetition=excluding.contains("opening-"+start.id) ? 1600.0:0.0
            ranked.append((start,abs(estimate-rating)+weakness*1.4+repetition))
        }
        ranked.sort {a,b in a.1 == b.1 ? a.0.id<b.0.id:a.1<b.1}
        guard !ranked.isEmpty else{throw NSError(domain:"CloudChess.Openings",code:2)}
        let shortlist=Array(ranked.prefix(160)),offset=Int(seed%UInt64(shortlist.count))
        var closest:TrainingPuzzle?,measuredCount=0
        for trial in 0..<24 {
            await progress?(min(7,4+trial/4))
            let s=shortlist[(offset+trial)%shortlist.count].0
            let (state,e)=try await ChallengeEngine.evaluate(initial:s.fen,multipv:3)
            guard state["result"] is NSNull,e.mate==nil,abs(e.cp)<=120 else{continue}
            let estimate=s.rating
            let puzzle=TrainingPuzzle(id:"opening-"+s.id,fen:s.fen,columns:8,rows:8,mate:0,gain:0,plies:count*2-1,rating:estimate,uncertainty:600,complexity:Double(s.ply*5+20),seconds:Double(count*22),tags:["opening", "opening:"+s.name,"eco:"+s.eco,"development","kingSafety"],line:e.line,source:s.name,nodes:ChallengeEngine.nodes,difficultyVersion:"opening-book-v1",challengeType:ChallengeKind.opening.rawValue,initialEvaluation:e.cp,sourceURL:"https://github.com/lichess-org/chess-openings")
            let measured=try ModeDifficulty.calibrated(puzzle,response:state);measuredCount+=1
            if closest==nil || abs(measured.rating-rating)<abs(closest!.rating-rating) {closest=measured}
            if abs(measured.rating-rating)<=225 {return measured}
            if measuredCount>=4 {return closest!}
        }
        if let closest {return closest}
        throw NSError(domain:"CloudChess.Openings",code:3,userInfo:[NSLocalizedDescriptionKey:"No opening passed the engine check. Try again."])
    }
}

actor ChallengeBank {
    static let shared=ChallengeBank()
    private var cached:[TrainingPuzzle]?
    func load()throws->[TrainingPuzzle] {
        if let cached {return cached}
        var resource=Bundle.main.url(forResource:"challenge-starts",withExtension:"json",subdirectory:"EngineResources")
        #if DEBUG
        if resource==nil,let path=ProcessInfo.processInfo.environment["CC_CHALLENGE_BANK_PATH"] {resource=URL(fileURLWithPath:path)}
        #endif
        guard let url=resource,
              let data=try? Data(contentsOf:url),let bank=try? JSONDecoder().decode([TrainingPuzzle].self,from:data) else {throw NSError(domain:"CloudChess.Challenge",code:3,userInfo:[NSLocalizedDescriptionKey:"Missing challenge positions"])}
        cached=bank;return bank
    }
}

/// Identical grading in foreground and speculative work. All assessments retain
/// the complete history and full node budgets; book frequency only ranks work.
enum TurnAnalysis {
    /// A frozen opponent decision belongs to one exact turn and Elo. This is a
    /// one-shot prepared move, not a global cache of limited-strength searches.
    struct PreparedReply {
        let initial:String,history:[String],elo:Double,move:String
        func matches(initial:String,history:[String],elo:Double,legal:[String])->Bool {
            self.initial==initial && self.history==history && self.elo==elo && legal.contains(move)
        }
    }
    /// Exact current turn or a certified candidate's immediate future. No FEN-only
    /// matching: histories, root constraints and full budgets remain distinct.
    static func keepsPreparation(_ r:[String:Any],puzzle:TrainingPuzzle,history:[String],known:Set<String>,source:String?,move:String?,replies:[String:String]=[:])->Bool {
        if puzzle.kind == .tactics {
            guard let candidate=r["candidate"] as? String,
                  move.map({$0==candidate}) ?? source.map({candidate.hasPrefix($0)}) ?? false else{return false}
            var expected=puzzle.request("judge",moves:history)
            expected["candidate"]=candidate;expected["budget"]=1_000_000
            return NSDictionary(dictionary:expected).isEqual(to:r)
        }
        guard puzzle.kind != .whosWinning,
              r["action"] as? String == "analyse",r["initial"] as? String == puzzle.fen,
              [ChallengeEngine.nodes,8_000_000].contains(r["nodes"] as? Int ?? 0) else{return false}
        func matches(_ candidate:String)->Bool {move.map{$0==candidate} ?? source.map{candidate.hasPrefix($0)} ?? false}
        let searched=r["moves"] as? [String] ?? []
        if searched==history {
            guard let root=r["root"] as? String else{return true}
            return matches(root)
        }
        let extra=searched.count-history.count
        if extra==2,(puzzle.kind == .tenMoves || puzzle.kind == .finish),r["root"]==nil,
           Array(searched.prefix(history.count))==history {
            let candidate=searched[history.count]
            return known.contains(candidate) && matches(candidate) && replies[candidate]==searched.last
        }
        guard (extra==1 && puzzle.kind == .blunderPunish) || (extra==2 && (puzzle.kind == .opening || puzzle.kind == .personal)),
              Array(searched.prefix(history.count))==history else{return false}
        let candidate=searched[history.count]
        return known.contains(candidate) && matches(candidate)
    }
    struct Decision {
        let best:EngineAssessment
        let played:EngineAssessment
        let rejected:Bool
        let deepRecheck:Bool
        var loss:Double {best.cp-played.cp}
    }
    static func assess(_ kind:ChallengeKind,initial:String,history:[String],move:String,baseline:EngineAssessment?=nil) async throws->Decision {
        let best:EngineAssessment
        if let baseline {best=baseline}
        else {best=try await ChallengeEngine.evaluate(initial:initial,moves:history,multipv:history.isEmpty ? 3:1).1}
        let played=move==best.line.first ? best:try await ChallengeEngine.evaluate(initial:initial,moves:history,root:move).1
        if kind == .opening,OpeningJudgement.punishes(best:best.cp,played:played.cp) {
            let deepBest=try await ChallengeEngine.evaluate(initial:initial,moves:history,budget:8_000_000).1
            let deepPlayed=try await ChallengeEngine.evaluate(initial:initial,moves:history,root:move,budget:8_000_000).1
            return Decision(best:deepBest,played:deepPlayed,rejected:OpeningJudgement.punishes(best:deepBest.cp,played:deepPlayed.cp),deepRecheck:true)
        }
        return Decision(best:best,played:played,rejected:kind == .personal && best.cp-played.cp>20,deepRecheck:false)
    }
    /// Reuse only the legal reply following this exact played root in its fully
    /// analyzed PV. A book move is never accepted solely because it is in a book.
    static func reply(move:String,assessment:EngineAssessment,legal:[String])->String? {
        guard assessment.line.count>1,assessment.line[0]==move,legal.contains(assessment.line[1]) else{return nil}
        return assessment.line[1]
    }
    static func candidates(best:String?,book:[String:Int],legal:[String],alternatives:[String]=[],limit:Int=3)->[String] {
        let ranked=book.sorted{$0.value == $1.value ? $0.key<$1.key:$0.value>$1.value}.map(\.key)
        var result:[String]=[]
        for move in [best].compactMap({$0})+ranked+alternatives where legal.contains(move) && !result.contains(move) {
            result.append(move);if result.count>=max(1,limit){break}
        }
        return result
    }
}

// MARK: - Position judgment

enum JudgmentVerdict:String,Codable,CaseIterable {
    case white,black,even
    static func classify(_ whiteCP:Double)->Self {whiteCP>50 ? .white:(whiteCP < -50 ? .black:.even)}
    /// Independent, reproducible uniform draws. Unlike balancing in groups of
    /// three, previous answers never reveal the next answer by elimination.
    static func draw(_ index:Int)->Self {
        var input=UInt64(max(0,index))
        while true {
            var z=input &+ 0x9e3779b97f4a7c15
            z=(z^(z>>30)) &* 0xbf58476d1ce4e5b9;z=(z^(z>>27)) &* 0x94d049bb133111eb;z ^= z>>31
            if z<UInt64.max {return [.white,.black,.even][Int(z%3)]}
            input &+= 1
        }
    }
}
struct JudgmentPosition:Codable {
    var id:String,initial:String,history:[String],fen:String
    var whiteCP:Double,screenCP:Double,verdict:JudgmentVerdict,rating:Double,material:Double
    var capturedWhite:[String],capturedBlack:[String],line:[String],nodes:Int,source:String,game:String
}
enum CapturedMaterial {
    struct Group:Identifiable {
        let kind:String,count:Int,white:Bool
        var id:String {kind}
        var name:String {["P":"pawn","N":"knight","B":"bishop","R":"rook","Q":"queen"][kind]!}
    }
    // Engine arrays are named for the capturing side, and their letters encode
    // type only. Every displayed trophy therefore belongs to the opposite side.
    static func groups(_ pieces:[String],capturedByWhite:Bool)->[Group] {
        ["Q","R","B","N","P"].compactMap {kind in
            let count=pieces.filter{$0.uppercased()==kind}.count
            return count>0 ? Group(kind:kind,count:count,white:!capturedByWhite):nil
        }
    }
    static func value(_ pieces:[String])->Int {pieces.reduce(0){$0+(["p":1,"n":3,"b":3,"r":5,"q":9][ $1.lowercased()] ?? 0)}}
}
actor JudgmentLibrary {
    static let shared=JudgmentLibrary()
    private var archive:[JudgmentPosition]?
    func load()throws->[JudgmentPosition] {
        if let archive {return archive}
        let path=ProcessInfo.processInfo.environment["CC_JUDGMENT_PATH"].map{URL(fileURLWithPath:$0)}
        guard let url=path ?? Bundle.main.url(forResource:"judgment-positions",withExtension:"json",subdirectory:"EngineResources") else{throw ModeDifficulty.failure("Missing judgment positions")}
        let rows=try JSONDecoder().decode([JudgmentPosition].self,from:Data(contentsOf:url));archive=rows;return rows
    }
    func generate(rating:Double,draw:Int,seed:UInt64,excluding:Set<String>,avoiding:Set<String>=[]) async throws->TrainingPuzzle {
        let answer=JudgmentVerdict.draw(draw)
        let ranked=try load().filter{$0.verdict==answer && PuzzleVariety.keys(id:"judgment-"+$0.id,fen:$0.fen).isDisjoint(with:avoiding)}.sorted {
            let a=abs($0.rating-rating)+(excluding.contains("judgment-"+$0.id) ? 3000:0)
            let b=abs($1.rating-rating)+(excluding.contains("judgment-"+$1.id) ? 3000:0)
            return a==b ? $0.id<$1.id:a<b
        }
        guard let first=ranked.first else{throw ModeDifficulty.failure("No verified position for this answer")}
        // Small variety only among equally suitable, unseen difficulties.
        let pool=ranked.filter{abs($0.rating-rating)<=abs(first.rating-rating)+80 && excluding.contains("judgment-"+$0.id)==excluding.contains("judgment-"+first.id)}
        let position=pool[Int(seed%UInt64(pool.count))]
        let state=try await NativeChess.call(["action":"state","initial":position.initial,"moves":position.history])
        guard state["fen"] as? String==position.fen,state["result"] is NSNull,
              state["capturedWhite"] as? [String]==position.capturedWhite,state["capturedBlack"] as? [String]==position.capturedBlack,
              JudgmentVerdict.classify(position.whiteCP)==position.verdict else{throw ModeDifficulty.failure("Judgment position failed verification")}
        var p=TrainingPuzzle(id:"judgment-"+position.id,fen:position.fen,columns:8,rows:8,mate:0,gain:0,plies:1,rating:position.rating,uncertainty:650,complexity:min(100,position.rating/30),seconds:35,tags:["evaluation","materialBalance","positionalJudgment"],line:[],source:position.source,nodes:position.nodes)
        p.challengeType=ChallengeKind.whosWinning.rawValue;p.difficultyVersion="judgment-v1";p.difficultySlope=350;p.judgment=position
        p.initialEvaluation=position.whiteCP*(p.white ? 1:-1)
        return p
    }
}

// MARK: - Blunder opportunity certification

enum BlunderEngine {
    struct Opportunity {let move:String,advantage:Double,loss:Double,line:[String]}
    static func targetTurn(seed:UInt64)->Int {2+Int(seed%2)}
    static func retained(_ solverCP:Double)->Bool {solverCP>50}
    static func find(initial:String,moves:[String],seed:UInt64) async throws->Opportunity? {
        try Task.checkCancellation()
        let key=initial+"|"+moves.joined(separator:" ")+"|"+String(seed)
        if let entry=await BlunderOpportunityCache.shared.get(key) {return entry.value}
        let (state,best)=try await ChallengeEngine.evaluate(initial:initial,moves:moves)
        guard state["result"] is NSNull,let legal=state["legal"] as? [String],legal.count>1 else{return nil}
        // Cheap scouting orders candidates; only full-strength results certify
        // the actual mistake. Never mistake a scout for grading evidence.
        var candidates:[(String,Double)]=[]
        for move in legal.sorted() where move != best.line.first {
            try Task.checkCancellation()
            let e=try await ChallengeEngine.evaluate(initial:initial,moves:moves,root:move,budget:12000).1
            if e.mate==nil,e.cp < -140,best.cp-e.cp>180 {candidates.append((move,e.cp))}
        }
        let desired=260+Double(seed%240)
        candidates.sort {a,b in abs(a.1+desired)==abs(b.1+desired) ? a.0<b.0:abs(a.1+desired)<abs(b.1+desired)}
        for (move,_) in candidates.prefix(6) {
            let e=try await ChallengeEngine.evaluate(initial:initial,moves:moves,root:move).1
            guard e.mate==nil,e.cp<=(-200),best.cp-e.cp>=250 else{continue}
            let opportunity=Opportunity(move:move,advantage:-e.cp,loss:best.cp-e.cp,line:e.line)
            try Task.checkCancellation();await BlunderOpportunityCache.shared.put(key,value:opportunity);return opportunity
        }
        try Task.checkCancellation();await BlunderOpportunityCache.shared.put(key,value:nil)
        return nil
    }
    static func generate(rating:Double,seed:UInt64,opponent:Double,excluding:Set<String>,avoiding:Set<String>=[]) async throws->TrainingPuzzle {
        let pool=try await ChallengeBank.shared.load().filter{$0.kind == .tenMoves && PuzzleVariety.keys(id:"blunder-"+$0.id,fen:$0.fen).isDisjoint(with:avoiding)}
        guard !pool.isEmpty else{throw ModeDifficulty.failure("Missing balanced blunder starts")}
        let sorted=pool.sorted {a,b in
            let ar=intrinsic(opponent:opponent,complexity:a.complexity),br=intrinsic(opponent:opponent,complexity:b.complexity)
            let x=abs(ar-rating)+(excluding.contains("blunder-"+a.id) ? 3000:0),y=abs(br-rating)+(excluding.contains("blunder-"+b.id) ? 3000:0)
            return x==y ? a.id<b.id:x<y
        }
        var selected:TrainingPuzzle?,evidence:EngineAssessment?
        let offset=Int(seed%UInt64(min(5,sorted.count)))
        for attempt in 0..<min(8,sorted.count) {
            let candidate=sorted[(offset+attempt)%sorted.count]
            let (state,e)=try await ChallengeEngine.evaluate(initial:candidate.fen,multipv:3)
            if state["result"] is NSNull,e.mate==nil,abs(e.cp)<=50 {selected=candidate;evidence=e;break}
        }
        guard var p=selected,let e=evidence else{throw ModeDifficulty.failure("No balanced blunder setup passed verification")}
        p.id="blunder-"+p.id
        p.challengeType=ChallengeKind.blunderPunish.rawValue;p.blunderSeed=seed;p.plies=12;p.mate=0;p.gain=0
        p.tags=["blunderPunish","conversion","maintainAdvantage"];p.source="generated:"+p.id
        p.initialEvaluation=e.cp;p.line=e.line;p.calibrationOpponent=opponent
        p.rating=intrinsic(opponent:opponent,complexity:p.complexity);p.uncertainty=650;p.difficultySlope=350
        p.difficultyVersion="blunder-v1";p.successLogits=nil;p.difficultyFeatures=nil;p.seconds=150
        return p
    }
    /// Provisional nominal bot scale, independent of the learner's reported Elo.
    static func intrinsic(opponent:Double,complexity:Double)->Double {min(3000,max(400,50+opponent*0.85+complexity*0.5))}
}

private actor BlunderOpportunityCache {
    struct Entry {let value:BlunderEngine.Opportunity?}
    static let shared=BlunderOpportunityCache()
    private var entries:[String:Entry]=[:],order:[String]=[]
    func get(_ key:String)->Entry? {entries[key]}
    func put(_ key:String,value:BlunderEngine.Opportunity?) {
        if entries[key]==nil {order.append(key)}
        entries[key]=Entry(value:value)
        while order.count>16 {entries.removeValue(forKey:order.removeFirst())}
    }
}

/// Familiar annotation symbols, with our own conservative local-engine criteria.
/// Expected-score conversion is a smooth heuristic, not Chess.com's private model.
enum MoveQuality:String,CaseIterable {
    case brilliant,great,best,excellent,good,book,inaccuracy,mistake,miss,blunder
    var label:String {rawValue.prefix(1).uppercased()+rawValue.dropFirst()}
    var annotation:String? {
        switch self {case .brilliant:return "!!";case .great:return "!";case .inaccuracy:return "?!";case .mistake:return "?";case .blunder:return "??";default:return nil}
    }
    var symbol:String {
        switch self {case .best:return "star.fill";case .excellent:return "hand.thumbsup.fill";case .good:return "checkmark";case .book:return "book.closed.fill";case .miss:return "xmark";default:return ""}
    }
    var rgb:UInt32 {
        switch self {case .brilliant:return 0x19A7A0;case .great:return 0x538CB8;case .best:return 0x70A744;case .excellent:return 0x79A44D;case .good:return 0x80A46C;case .book:return 0xB58D65;case .inaccuracy:return 0xDFA92E;case .mistake:return 0xE18A39;case .miss:return 0xDA716C;case .blunder:return 0xDA4D55}
    }
}
enum MoveQualityJudge {
    static func expected(_ cp:Double,elo:Double)->Double {
        let scale=360-0.06*min(3000,max(400,elo.isFinite ? elo:1100))
        return 1/(1+exp(-min(100000,max(-100000,cp))/scale))
    }
    static func classify(best:Double,played:Double,isBest:Bool,runnerUp:Double?,sacrifice:Bool,book:Bool,elo:Double)->MoveQuality {
        guard best.isFinite,played.isFinite else{return .good}
        let lost=max(0,expected(best,elo:elo)-expected(played,elo:elo))
        let nearBest=best-played<=20 && lost<0.02
        if nearBest,sacrifice,played>=(-50),let alternative=runnerUp,alternative<200 {return .brilliant}
        if nearBest,let alternative=runnerUp,expected(played,elo:elo)-expected(alternative,elo:elo)>=0.10,played>=(-50) {return .great}
        if lost>=0.20 {return .blunder}
        if best>=200,played<=50,lost>=0.10 {return .miss}
        if lost>=0.10 {return .mistake}
        if lost>=0.05 {return .inaccuracy}
        if book && lost<0.02 {return .book}
        if isBest {return .best}
        return lost<0.02 ? .excellent:.good
    }
    static func pieces(_ fen:String)->[String:Character] {
        var result:[String:Character]=[:],rank=8,file=0
        for symbol in fen.split(separator:" ").first ?? "" {
            if symbol=="/" {rank-=1;file=0}
            else if let n=symbol.wholeNumberValue {file+=n}
            else {if file<8 && rank>0 {result["\(UnicodeScalar(97+file)!)\(rank)"]=symbol};file+=1}
        }
        return result
    }
    static func material(_ fen:String,white:Bool)->Int {
        pieces(fen).values.reduce(0){$0+CapturedMaterial.value([String($1)])*($1.isUppercase==white ? 1:-1)}
    }
    static func grade(initial:String,history:[String],move:String,beforeFEN:String,decision:TurnAnalysis.Decision,elo:Double,book:Bool=false) async throws->MoveQuality {
        let best=decision.best,played=decision.played
        var sacrifice=false
        // Replay a short already-verified PV with the native rules, never invent
        // a sacrifice from a hanging piece or a shallow material-only guess.
        if best.cp-played.cp<=20,played.cp>=(-50),best.runnerUpCP.map({$0<200})==true,
           move.count==4,played.line.count>=3,played.line.first==move,
           played.line[1].dropFirst(2).prefix(2)==move.dropFirst(2).prefix(2),
           let piece=pieces(beforeFEN)[String(move.prefix(2))],CapturedMaterial.value([String(piece)])>=3 {
            let after=try await NativeChess.call(["action":"state","initial":initial,"moves":history+Array(played.line.prefix(3))])
            if let fen=after["fen"] as? String {sacrifice=material(fen,white:piece.isUppercase)<=material(beforeFEN,white:piece.isUppercase)-2}
        }
        return classify(best:best.cp,played:played.cp,isBest:best.line.first==move,runnerUp:best.runnerUpCP,sacrifice:sacrifice,book:book,elo:elo)
    }
}
