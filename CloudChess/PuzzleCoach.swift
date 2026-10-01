import Foundation
import CryptoKit

struct TrainingPuzzle:Codable,Identifiable {
    var id:String,fen:String
    var columns:Int,rows:Int,mate:Int,gain:Int,plies:Int
    var rating:Double,uncertainty:Double,complexity:Double,seconds:Double
    var tags:[String],line:[String],source:String
    var nodes:Int
    var difficultyVersion:String?
    var botSuccess:[Double]?
    var challengeType:String?
    var initialEvaluation:Double?
    var sourceURL:String?
    var difficultyFeatures:[Double]?
    var calibrationOpponent:Double?
    var difficultySlope:Double?
    var successLogits:[Double]?
    var judgment:JudgmentPosition?
    var blunderSeed:UInt64?
    static let skillAnchors=[400.0,600,1100,1800,2600,3000]
    func successLogit(at rating:Double)->Double? {
        guard let curve=successLogits,curve.count==6,curve.allSatisfy({$0.isFinite}) else{return nil}
        let elo=min(3000,max(400,rating)),levels=Self.skillAnchors
        for i in 1..<6 where elo<=levels[i] {return curve[i-1]+(curve[i]-curve[i-1])*(elo-levels[i-1])/(levels[i]-levels[i-1])}
        return curve[5]
    }
    var kind:ChallengeKind {ChallengeKind(rawValue:challengeType ?? "") ?? .tactics}
    /// Position identity ignores move counters; alternate IDs cannot bypass recency.
    /// Tactical source identity also covers mirrored/cropped versions of one puzzle.
    var repeatKeys:Set<String> {
        var keys=PuzzleVariety.keys(id:id,fen:fen,columns:columns,rows:rows)
        if kind == .tactics {keys.formUnion(PuzzleVariety.legacyKeys(id))}
        if kind == .tactics,!source.isEmpty {keys.insert("tactical-source:"+source)}
        return keys
    }
    var white:Bool {fen.split(separator:" ")[1]=="w"}
    var family:String {mate==0 ? "improvement":"mate\(min(4,mate))"}
    var solverMoves:Int {(plies+1)/2}
    var compositionBudget:Int {max(18000,min(160000,nodes*2+12000))}
    /// Propose a genuinely new local composition by relocating a supporting
    /// piece. This is ONLY a candidate: the native all-defenses proof must
    /// certify the original objective and a unique root move before it is used.
    func composition(seed:UInt64)->TrainingPuzzle? {
        var cells=[Int:Character](),r=7,f=0
        for ch in fen.split(separator:" ")[0] {
            if ch=="/"{r-=1;f=0}else if let n=ch.wholeNumberValue{f+=n}else{cells[r*8+f]=ch;f+=1}
        }
        let movable=cells.keys.sorted().filter{cells[$0]!.lowercased() != "k"}
        guard !movable.isEmpty else{return nil}
        let source=movable[Int(seed%UInt64(movable.count))],piece=cells[source]!
        let offsets=[(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1),(-1,1),(1,-1)]
        let (dx,dy)=offsets[Int((seed>>8)%8)],x=source%8+dx,y=source/8+dy
        guard x>=0,x<columns,y>=0,y<rows,cells[y*8+x]==nil else{return nil}
        if piece.lowercased()=="p" && (y==0 || y==rows-1){return nil}
        cells.removeValue(forKey:source);cells[y*8+x]=piece
        var ranks:[String]=[]
        for row in (0..<8).reversed(){var rank="",empty=0
            for col in 0..<8 {if let ch=cells[row*8+col]{if empty>0{rank+=String(empty);empty=0};rank.append(ch)}else{empty+=1}}
            if empty>0{rank+=String(empty)};ranks.append(rank)
        }
        var p=self;p.fen=ranks.joined(separator:"/")+(white ? " w":" b")+" - - 0 1"
        p.id=SHA256.hash(data:Data("\(columns)x\(rows):\(p.fen)".utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()+"-c"
        p.uncertainty=max(650,uncertainty);p.difficultyVersion=nil;p.botSuccess=nil;return p
    }
    // Only rule-preserving symmetries: file reflection, rank reflection with
    // color exchange. No arbitrary rotations of directional pawn rules.
    func variant(_ value:Int)->TrainingPuzzle {
        let flipFile=value&1 != 0,flipRank=value&2 != 0
        func square(_ s:String)->String {
            let a=Array(s.utf8),f=Int(a[0])-97,r=Int(a[1])-49
            return String(UnicodeScalar(97+(flipFile ? columns-1-f:f))!)+String(1+(flipRank ? rows-1-r:r))
        }
        var grid=Array(repeating:Array(repeating:Character(" "),count:8),count:8)
        var r=7,f=0
        for ch in fen.split(separator:" ")[0] {
            if ch=="/" {r-=1;f=0}
            else if let n=ch.wholeNumberValue {f+=n}
            else {let x=flipFile ? columns-1-f:f,y=flipRank ? rows-1-r:r
                grid[y][x]=flipRank ? Character(ch.isUppercase ? ch.lowercased():ch.uppercased()):ch;f+=1}
        }
        var ranks:[String]=[]
        for row in grid.reversed() {
            var s="",n=0
            for ch in row {if ch==" "{n+=1}else{if n>0{s+=String(n);n=0};s.append(ch)}}
            if n>0{s+=String(n)};ranks.append(s)
        }
        var p=self;p.id=id+"-\(value&3)"
        p.fen=ranks.joined(separator:"/")+((white != flipRank) ? " w":" b")+" - - 0 1"
        p.line=line.map{square(String($0.prefix(2)))+square(String($0.dropFirst(2).prefix(2)))+String($0.dropFirst(4))}
        return p
    }
    mutating func applyDifficulty(_ certificate:[String:Any])throws {
        guard let d=certificate["difficulty"] as? [String:Any],d["version"] as? String=="challenge-v2",
              let r=d["rating"] as? Double,let u=d["uncertainty"] as? Double,
              let c=d["complexity"] as? Double,let t=d["seconds"] as? Double,
              [r,u,c,t].allSatisfy({$0.isFinite}),r>=400,r<=3000,u>0,u<1000,c>0,c<=100,t>0,
              let success=d["botSuccess"] as? [Double],success.count==3,success.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else {
            throw NSError(domain:"CloudChess.Difficulty",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing measured puzzle difficulty"])
        }
        rating=r;uncertainty=u;complexity=c;seconds=t;difficultyVersion="challenge-v2";botSuccess=success
    }
    func request(_ operation:String="position",moves:[String]=[])->[String:Any] {
        ["action":kind == .tactics ? "puzzle":"state","operation":operation,"initial":fen,"columns":columns,"rows":rows,"mate":mate,"gain":gain,"plies":plies,"moves":moves]
    }
}

/// Portable online Bayesian logistic learner. Ratings are provisional training
/// estimates, not site/FIDE Elo. Independent tag offsets shrink toward zero;
/// uncertainty prevents a single lucky solve or a rare tag dominating selection.
struct PuzzleAbility:Codable {
    var mean:Double=1100,variance:Double=90000
    var evidence:Int=0
}
struct PuzzleAttempt:Codable {
    var id:String,puzzle:String,tags:[String],family:String
    var rating:Double,predicted:Double,seconds:Double
    var mistakes:Int,hints:Int
    var skipped:Bool,clean:Bool
    var source:String?
    var expectedSeconds:Double?
    var difficultyVersion:String?
    var kind:ChallengeKind?
    var opponentElo:Double?
    var succeeded:Bool?
}
struct PuzzleSession:Codable {
    var id=UUID().uuidString
    var puzzle:TrainingPuzzle
    var moves:[String]=[]
    var mistakes=0,hints=0
    var elapsed:Double=0
    var recorded=false
    var reattempt:Bool?
    var evaluation:Double?
    var opponentElo:Double?
    var succeeded:Bool?
    var extraPenalty:Double?
    var undoCount:Int?
    var blunderPly:Int?
    // Optional fields preserve older saves. Hint steps belong to an exact history;
    // their reward discounts survive undo, backgrounding and relaunch.
    var hintPosition:String?
    var hintStage:Int?
    var hintDiscounts:Int?
    var nextHintStage:Int {hintPosition==moves.joined(separator:" ") ? min(3,max(0,hintStage ?? 0))+1:1}
    mutating func revealHint() {
        let stage=nextHintStage
        guard stage<=3 else{return}
        hintPosition=moves.joined(separator:" ");hintStage=stage
        hintDiscounts=min(10000,max(0,hintDiscounts ?? 0)+1);hints+=1
    }
    var reward:Double {ChallengeScore.value(rating:puzzle.rating,kind:puzzle.kind)*(reattempt == true ? 0.5:1)*pow(0.8,Double(max(0,undoCount ?? 0)))*pow(0.9,Double(max(0,hintDiscounts ?? 0)))}
    @discardableResult mutating func undoLastDecision()->Bool {
        guard !moves.isEmpty,succeeded != true else{return false}
        // A failed, settled attempt can be tried again without recharging its
        // old mistakes or replaying a previously granted success reward.
        if recorded {id=UUID().uuidString;recorded=false;succeeded=nil;mistakes=0;extraPenalty=nil}
        moves.removeLast(moves.count%2==0 ? 2:1)
        if let injected=blunderPly,moves.count<injected {blunderPly=nil}
        undoCount=min(10000,max(0,undoCount ?? 0))+1
        hints+=1
        return true
    }
    var instructionType:String {puzzle.kind == .tactics ? (puzzle.mate>0 ? "mate":"improvement"):puzzle.kind.rawValue}

}
struct PuzzleReview:Codable {var puzzle:TrainingPuzzle;var due:Int}

enum PuzzleVariety {
    static func legacyKeys(_ id:String)->[String] {
        var base=id
        while let dash=base.lastIndex(of:"-"),["0","1","2","3"].contains(String(base[base.index(after:dash)...])) {base=String(base[..<dash])}
        return [id,"tactical-id:"+base]
    }
    static func keys(id:String,fen:String,columns:Int=8,rows:Int=8)->Set<String> {
        [id,"position:\(columns)x\(rows):"+fen.split(separator:" ").prefix(4).joined(separator:" ")]
    }
}

struct AdaptivePuzzleCoach:Codable {
    var difficultyVersion:String?
    var challengeMode:ChallengeKind?
    var scoring:ChallengeScore?
    var introductions:Set<String>?
    var collection:CollectionProgress?
    var recentChallengeKinds:[ChallengeKind]?
    var recentPuzzleKeys:[[String]]?
    var judgmentDraws:Int?
    var adaptationVersion:String?
    var modeSkills:[String:PuzzleAbility]?
    var previousOpponents:[String:Double]?
    func modeAbility(_ kind:ChallengeKind)->Double {
        min(3000,max(350,ability.mean+(modeSkills?[kind.rawValue]?.mean ?? 0)))
    }
    var currentScore:Double {
        let penalty=session.map{$0.recorded ? 0:ChallengeScore.penalty($0)} ?? 0
        return max(0,(scoring?.total ?? 0)-penalty)
    }
    /// Score is progression pressure, not evidence that the player gained Elo.
    /// Keep the Bayesian skill estimate separate for honest outcome learning.
    func challengeLevel(_ kind:ChallengeKind)->Double {
        let score=currentScore.isFinite ? min(1e12,currentScore):0
        let progression=850+300*log2(1+score/100000)
        return min(3000,max(400,0.75*progression+0.25*modeAbility(kind)))
    }
    func targetRating(for kind:ChallengeKind)->Double {
        let goal=target(for:kind)
        return min(3000,max(400,challengeLevel(kind)-240*log(goal/(1-goal))))
    }
    /// Strength is chosen once, before rating/points, and held for the puzzle.
    /// Shared ability transfers learning; mode offsets remember local struggle.
    func opponentRating(for kind:ChallengeKind)->Double {
        let desired=max(100,min(3000,kind == .blunderPunish ? challengeLevel(kind):targetRating(for:kind)-(kind == .finish ? 150:0)))
        guard let last=previousOpponents?[kind.rawValue] else{return desired}
        return min(last+180,max(last-220,desired))
    }
    func opponentBounds(for kind:ChallengeKind)->ClosedRange<Double> {
        guard let previous=previousOpponents?[kind.rawValue] else{return 100...3000}
        let last=attempts.last{($0.kind ?? .tactics)==kind}
        let lost=last?.skipped==true
        let mastered=last?.succeeded==true && last?.hints==0
        let lower=mastered ? min(3000,previous+40):max(100,previous-220)
        let upper=lost ? max(100,previous-60):min(3000,previous+180)
        return lower...upper
    }
    var previousChallengeKind:ChallengeKind? {
        session?.puzzle.kind ?? recentChallengeKinds?.last ?? attempts.last?.kind
    }
    var blockedPuzzleKeys:Set<String> {
        // Older saves retain their last three IDs; the current session also has
        // enough information to protect its position and tactical symmetries.
        var keys=Set((recentPuzzleKeys ?? seen.suffix(3).map{PuzzleVariety.legacyKeys($0)}).suffix(3).flatMap{$0})
        if let p=session?.puzzle {keys.formUnion(p.repeatKeys)}
        return keys
    }
    func allowsNextPuzzle(_ p:TrainingPuzzle)->Bool {p.repeatKeys.isDisjoint(with:blockedPuzzleKeys)}
    mutating func selectChallengeKind(personalAvailable:Bool)->ChallengeKind {
        let pool=ChallengeKind.allCases.filter{(personalAvailable || $0 != .personal) && $0 != previousChallengeKind}
        // Uniform among the eligible alternatives, without predictable cycles.
        // Only begin() commits history; failed or speculative draws never do.
        let count=UInt64(pool.count),limit=UInt64.max-UInt64.max%count
        var draw=nextRandom();while draw>=limit {draw=nextRandom()}
        return pool[Int(draw%count)]
    }

    var remainingHearts:Int {guard let s=session,s.puzzle.kind.usesHearts else{return 0};return max(0,3-s.mistakes)}
    @discardableResult mutating func mistakenMove()->Bool {
        guard session?.recorded==false else{return false}
        session?.mistakes+=1
        return session?.puzzle.kind.usesHearts==true && remainingHearts==0
    }
    var ability=PuzzleAbility()
    var skills:[String:PuzzleAbility]=[:]
    var shapes:[String:PuzzleAbility]=[:]
    var priors:[String:Double]=[:]
    var attempts:[PuzzleAttempt]=[]
    var total=0,streak=0,sequence:UInt64=0
    var seen:[String]=[],reviews:[PuzzleReview]=[]
    var pace:Double=1
    var session:PuzzleSession?
    // nil means a curated mix of rectangular and square boards.
    var preferredColumns:Int?,preferredRows:Int?
    static func sigmoid(_ x:Double)->Double {1/(1+exp(-min(30,max(-30,x))))}
    func shape(_ p:TrainingPuzzle)->String {"\(p.columns)x\(p.rows)"}
    func tagAbility(_ tag:String)->PuzzleAbility {skills[tag] ?? PuzzleAbility(mean:0,variance:22500)}
    func probability(_ p:TrainingPuzzle,level:Double?=nil)->Double {
        let learner=level ?? modeAbility(p.kind)
        if p.kind != .tactics,let logit=p.successLogit(at:learner) {return Self.sigmoid(logit)}
        let offsets=p.tags.map{tagAbility($0).mean}
        let tagMean=offsets.reduce(0,+)/sqrt(Double(max(1,offsets.count)))
        let shapeMean=shapes[shape(p)]?.mean ?? 0
        // Unknown item difficulty increases predictive uncertainty, rather than
        // pretending our source-trained mini-board ratings are calibrated.
        let scale=sqrt(174*174+(ability.variance+pow(min(500,p.uncertainty)*0.35,2))*0.20)
        // Long-game/opening ratings already model their geometry and mode.
        // Do not let generic tags such as "opening" absorb the same evidence a
        // second time and silently hold back the next opponent's strength.
        let context=p.kind == .tactics ? tagMean+shapeMean:0
        return Self.sigmoid((learner+context-p.rating)/max(120,p.difficultySlope ?? scale))
    }
    func weakness(_ tag:String)->Double {
        let s=tagAbility(tag)
        let local=max(0,-s.mean)/240*Double(s.evidence)/Double(s.evidence+3)
        let imported=min(0.6,max(0,priors[tag] ?? 0))*exp(-Double(s.evidence)/12)
        return min(1,max(local,imported))
    }
    var target:Double {target(for:.tactics)}
    func target(for kind:ChallengeKind)->Double {
        let history=attempts.filter{($0.kind ?? .tactics)==kind}
        let recent=history.suffix(4)
        let modeStreak=history.reversed().prefix(while:{$0.clean}).count
        let quick=recent.filter{$0.clean && $0.seconds>0 && $0.seconds<max(10,($0.expectedSeconds ?? 45)*0.45)}.count
        if quick>=3 || (modeStreak>=2 && quick>=2) {return 0.52}
        if modeStreak>=3 {return 0.58}
        // A corrected first mistake is useful evidence, not a reason to send
        // the player back to trivial exercises. Repeated struggle still eases.
        if history.suffix(3).filter({$0.skipped || $0.hints>0 || (kind.usesHearts && $0.mistakes>=2)}).count>=2 {return 0.78}
        return 0.67
    }
    mutating func migrateDifficulty() {
        // Retain history, frozen points and opponent when upgrading an active drill.
        if session?.puzzle.kind == .tenMoves {session?.puzzle.plies=ImprovementChallenge.plies}

        if adaptationVersion != "all-modes-v3" {
            for i in attempts.indices where attempts[i].kind==nil {
                let v=attempts[i].difficultyVersion ?? ""
                attempts[i].kind=v.hasPrefix("opening") ? .opening:(v.hasPrefix("personal") ? .personal:(v=="open-play-v1" ? (attempts[i].tags.contains("conversion") ? .finish:.tenMoves):.tactics))
            }
            adaptationVersion="all-modes-v3"
        }
        guard difficultyVersion != "challenge-v2" else{return}
        // Keep history, current puzzle and the player's estimate. A changed
        // item scale warrants renewed uncertainty, not erasing their progress.
        ability.variance=max(90000,ability.variance);difficultyVersion="challenge-v2"
    }
    func acceptsComposition(_ p:TrainingPuzzle,from parent:TrainingPuzzle)->Bool {
        p.difficultyVersion=="challenge-v2" && p.rating>=parent.rating-175 && p.rating<=parent.rating+250 && abs(probability(p,level:challengeLevel(.tactics))-target)<=max(0.16,abs(probability(parent,level:challengeLevel(.tactics))-target)+0.04)
    }
    mutating func importProfile(_ report:[String:Any]) {
        priors=(report["trainingPrior"] as? [String:Double] ?? [:]).mapValues{min(0.6,max(0,$0))}
        guard total==0,let ratings=report["ratings"] as? [String:[String:Any]] else{return}
        let estimate=["rapid","blitz","classical","bullet"].compactMap{ratings[$0]?["performanceEstimate"] as? Double}.first
        if let estimate,estimate.isFinite {ability.mean=min(1800,max(700,0.5*estimate+550));ability.variance=160000}
    }
    mutating func nextRandom()->UInt64 {
        sequence &+= 0x9e3779b97f4a7c15
        var z=sequence;z=(z^(z>>30)) &* 0xbf58476d1ce4e5b9;z=(z^(z>>27)) &* 0x94d049bb133111eb;return z^(z>>31)
    }
    func eligibleReview(_ review:PuzzleReview)->Bool {
        let p=probability(review.puzzle,level:challengeLevel(.tactics))
        return allowsNextPuzzle(review.puzzle) && review.due<=total && p>=0.25 && p<=0.95 && (preferredColumns==nil || (review.puzzle.columns==preferredColumns && review.puzzle.rows==preferredRows))
    }
    mutating func candidates(_ bank:[TrainingPuzzle])->[TrainingPuzzle] {
        let blocked=blockedPuzzleKeys
        let eligible=bank.filter{$0.repeatKeys.isDisjoint(with:blocked) && (preferredColumns==nil || ($0.columns==preferredColumns && $0.rows==preferredRows))}
        let recent=Set(seen.suffix(4000)),recentSources=Set(attempts.suffix(12).map{$0.source ?? $0.puzzle.components(separatedBy:"-")[0]})
        let lastFamily=attempts.last?.family,seed=nextRandom()
        let desired=target,targetLogOdds=log(desired/(1-desired)),selectionLevel=challengeLevel(.tactics)
        // Randomize deterministically BEFORE scoring so ties don't repeat one
        // tiny motif; final sorting has a stable ID tie-break.
        var ranked:[(Double,Int,TrainingPuzzle)]=[]
        var metrics:[String:(mean:Double,focus:Double,uncertainty:Double)]=[:]
        let shapeOffsets=shapes.mapValues(\.mean)
        for (i,base) in eligible.enumerated() {
            // Rating/features are invariant under these symmetries. Rank the
            // lightweight descriptors first; build only shortlisted boards.
            let p=base,v=Int((seed &+ UInt64(i))%4),id=base.id+"-\(v)"
            var focus=0.0,offset=0.0,uncertaintySum=0.0
            for tag in p.tags {
                let metric:(mean:Double,focus:Double,uncertainty:Double)
                if let cached=metrics[tag] {metric=cached} else {
                    let a=tagAbility(tag);metric=(a.mean,weakness(tag),sqrt(a.variance)/300);metrics[tag]=metric
                }
                focus=max(focus,metric.focus);offset+=metric.mean;uncertaintySum+=metric.uncertainty
            }
            let uncertainty=uncertaintySum/Double(max(1,p.tags.count))
            let probability:Double
            if p.kind == .tactics {
                let context=offset/sqrt(Double(max(1,p.tags.count)))+(shapeOffsets[shape(p)] ?? 0)
                let scale=sqrt(174*174+(ability.variance+pow(min(500,p.uncertainty)*0.35,2))*0.20)
                probability=Self.sigmoid((selectionLevel+context-p.rating)/max(120,p.difficultySlope ?? scale))
            } else {probability=self.probability(p,level:selectionLevel)}
            // Probability distances saturate near 100% and make easy items
            // indistinguishable to a strong player. Log odds retain distance
            // from the target and choose the hardest available at the ceiling.
            let bounded=min(1-1e-12,max(1e-12,probability))
            let mismatch=abs(log(bounded/(1-bounded))-targetLogOdds)/4
            var score=mismatch-0.12*focus-0.025*uncertainty
            if recent.contains(id){score+=2}
            if recentSources.contains(base.source){score+=0.6}
            if lastFamily==p.family {score+=0.055}
            // Gentle seeded variety among equally appropriate exercises.
            score+=Double((seed &+ UInt64(i)*7919)%1000)/50000
            ranked.append((score,v,p))
        }
        ranked.sort{$0.0 == $1.0 ? $0.2.id<$1.2.id:$0.0<$1.0}
        var picks=Array(ranked.lazy.map{$0.2.variant($0.1)}.filter{$0.repeatKeys.isDisjoint(with:blocked)}.prefix(16))
        if total%4==3,let review=reviews.first(where:{eligibleReview($0)}) {picks.insert(review.puzzle,at:0)}
        return picks
    }
    mutating func begin(_ p:TrainingPuzzle) {
        recentPuzzleKeys=Array(((recentPuzzleKeys ?? seen.suffix(3).map{PuzzleVariety.legacyKeys($0)})+[p.repeatKeys.sorted()]).suffix(3))
        recentChallengeKinds=Array(((recentChallengeKinds ?? [])+[p.kind]).suffix(12))
        if p.kind == .whosWinning {judgmentDraws=(judgmentDraws ?? 0)+1}
        session=PuzzleSession(puzzle:p);session?.reattempt=seen.contains(p.id);session?.evaluation=p.initialEvaluation
        let opponent=p.calibrationOpponent ?? opponentRating(for:p.kind)
        session?.opponentElo=opponent
        if !p.kind.usesHearts {
            if previousOpponents==nil {previousOpponents=[:]}
            previousOpponents?[p.kind.rawValue]=opponent
        }
        seen.append(p.id);if seen.count>8000{seen.removeFirst(seen.count-8000)}
    }
    // Idempotent across app suspension, retries, and a relaunch during confetti.
    @discardableResult mutating func finish(skipped:Bool=false)->Bool {
        guard var s=session,!s.recorded,!attempts.contains(where:{$0.id==s.id}) else{return false}
        let p=s.puzzle,clean = !skipped && s.mistakes==0 && s.hints==0
        var score=scoring ?? ChallengeScore();score.settle(s,success:!skipped);scoring=score;s.succeeded = !skipped
        let predicted=probability(p)
        // Winning a long game with a corrected slip is still a win. Assistance
        // discounts mastery; free open-play errors reduce confidence, not outcome.
        let unassistedWin = !skipped && s.hints==0 && (!p.kind.usesHearts || s.mistakes==0)
        let outcome=unassistedWin ? 1.0:0.0
        let expected=max(8,p.seconds*pace*(0.65+p.complexity/140))
        let timeRatio=min(6,max(0.15,s.elapsed/expected))
        // Slow correct answers still count as correct. Time only changes update
        // strength modestly; hints/undo never masquerade as clean mastery.
        let lost=skipped && ((s.extraPenalty ?? 0)>=1.75 || (p.kind.usesHearts && s.mistakes>=3))
        let baseWeight=skipped ? (lost ? 1.0:0.55):(clean ? (timeRatio<0.45 ? 1.55:min(1.15,max(0.85,1.15-0.12*log(max(1,timeRatio))))):(s.mistakes==1 && s.hints==0 ? 0.48:0.85))
        let openQuality=max(0.45,1-Double(s.mistakes)/Double(max(1,(s.moves.count+1)/2)))
        let weight = !p.kind.usesHearts && unassistedWin ? max(0.55,openQuality):baseWeight
        func update(_ a:inout PuzzleAbility,share:Double,limit:Double) {
            let variance=min(160000,a.variance+225)
            let scale=240.0
            let next=1/(1/variance+weight*predicted*(1-predicted)*share*share/(scale*scale))
            let delta=max(-limit,min(limit,next*weight*share*(outcome-predicted)/scale))
            a.mean+=delta;a.variance=max(2500,next);a.evidence+=1
        }
        update(&ability,share:p.kind == .tactics ? 0.85:0.55,limit:95);ability.mean=min(3000,max(350,ability.mean))
        if p.kind != .tactics {
            var local=modeSkills?[p.kind.rawValue] ?? PuzzleAbility(mean:0,variance:62500)
            update(&local,share:0.75,limit:65);local.mean=min(500,max(-500,local.mean))
            if modeSkills==nil {modeSkills=[:]};modeSkills?[p.kind.rawValue]=local
        }
        let tagShare=0.45/sqrt(Double(max(1,p.tags.count)))
        for tag in p.tags {var a=tagAbility(tag);update(&a,share:tagShare,limit:32);a.mean=min(400,max(-400,a.mean));skills[tag]=a}
        let key=shape(p);var a=shapes[key] ?? PuzzleAbility(mean:0,variance:14400)
        update(&a,share:0.25,limit:20);a.mean=min(250,max(-250,a.mean));shapes[key]=a
        if clean,s.elapsed>1 {pace=0.94*pace+0.06*min(3,max(0.4,s.elapsed/max(8,p.seconds)))}
        reviews.removeAll{$0.puzzle.id==p.id}
        if !clean,p.kind == .tactics {reviews.append(PuzzleReview(puzzle:p,due:total+7));if reviews.count>128{reviews.removeFirst()}}
        attempts.append(PuzzleAttempt(id:s.id,puzzle:p.id,tags:p.tags,family:p.family,rating:p.rating,predicted:predicted,seconds:s.elapsed,mistakes:s.mistakes,hints:s.hints,skipped:skipped,clean:clean,source:p.source,expectedSeconds:expected,difficultyVersion:p.difficultyVersion,kind:p.kind,opponentElo:s.opponentElo,succeeded:!skipped))
        if attempts.count>2000 {attempts.removeFirst()}
        total+=1;streak=clean ? streak+1:0;s.recorded=true;session=s;return true
    }
}

/// One FIFO writer for immutable coach snapshots. Encoding and atomic file I/O
/// run off the main thread; acknowledged move saves still finish before grading.
// URL is immutable; all filesystem access is serialized by writer.
final class PuzzleCoachStore: @unchecked Sendable {
    let url:URL
    private let writer=DispatchQueue(label:"CloudChess.coachPersistence",qos:.userInitiated)
    init(testing:Bool) {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        url=root.appendingPathComponent("CloudChess/\(testing ? "test-":"")puzzle-coach-v1.json")
    }
    init(url:URL) {self.url=url}
    func load()throws->AdaptivePuzzleCoach {
        try writer.sync {
            guard FileManager.default.fileExists(atPath:url.path) else{return AdaptivePuzzleCoach()}
            return try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:Data(contentsOf:url))
        }
    }
    private func write(_ coach:AdaptivePuzzleCoach)throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(coach).write(to:url,options:.atomic)
    }
    // Only lifecycle flushes and portable callers need the synchronous barrier.
    func save(_ coach:AdaptivePuzzleCoach)throws {try writer.sync {try write(coach)}}
    func enqueue(_ coach:AdaptivePuzzleCoach,completion:@escaping (Result<Void,Error>)->Void) {
        writer.async {completion(Result {try self.write(coach)})}
    }
    func reset() async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            writer.async {
                do {
                    if FileManager.default.fileExists(atPath:self.url.path) {try FileManager.default.removeItem(at:self.url)}
                    continuation.resume()
                } catch {continuation.resume(throwing:error)}
            }
        }
    }
}

