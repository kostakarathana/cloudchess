import Foundation

/// Difficulty measured from complete mode rollouts, independently of the learner.
/// The bot scale is a training estimate, not a certified human/site Elo rating.
enum ModeDifficulty {
    static let version="mode-bots-v3"
    static let improvementVersion="mode-bots-v3-six-v1"
    static let kinds:[ChallengeKind]=[.finish,.tenMoves,.personal,.opening]
    struct Node:Decodable {let f:Int,t:Double,v:Double,l:Int,r:Int,leaf:Bool}
    struct ImprovementCalibration:Decodable {let scale:Double,bias:Double,samples:Int}
    /// Exact anchor values only; each decoded model owns an isolated bounded cache.
    final class AnchorCache {
        private let lock=NSLock()
        private var values:[[Double]:[Double]]=[:]
        private var order:[[Double]]=[]
        func curve(_ key:[Double],compute:()->[Double])->[Double] {
            lock.lock();if let value=values[key] {lock.unlock();return value};lock.unlock()
            let value=compute()
            lock.lock();defer{lock.unlock()}
            if values[key]==nil {
                values[key]=value;order.append(key)
                if order.count>1024 {values.removeValue(forKey:order.removeFirst())}
            }
            return value
        }
    }
    struct Model:Decodable {
        private enum CodingKeys:String,CodingKey {case version,intercept,temperature,bias,nodes,roots,uncertainty,improvement}
        private let anchors=AnchorCache()
        private func anchor(_ features:[Double])->[Double] {
            anchors.curve(features){TrainingPuzzle.skillAnchors.map{raw(features+[$0/1000])}}
        }
        let version:String,intercept:Double,temperature:Double,bias:Double
        let nodes:[Node],roots:[Int],uncertainty:[String:Double]
        let improvement:ImprovementCalibration?
        func raw(_ input:[Double])->Double {
            var x=input
            // The original forest saw ten-turn outcomes. Reuse its position
            // ordering, then apply the held-out six-turn probability calibration.
            let sixTurns=x[1]==1 && abs(x[14]-0.6)<0.00001
            if sixTurns {x[14]=1}

            var value=intercept
            for root in roots {
                var i=root
                while !nodes[i].leaf {let n=nodes[i];i=x[n.f]<=n.t ? n.l:n.r}
                value+=nodes[i].v
            }
            let original=value*temperature+bias
            if sixTurns,let improvement {return original*improvement.scale+improvement.bias}
            return original
        }
        // Interpolate calibrated logits between measured solver levels. A tree's
        // split boundary is not a real discontinuity in a person's chess skill.
        func logit(_ features:[Double],at rating:Double)->Double {
            let values=curve(features),levels=TrainingPuzzle.skillAnchors,elo=min(3000,max(400,rating))
            for i in 1..<levels.count where elo<=levels[i] {
                return values[i-1]+(values[i]-values[i-1])*(elo-levels[i-1])/(levels[i]-levels[i-1])
            }
            return values[5]
        }
        func curve(_ features:[Double])->[Double] {
            // The opponent's strength is continuous too. Interpolate only
            // between measured anchors, retaining monotonicity in both axes.
            let opponents=[100.0,300,800,1800,2600,3000]
            if features[16]==0 {return anchor(features)}
            let elo=max(100,min(3000,features[16]*1000))
            let i=(1..<opponents.count).first{elo<=opponents[$0]} ?? 5
            var low=features,high=features;low[16]=opponents[i-1]/1000;high[16]=opponents[i]/1000
            let t=(elo-opponents[i-1])/(opponents[i]-opponents[i-1])
            let lower=anchor(low),upper=anchor(high)
            return zip(lower,upper).map {a,b in a+(b-a)*t}
        }
        func quantile(_ curve:[Double],logit:Double)->Double {
            let levels=TrainingPuzzle.skillAnchors
            if curve[0]>=logit {return levels[0]}
            for i in 1..<levels.count where curve[i]>=logit {
                return levels[i-1]+(levels[i]-levels[i-1])*(logit-curve[i-1])/max(1e-10,curve[i]-curve[i-1])
            }
            return 3000
        }

    }
    private static let loaded:Result<Model,Error>=Result {
        let path=ProcessInfo.processInfo.environment["CC_MODE_MODEL_PATH"].map{URL(fileURLWithPath:$0)}
        guard let url=path ?? Bundle.main.url(forResource:"mode-difficulty-v3",withExtension:"json",subdirectory:"EngineResources") else {throw failure("Missing mode difficulty calibration")}
        let model=try JSONDecoder().decode(Model.self,from:Data(contentsOf:url))
        guard model.version==version,!model.nodes.isEmpty,!model.roots.isEmpty,model.temperature>0,model.improvement.map({$0.scale>0 && $0.scale.isFinite && $0.bias.isFinite && $0.samples>=100}) ?? true else {throw failure("Invalid mode difficulty calibration")}
        return model
    }
    static func failure(_ message:String)->NSError {NSError(domain:"CloudChess.ModeDifficulty",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    static func score(_ row:[String:Any])->Double {
        if let mate=row["mate"] as? Int {return mate>0 ? 100000-Double(mate):-100000-Double(mate)}
        return row["cp"] as? Double ?? 0
    }
    static func features(fen:String,kind:ChallengeKind,turns:Int,response:[String:Any],opponent:Double)throws->[Double] {
        guard kinds.contains(kind) else{throw failure("This mode has its own difficulty evidence")}
        guard let rows=response["evaluations"] as? [[String:Any]],let best=rows.first,
              let legal=response["legal"] as? [String],!legal.isEmpty,
              let quiet=response["rootQuiet"] as? Bool,response["limitedStrength"] as? Bool==false else {throw failure("Missing full-strength difficulty evidence")}
        let fields=fen.split(separator:" "),pieces=fields[0].filter{$0.isLetter},white=fields[1]=="w"
        let values:[Character:Double]=["p":100,"n":320,"b":335,"r":500,"q":900,"k":0]
        let own=pieces.filter{$0.isUppercase==white}.reduce(0.0){$0+(values[Character($1.lowercased())] ?? 0)}
        let enemy=pieces.filter{$0.isUppercase != white}.reduce(0.0){$0+(values[Character($1.lowercased())] ?? 0)}
        let cp=score(best)
        var gaps=rows.dropFirst().prefix(2).map{min(5,max(0,(cp-score($0))/400))}
        while gaps.count<2 {gaps.append(5)}
        let ply=max(0,(Int(fields.last ?? "1") ?? 1)-1)*2+(white ? 0:1)
        let x=kinds.map{$0==kind ? 1.0:0.0}+[Double(pieces.count)/32,own/4000,enemy/4000,Double(pieces.filter{$0.lowercased()=="p"}.count)/16,(response["check"] as? Bool==true ? 1:0),Double(legal.count)/40,min(2,max(-2,cp/1000)),gaps[0],gaps[1],quiet ? 1:0,Double(turns)/10,Double(min(40,ply))/20,opponent/1000]
        guard x.count==17,x.allSatisfy({$0.isFinite}) else{throw failure("Invalid difficulty features")};return x
    }
    static func calibrated(_ puzzle:TrainingPuzzle,response:[String:Any],opponent:Double=0)throws->TrainingPuzzle {
        var p=puzzle
        p.difficultyFeatures=try features(fen:p.fen,kind:p.kind,turns:p.kind == .finish ? 20:(p.kind == .tenMoves ? ImprovementChallenge.turns:p.solverMoves),response:response,opponent:opponent)
        return try rerated(p,opponent:opponent)
    }
    static func rerated(_ puzzle:TrainingPuzzle,opponent:Double=0)throws->TrainingPuzzle {
        guard var x=puzzle.difficultyFeatures,x.count==17,x.allSatisfy({$0.isFinite}) else {throw failure("Unmeasured challenge difficulty")}
        let model=try loaded.get();var p=puzzle
        if p.kind == .tenMoves {x[14]=Double(ImprovementChallenge.turns)/10;p.plies=ImprovementChallenge.plies;p.seconds=Double(ImprovementChallenge.turns)*18}
        x[16]=p.kind.usesHearts ? 0:max(100,min(3000,opponent))/1000
        let curve=model.curve(x)
        let r=model.quantile(curve,logit:0),low=model.quantile(curve,logit:-1.0986122887),high=model.quantile(curve,logit:1.0986122887)
        p.successLogits=curve
        p.rating=round(min(3000,max(400,r)));p.difficultySlope=max(120,min(600,(high-low)/2.1972245774))
        p.uncertainty=model.uncertainty[p.kind.rawValue] ?? 650
        if r<425 || r>2975 {p.uncertainty=max(650,p.uncertainty)}
        p.difficultyFeatures=x;p.calibrationOpponent=p.kind.usesHearts ? nil:opponent
        if p.kind == .tenMoves {p.uncertainty=max(650,p.uncertainty)}
        p.difficultyVersion=p.kind == .tenMoves ? improvementVersion:version
        return p
    }
    static func tuneOpponent(_ puzzle:TrainingPuzzle,learner:Double,target:Double,bounds:ClosedRange<Double>,preferred:Double)throws->TrainingPuzzle {
        guard !puzzle.kind.usesHearts else{return puzzle}
        var low=bounds.lowerBound,high=bounds.upperBound
        let wanted=log(target/(1-target))
        for _ in 0..<12 {
            let mid=(low+high)/2,p=try rerated(puzzle,opponent:mid)
            if p.successLogit(at:learner)!>wanted {low=mid}else{high=mid}
        }
        let matched=try rerated(puzzle,opponent:round((low+high)/2))
        let comfortable=try rerated(puzzle,opponent:min(bounds.upperBound,max(bounds.lowerBound,preferred)))
        // If the model is flat in this range, keep the smoother coach request.
        return abs(comfortable.successLogit(at:learner)!-wanted)<=abs(matched.successLogit(at:learner)!-wanted)+0.015 ? comfortable:matched
    }
    static func predictedSuccess(_ p:TrainingPuzzle,solver:Double)throws->Double {
        guard let x=p.difficultyFeatures,x.count==17 else{throw failure("Unmeasured challenge")}
        return AdaptivePuzzleCoach.sigmoid(try loaded.get().logit(x,at:solver))
    }
}

/// Revalidation at handoff, after the previous puzzle has updated the learner.
/// Preparation never freezes an old opponent, consumes a review, or overrides
/// the live mode/shape/instruction selection.
enum PreparedChallengeGate {
    static func revalidate(_ p:TrainingPuzzle,ability:Double,age:TimeInterval,coach:AdaptivePuzzleCoach,excluded:String?,instruction:String?,parent:TrainingPuzzle?=nil)->TrainingPuzzle? {
        let kind=p.kind
        guard kind == .tactics,(coach.focusedSelection?.matches(p) ?? false),age>=0,age<600,abs(coach.challengeLevel(kind)-ability)<=150,
              !coach.seen.contains(p.id),coach.allowsNextPuzzle(p),p.id != excluded,instruction==nil else{return nil}
        if kind == .tactics {
            guard let parent,!(coach.total%4==3 && coach.reviews.contains(where:{coach.eligibleReview($0)})),coach.acceptsComposition(p,from:parent),
                  coach.preferredColumns==nil || (p.columns==coach.preferredColumns && p.rows==coach.preferredRows) else{return nil}
            return p
        }
        var adjusted=p
        if kind == .whosWinning {
            guard p.judgment?.verdict==JudgmentVerdict.draw(coach.judgmentDraws ?? 0) else{return nil}
        }
        if kind == .blunderPunish {
            adjusted.calibrationOpponent=coach.opponentRating(for:kind)
            adjusted.rating=BlunderEngine.intrinsic(opponent:adjusted.calibrationOpponent!,complexity:p.complexity)
        }
        if kind == .tenMoves && p.plies != ImprovementChallenge.plies {return nil}
        if kind == .finish || kind == .tenMoves {
            guard let value=try? ModeDifficulty.tuneOpponent(p,learner:coach.challengeLevel(kind),target:coach.target(for:kind),bounds:coach.opponentBounds(for:kind),preferred:coach.opponentRating(for:kind)) else{return nil}
            adjusted=value
        }
        guard abs(adjusted.rating-coach.targetRating(for:kind))<=225 else{return nil}
        if kind == .opening && adjusted.solverMoves != OpeningJudgement.moves(rating:coach.targetRating(for:kind)) {return nil}
        return adjusted
    }
}
