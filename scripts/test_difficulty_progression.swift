import Foundation

/// Deterministic evidence that focused-puzzle selection gets harder as the
/// current score rises, up to each shape/family stratum's catalogue ceiling.
///
/// Three parts, all against the real `AdaptivePuzzleCoach` and the shipping
/// catalogue (bank variants only; no native composition/certification):
///   1. Forced-shape sweep: every one of the 50 shape/family strata at a fixed
///      score schedule and two fixed abilities, fresh coach each time.
///   2. Organic always-correct runs for five RNG seeds (fast clean solves).
///   3. Struggle run: every fifth puzzle fails with three mistakes.
///
/// Usage: progression-tests <puzzles.json> <output directory>
/// Writes sweep.jsonl, organic.jsonl, struggle.jsonl and summary.json.
/// Scores are points (rating^1.5 per puzzle), the unit the shipping coach uses.
@main struct DifficultyProgressionTests {
    /// Score schedule 0 … 10,000,000 points.
    static let schedule:[Double]=[0,50_000,100_000,200_000,300_000,500_000,1_000_000,1_500_000,2_000_000,3_000_000,5_000_000,10_000_000]
    static let goal=10_000_000.0
    static let lowBucket=300_000.0,highBucket=2_000_000.0
    static let abilities=[1100.0,3000.0]

    struct Record:Encodable {
        var run:String,seed:Int,fixedAbility:Double?
        let attempt:Int,score:Double,level:Double,targetRating:Double,targetSuccess:Double,ability:Double
        let shape:String,family:String,rating:Double,stratumMax:Double,stratumP90:Double,review:Bool,reviewEligible:Bool,probability:Double
        let id:String,source:String,fen:String,columns:Int,rows:Int,mate:Int,gain:Int,plies:Int,line:[String]
        let reward:Double,picksCount:Int,topRatings:[Double]
        let maxID:String,maxSeenVariants:Int,maxSourceRecent:Bool,maxBlocked:Bool
    }
    struct Failure:Error,CustomStringConvertible {let description:String}

    static var checks=0,failures:[String]=[]
    static func check(_ condition:Bool,_ message:@autoclosure()->String) {
        checks+=1
        if !condition {failures.append(message());FileHandle.standardError.write(("FAIL: "+message()+"\n").data(using:.utf8)!)}
    }
    static func key(_ p:TrainingPuzzle)->String {"\(p.columns)x\(p.rows):\(p.mate>0 ? "mate":"improvement")"}
    static func mean(_ v:[Double])->Double {v.isEmpty ? .nan:v.reduce(0,+)/Double(v.count)}
    static func ranks(_ v:[Double])->[Double] {
        let order=v.indices.sorted{v[$0]<v[$1]};var r=[Double](repeating:0,count:v.count);var i=0
        while i<order.count {var j=i;while j+1<order.count && v[order[j+1]]==v[order[i]] {j+=1}
            let avg=Double(i+j)/2+1;for k in i...j {r[order[k]]=avg};i=j+1}
        return r
    }
    static func spearman(_ x:[Double],_ y:[Double])->Double {
        guard x.count==y.count,x.count>2 else{return .nan}
        let rx=ranks(x),ry=ranks(y),mx=mean(rx),my=mean(ry)
        var sxy=0.0,sxx=0.0,syy=0.0
        for i in x.indices {sxy+=(rx[i]-mx)*(ry[i]-my);sxx+=(rx[i]-mx)*(rx[i]-mx);syy+=(ry[i]-my)*(ry[i]-my)}
        return sxx>0 && syy>0 ? sxy/sqrt(sxx*syy):.nan
    }