/// Keep the persisted `tenMoves` identifier so progress/instructions survive updates.
enum ImprovementChallenge {
    static let turns=6
    static let plies=turns*2
    static func isComplete(plies:Int)->Bool {plies>=self.plies}
}

enum ChallengeKind:String,Codable,CaseIterable,Identifiable {
    case tactics,finish,tenMoves,personal,opening,blunderPunish,whosWinning
    var id:String {rawValue}
    var usesHearts:Bool {self != .finish && self != .tenMoves && self != .blunderPunish}
    var rewardMultiplier:Double {self == .finish ? 3:(self == .tenMoves ? 2.5:(self == .blunderPunish ? 2:1))}
    var title:String {
        switch self {case .tactics:return "Tactical puzzles";case .finish:return "Finish the job";case .tenMoves:return "Improve your position in 6 moves";case .personal:return "From one of your games";case .opening:return "Opening drill";case .blunderPunish:return "Punish the blunder";case .whosWinning:return "Who’s winning?"}
    }
    func explanation(mate:Int=0,plies:Int=0)->String {
        switch self {
        case .tactics:return mate>0 ? "Checkmate in \(mate) moves. Find the winning continuation." : "Win material within \((plies+1)/2) moves. Find the winning continuation."
        case .finish:return "You're ahead. Win the game against a slightly easier opponent. Any legal move is allowed."
        case .tenMoves:return "You have 6 moves to improve an equal position. Any legal moves count; your final position decides."
        case .personal:return "Replay a missed opportunity from your game. Find a strong continuation; equivalent moves count."
        case .opening:return "Play \((plies+1)/2) sound opening moves. Different book moves and other good continuations count. Only clear mistakes cost an attempt."
        case .blunderPunish:return "Keep the game balanced. After 2–3 turns, your opponent will blunder. Punish it and keep your advantage for your next 3 moves."
        case .whosWinning:return "Choose which side has the better position, or Even. Within half a pawn is even. Material alone does not decide the answer."
        }
    }
}

/// Each penalty is settled once; best is a lifetime maximum, never a run reset.
struct ChallengeScore:Codable {
    var total:Double=0,best:Double=0
    var completed:Set<String>=[]
    static func value(rating:Double,kind:ChallengeKind = .tactics)->Double {pow(max(400,min(3000,rating.isFinite ? rating:400)),1.5)*kind.rewardMultiplier}
    static func penalty(_ s:PuzzleSession)->Double {
        value(rating:s.puzzle.rating,kind:s.puzzle.kind)*((s.puzzle.kind.usesHearts ? Double(max(0,s.mistakes))*0.25:0)+max(0,s.extraPenalty ?? 0))
    }
    static func delta(rating:Double,mistakes:Int,retry:Bool,success:Bool,extraPenalty:Double=0,kind:ChallengeKind = .tactics)->Double {
        value(rating:rating,kind:kind)*((success ? (retry ? 0.5:1):0)-(kind.usesHearts ? Double(max(0,mistakes))*0.25:0)-max(0,extraPenalty))
    }
    mutating func settle(_ s:PuzzleSession,success:Bool) {
        guard completed.insert(s.id).inserted else{return}
        best=max(best,max(0,total))
        total=max(0,total-Self.penalty(s))+(success ? s.reward:0)
        best=max(best,total)
    }
}

/// Deliberately forgiving: a small centipawn preference is not a failed drill.
enum OpeningJudgement {
    static let tolerance=100.0
    static func moves(rating:Double)->Int {rating<1300 ? 3:(rating<1900 ? 4:5)}
    static func punishes(best:Double,played:Double)->Bool {best.isFinite && played.isFinite && best-played>tolerance}
}