    static func main() throws {
        let args=CommandLine.arguments
        guard args.count>=3 else{throw Failure(description:"usage: progression-tests <puzzles.json> <output dir>")}
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let out=URL(fileURLWithPath:args[2],isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var strata:[String:[TrainingPuzzle]]=[:]
        for p in bank where p.kind == .tactics {strata[key(p),default:[]].append(p)}
        check(strata.count==50,"Catalogue must cover all 50 shape/family strata, found \(strata.count)")
        var maxima:[String:TrainingPuzzle]=[:],p90:[String:Double]=[:]
        for (k,v) in strata {let s=v.sorted{$0.rating<$1.rating};maxima[k]=s.last!;p90[k]=s[Int(Double(s.count-1)*0.9)].rating}

        func record(_ coach:AdaptivePuzzleCoach,run:String,seed:Int,fixedAbility:Double?,attempt:Int,picks:[TrainingPuzzle],reward:Double)->Record {
            let p=picks[0],k=key(p),top=maxima[k]!,level=coach.challengeLevel(.tactics)
            let seenVariants=(0..<4).filter{coach.seen.contains(top.id+"-\($0)")}.count
            let recentSources=Set(coach.attempts.suffix(12).map{$0.source ?? $0.puzzle.components(separatedBy:"-")[0]})
            let review=coach.reviews.first{$0.puzzle.id==p.id}
            return Record(run:run,seed:seed,fixedAbility:fixedAbility,attempt:attempt,score:coach.currentScore,level:level,targetRating:coach.targetRating(for:.tactics),targetSuccess:coach.target,ability:coach.ability.mean,
                          shape:"\(p.columns)x\(p.rows)",family:p.mate>0 ? "mate":"improvement",rating:p.rating,stratumMax:top.rating,stratumP90:p90[k]!,review:review != nil,reviewEligible:review.map{coach.eligibleReview($0)} ?? false,probability:coach.probability(p,level:level),
                          id:p.id,source:p.source,fen:p.fen,columns:p.columns,rows:p.rows,mate:p.mate,gain:p.gain,plies:p.plies,line:p.line,reward:reward,picksCount:picks.count,topRatings:picks.prefix(5).map{$0.rating},
                          maxID:top.id,maxSeenVariants:seenVariants,maxSourceRecent:recentSources.contains(top.source),maxBlocked:!coach.allowsNextPuzzle(top))
        }
        func write(_ records:[Record],_ name:String) throws {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            var text="";for r in records {text+=String(decoding:try encoder.encode(r),as:UTF8.self)+"\n"}
            try text.write(to:out.appendingPathComponent(name),atomically:true,encoding:.utf8)
        }

        // 1. Forced-shape sweep ------------------------------------------------
        var sweep:[Record]=[]
        var sweepTable:[String:[String:[Double]]]=[:]   // ability -> stratum -> ratings by schedule index
        var saturation:[String:[String:Double?]]=[:]    // ability -> stratum -> first score within 150 of the ceiling
        var levels:[String:[Double]]=[:],targets:[String:[Double]]=[:]
        for ability in abilities {
            let a="\(Int(ability))"
            var levelRow:[Double]=[],targetRow:[Double]=[]
            var rows:[String:[Double]]=[:]
            for (si,score) in schedule.enumerated() {
                var sampleLevel:Double?=nil,sampleTarget:Double?=nil
                for x in 4...8 {for y in 4...8 {for mate in [false,true] {
                    var c=AdaptivePuzzleCoach();c.ability.mean=ability;c.scoring=ChallengeScore(total:score,best:score)
                    c.focusedSelection=FocusedPuzzleSelection(columns:x,rows:y,mate:mate)
                    let picks=c.candidates(bank)
                    check(!picks.isEmpty,"Stratum \(x)x\(y) mate=\(mate) must have candidates at score \(score)")
                    let r=record(c,run:"sweep",seed:0,fixedAbility:ability,attempt:sweep.count,picks:picks,reward:0)
                    sweep.append(r);rows[key(picks[0]),default:[]].append(r.rating)
                    check(r.level>=400 && r.level<=3000 && r.targetRating>=400 && r.targetRating<=3000,"Level/target stay within 400…3000 at score \(score)")
                    sampleLevel=r.level;sampleTarget=r.targetRating
                    if si==schedule.count-1 {
                        let top=maxima[key(picks[0])]!.rating
                        if ability==1100 {check(r.rating>=min(top,r.targetRating)-150,"Ability 1100 \(key(picks[0])) top-score pick \(r.rating) must reach min(ceiling \(top), target \(Int(r.targetRating)))-150")}
                        else {check(r.rating>=top-150,"Ability 3000 \(key(picks[0])) top-score pick \(r.rating) must be within 150 of the ceiling \(top)")}
                    }
                }}}
                levelRow.append(sampleLevel!);targetRow.append(sampleTarget!)
            }
            for i in 1..<schedule.count {
                check(levelRow[i]>levelRow[i-1],"challengeLevel must strictly increase with score (ability \(a), step \(i))")
                check(targetRow[i]>targetRow[i-1],"targetRating must strictly increase with score (ability \(a), step \(i))")
            }
            levels[a]=levelRow;targets[a]=targetRow
            var firstSaturation:[String:Double?]=[:]
            for (stratum,ratings) in rows {
                let top=maxima[stratum]!.rating
                check(ratings.count==schedule.count,"One pick per schedule point in \(stratum)")
                for i in 1..<ratings.count where ratings[i-1]<top-150 {
                    check(ratings[i]>=ratings[i-1]-25,"Ability \(a) \(stratum): rating fell \(ratings[i-1]) -> \(ratings[i]) between scores \(schedule[i-1]) and \(schedule[i]) while below the ceiling")
                }
                // updateValue keeps the key when the stratum never saturates (subscript assignment of nil would remove it).
                firstSaturation.updateValue(ratings.indices.first{ratings[$0]>=top-150}.map{schedule[$0]},forKey:stratum)
            }
            sweepTable[a]=rows;saturation[a]=firstSaturation
        }
        try write(sweep,"sweep.jsonl")
        let saturated3000=saturation["3000"]!.values.filter{$0 != nil}.count
        check(saturated3000==50,"Ability 3000 must saturate every stratum by the top score (\(saturated3000)/50)")
        let saturated1100=saturation["1100"]!.values.filter{$0 != nil}.count
        check(saturated1100>=48,"Ability 1100 must saturate at least 48 strata by the top score (\(saturated1100)/50)")

        // 2. Organic always-correct runs --------------------------------------
        var organic:[Record]=[],attemptsToGoal:[Int]=[],finalAbilities:[Double]=[],finalTargets:[Double]=[]
        func play(run:String,seed:Int,struggle:Bool)->[Record] {
            var coach=AdaptivePuzzleCoach();coach.sequence=UInt64(seed)
            var records:[Record]=[];var attempt=0
            while coach.currentScore<goal && attempt<3000 {
                let picks=coach.candidates(bank)
                check(!picks.isEmpty,"\(run) seed \(seed): empty candidates at attempt \(attempt)")
                let before=coach
                coach.begin(picks[0])
                records.append(record(before,run:run,seed:seed,fixedAbility:nil,attempt:attempt,picks:picks,reward:coach.session!.reward))
                if struggle && attempt%5==4 {
                    coach.session?.mistakes=3;coach.session?.extraPenalty=1.75;coach.session?.elapsed=60
                    check(coach.finish(skipped:true),"\(run) seed \(seed): failed finish must record")
                } else {
                    coach.session?.elapsed=4
                    check(coach.finish(),"\(run) seed \(seed): clean finish must record")
                }
                attempt+=1
            }
            check(coach.currentScore>=goal,"\(run) seed \(seed) must reach \(goal) points within 3000 attempts (\(attempt), score \(coach.currentScore))")
            attemptsToGoal.append(attempt);finalAbilities.append(coach.ability.mean);finalTargets.append(coach.target)
            print("\(run) seed=\(seed) attempts=\(attempt) finalScore=\(Int(coach.currentScore)) finalLevel=\(Int(coach.challengeLevel(.tactics))) ability=\(Int(coach.ability.mean)) target=\(coach.target) reviews=\(coach.reviews.count)")
            return records
        }
        for seed in 0..<5 {organic+=play(run:"organic",seed:seed,struggle:false)}
        try write(organic,"organic.jsonl")
        func buckets(_ records:[Record])->(low:[Record],mid:[Record],high:[Record]) {
            (records.filter{$0.score<lowBucket},records.filter{$0.score>=lowBucket && $0.score<highBucket},records.filter{$0.score>=highBucket})
        }
        let ob=buckets(organic)
        let organicMeans=(low:mean(ob.low.map(\.rating)),mid:mean(ob.mid.map(\.rating)),high:mean(ob.high.map(\.rating)))
        let organicLevels=(low:mean(ob.low.map(\.level)),mid:mean(ob.mid.map(\.level)),high:mean(ob.high.map(\.level)))
        let organicGaps=(low:mean(ob.low.map{$0.rating-$0.stratumMax}),mid:mean(ob.mid.map{$0.rating-$0.stratumMax}),high:mean(ob.high.map{$0.rating-$0.stratumMax}))
        let highCeilingShare=Double(ob.high.filter{$0.rating>=$0.stratumMax-150}.count)/Double(max(1,ob.high.count))
        let organicSpearman=spearman(organic.map(\.score),organic.map(\.rating))
        for (seed,n) in attemptsToGoal.enumerated() {check(n>=100 && n<=160,"Organic seed \(seed): attempts to goal \(n) must be within 100…160")}
        check(organicMeans.low<=organicMeans.mid-500,"Organic low bucket mean \(organicMeans.low) must sit at least 500 below the mid bucket \(organicMeans.mid)")
        check(organicMeans.high>=organicMeans.mid-75,"Organic high bucket mean \(organicMeans.high) must not fall more than 75 below the mid bucket \(organicMeans.mid) (ceiling plateau)")
        check(highCeilingShare>=0.85,"At least 85% of high-score picks must be within 150 of their stratum ceiling (\(highCeilingShare))")
        check(organicGaps.high>=(-100),"Mean gap to the stratum ceiling above \(highBucket) points must be at least -100 (\(organicGaps.high))")
        check(organicSpearman>0.1,"Spearman(score, rating) over organic picks must be positive (\(organicSpearman))")
        for (seed,a) in finalAbilities.enumerated() {check(a>2300,"Organic seed \(seed): final ability \(a) must exceed 2300")}
        for (seed,t) in finalTargets.enumerated() {check(t==0.52,"Organic seed \(seed): fast clean solves must lock the 0.52 target (\(t))")}

        // 3. Struggle run -------------------------------------------------------
        let struggleStart=attemptsToGoal.count
        let struggle=play(run:"struggle",seed:0,struggle:true)
        try write(struggle,"struggle.jsonl")
        let sb=buckets(struggle)
        let struggleMeans=(low:mean(sb.low.map(\.rating)),mid:mean(sb.mid.map(\.rating)),high:mean(sb.high.map(\.rating)))
        let presentedReviews=struggle.filter(\.review)
        let reviewShare=Double(presentedReviews.count)/Double(max(1,struggle.count))
        check(reviewShare<=0.08,"Struggle run: presented reviews \(presentedReviews.count)/\(struggle.count) must be at most 8% of picks")
        check(struggleMeans.high>=1750,"Struggle run: high bucket mean rating \(struggleMeans.high) must be at least 1750")
        for r in presentedReviews {check(r.reviewEligible,"Struggle run attempt \(r.attempt): presented review \(r.id) must pass eligibleReview")}
        for r in presentedReviews {check(r.probability>=0.30 && r.probability<=0.85,"Struggle run attempt \(r.attempt): review predicted success \(r.probability) must lie in 0.30…0.85")}
        let struggleAttempts=attemptsToGoal[struggleStart]

        // Summary ---------------------------------------------------------------
        var stratumRows:[[String:Any]]=[]
        for x in 4...8 {for y in 4...8 {for fam in ["mate","improvement"] {
            let k="\(x)x\(y):\(fam)",items=strata[k]!
            var row:[String:Any]=["stratum":k,"shape":"\(x)x\(y)","family":fam,"count":items.count,"max":maxima[k]!.rating,"p90":p90[k]!]
            for a in abilities.map({"\(Int($0))"}) {row["ratings\(a)"]=sweepTable[a]![k]!;row["saturation\(a)"]=saturation[a]![k]!.map{$0 as Any} ?? NSNull()}
            stratumRows.append(row)
        }}}
        let summary:[String:Any]=[
            "schedule":schedule,"goal":goal,"abilities":abilities,
            "lowBucket":lowBucket,"highBucket":highBucket,
            "sweep":["records":sweep.count,"levels":levels,"targets":targets,"strata":stratumRows,
                     "saturatedStrata":["1100":saturated1100,"3000":saturated3000],
                     "meanRatingBySchedule":abilities.reduce(into:[String:[Double]]()){acc,a in let key="\(Int(a))";acc[key]=schedule.indices.map{i in mean(sweepTable[key]!.values.map{$0[i]})}}],
            "organic":["seeds":5,"records":organic.count,"attemptsToGoal":Array(attemptsToGoal.prefix(5)),"finalAbilities":finalAbilities.prefix(5).map{$0},"finalTargets":finalTargets.prefix(5).map{$0},
                       "buckets":["low":["count":ob.low.count,"meanRating":organicMeans.low,"meanLevel":organicLevels.low,"meanGap":organicGaps.low],
                                  "mid":["count":ob.mid.count,"meanRating":organicMeans.mid,"meanLevel":organicLevels.mid,"meanGap":organicGaps.mid],
                                  "high":["count":ob.high.count,"meanRating":organicMeans.high,"meanLevel":organicLevels.high,"meanGap":organicGaps.high,"ceilingShare":highCeilingShare]],
                       "spearman":organicSpearman],
            "struggle":["records":struggle.count,"attemptsToGoal":struggleAttempts,"reviewsPresented":presentedReviews.count,"reviewShare":reviewShare,
                        "buckets":["low":["count":sb.low.count,"meanRating":struggleMeans.low],"mid":["count":sb.mid.count,"meanRating":struggleMeans.mid],"high":["count":sb.high.count,"meanRating":struggleMeans.high]],
                        "spearman":spearman(struggle.map(\.score),struggle.map(\.rating))],
            "checks":checks,"failures":failures]
        let data=try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:out.appendingPathComponent("summary.json"))
        print("sweep records=\(sweep.count) organic records=\(organic.count) struggle records=\(struggle.count)")
        print("organic bucket means low/mid/high: \(Int(organicMeans.low))/\(Int(organicMeans.mid))/\(Int(organicMeans.high)) spearman=\(String(format:"%.3f",organicSpearman)) ceilingShare=\(String(format:"%.3f",highCeilingShare))")
        print("checks=\(checks) failures=\(failures.count)")
        if !failures.isEmpty {exit(1)}
    }
}
