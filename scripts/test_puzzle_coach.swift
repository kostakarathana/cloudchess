import Foundation

@main struct CoachRegression {
    static var checks=0
    static func check(_ condition:Bool,_ message:String="Regression") {checks+=1;if !condition{fatalError(message)}}
    static func main()throws {
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        if CommandLine.arguments.count>2 {
            var proposals:[TrainingPuzzle]=[]
            for (i,p) in bank.enumerated() {
                for j in 0..<4 {
                    let seed=UInt64(i*7919+j*43927+92131)
                    if let q=p.composition(seed:seed) {check(q.fen==p.composition(seed:seed)!.fen);check(q.fen != p.fen);proposals.append(q)}
                }
            }
            try JSONEncoder().encode(proposals).write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print("Generated \(proposals.count) proposals");return
        }
        check(bank.count>6000)
        var report:[String:Any]=[:]
        for p in bank {
            for v in 0..<4 {
                let q=p.variant(v)
                check(q.white == (p.white != (v&2 != 0)),"Color reflection")
                check(q.line.count==p.line.count && q.plies==p.plies)
                check(q.rating==p.rating && q.difficultyVersion==p.difficultyVersion,"Legal reflection retains measured difficulty")
                let fields=q.fen.split(separator:" ");check(fields.count==6)
                check(q.variant(v).fen==p.fen,"Involutive reflection")
            }
        }
        let sample=bank.first{$0.mate==2}!
        var c=AdaptivePuzzleCoach();c.begin(sample)
        c.session?.elapsed=35;check(c.finish());let once=c.ability.mean
        check(!c.finish());check(c.ability.mean==once && c.total==1,"Idempotent finish")
        c.begin(sample);c.session?.hints=1;c.session?.elapsed=3;c.finish()
        check(c.ability.mean<once,"Hint cannot improve mastery")
        let saved=try JSONEncoder().encode(c)
        var restored=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:saved)
        check(restored.total==c.total && restored.session?.recorded==true)
        check(!restored.finish(),"No duplicate after relaunch")
        restored.begin(sample);restored.session?.mistakes=2;restored.session?.moves=sample.line.prefix(2).map{$0};restored.session?.elapsed=77
        let resumed=try JSONDecoder().decode(AdaptivePuzzleCoach.self,from:JSONEncoder().encode(restored))
        check(resumed.session?.mistakes==2 && resumed.session?.elapsed==77 && resumed.session?.moves.count==2)
        var simulations:[[String:Any]]=[]
        for trueRating in [700.0,1100,1500,1900,2300] {
            var model=AdaptivePuzzleCoach()
            for i in 0..<400 {
                let candidates=model.candidates(bank);check(!candidates.isEmpty)
                let p=candidates[0];model.begin(p)
                let probability=AdaptivePuzzleCoach.sigmoid((trueRating-p.rating)/240)
                let roll=Double(model.nextRandom()%100000)/100000
                model.session?.mistakes=roll<probability ? 0:1
                model.session?.elapsed=p.seconds
                let before=model.ability.mean
                model.finish()
                check(model.ability.mean.isFinite && model.ability.variance.isFinite)
                check(abs(model.ability.mean-before)<=95.001,"Bounded update")
                if i>15 {check(model.session?.recorded==true)}
            }
            // Rating has contextual tag and shape offsets: verify the effective
            // success estimate, not falsely claim perfect global Elo calibration.
            let probes=bank.enumerated().filter{$0.offset%41==0}.map{$0.element}
            let error=probes.reduce(0.0){$0+abs(model.probability($1)-AdaptivePuzzleCoach.sigmoid((trueRating-$1.rating)/240))}/Double(probes.count)
            check(error<0.20,"Predictive adaptation \(trueRating): \(error)")
            simulations.append(["ability":trueRating,"estimate":model.ability.mean,"probabilityMAE":error])
        }
        var weak=AdaptivePuzzleCoach()
        weak.importProfile(["trainingPrior":["fork":0.9],"ratings":["rapid":["performanceEstimate":1800.0]]])
        check(weak.priors["fork"]==0.6);check(weak.ability.mean==1450)
        let fork=bank.first{$0.tags.contains("fork")}!
        for _ in 0..<30 {weak.begin(fork);weak.session?.mistakes=1;weak.finish()}
        check(weak.weakness("fork")>weak.weakness("promotion"),"Repeated weak skill is prioritized")
        let local=weak.ability.mean
        weak.importProfile(["trainingPrior":["fork":0.2],"ratings":["rapid":["performanceEstimate":2800.0]]])
        check(weak.ability.mean==local,"Imported rating cannot reset learned ability")
        var review=AdaptivePuzzleCoach();let missed=sample.variant(2)
        review.ability.mean=missed.rating
        review.total=11;review.reviews=[PuzzleReview(puzzle:missed,due:8)]
        check(review.candidates(bank).first?.id==missed.id,"Due review retains its exact position")
        review.begin(missed);review.session?.elapsed=30;review.finish()
        check(review.reviews.isEmpty,"Successful review retires its queue entry")
        for cols in 4...8 {for rows in 4...8 {
            var m=AdaptivePuzzleCoach();m.preferredColumns=cols;m.preferredRows=rows
            let picks=m.candidates(bank);check(picks.count>=8);check(picks.allSatisfy{$0.columns==cols && $0.rows==rows})
            var same=m;same.sequence=0;var fresh=AdaptivePuzzleCoach();fresh.preferredColumns=cols;fresh.preferredRows=rows
            check(same.candidates(bank).map{$0.id}==fresh.candidates(bank).map{$0.id},"Deterministic selection")
        }}
        // Progression must rise on the actual item bank, not merely make the
        // hidden player rating bigger. Exercise every rectangular curriculum.
        var progressions:[[String:Any]]=[]
        for columns in 4...8 {for rows in 4...8 {
            var fast=AdaptivePuzzleCoach();fast.preferredColumns=columns;fast.preferredRows=rows
            var ratings:[Double]=[]
            for _ in 0..<18 {
                let p=fast.candidates(bank)[0];ratings.append(p.rating);fast.begin(p);fast.session?.elapsed=4;fast.finish()
            }
            let first=ratings.prefix(3).reduce(0,+)/3,last=ratings.suffix(3).reduce(0,+)/3
            check(last>first+300,"Fast mastery must produce harder items: \(columns)x\(rows): \(ratings)")
            check(fast.target<=0.58,"Quick solves must earn challenge, not repeated warmups")
            let high=fast.ability.mean
            for _ in 0..<8 {let p=fast.candidates(bank)[0];fast.begin(p);fast.session?.mistakes=4;fast.session?.elapsed=120;fast.finish()}
            check(fast.ability.mean<high-150 && fast.target==0.78,"Repeated struggle must ease safely")
            progressions.append(["shape":"\(columns)x\(rows)","initialMean":first,"afterMasteryMean":last])
        }}
        for c in 4...8 {for r in 4...8 {
            var expert=AdaptivePuzzleCoach();expert.preferredColumns=c;expert.preferredRows=r;expert.ability.mean=3000;expert.ability.variance=2500
            let maximum=bank.filter{$0.columns==c && $0.rows==r}.map{$0.rating}.max()!
            let chosen=expert.candidates(bank)[0]
            check(chosen.rating>=maximum-120,"At the bank ceiling, choose a hard item instead of a saturated-probability tie")
        }}
        var single=AdaptivePuzzleCoach();single.begin(sample);single.session?.mistakes=1;single.finish()
        single.begin(sample);single.session?.mistakes=1;single.finish()
        check(single.target==0.67,"Two corrected slips must not force remedial difficulty")
        var repeated=AdaptivePuzzleCoach();repeated.begin(sample);repeated.session?.elapsed=4;repeated.finish()
        check(repeated.attempts.last?.source==sample.source,"Generated variants retain source-family repetition tracking")
        var migration=AdaptivePuzzleCoach();migration.begin(sample);migration.session?.moves=[sample.line[0]];migration.total=19;migration.ability.mean=1337;migration.ability.variance=9000
        migration.migrateDifficulty();check(migration.total==19 && migration.ability.mean==1337 && migration.session?.moves==[sample.line[0]])
        check(migration.ability.variance>=90000);migration.ability.variance=8000;migration.migrateDifficulty();check(migration.ability.variance==8000,"Migration is one-time")
        var calibrated=sample
        let valid:[String:Any]=["version":"challenge-v2","rating":1500.0,"uncertainty":400.0,"complexity":55.0,"seconds":50.0,"botSuccess":[0.2,0.5,0.8]]
        try calibrated.applyDifficulty(["difficulty":valid]);check(calibrated.rating==1500 && calibrated.difficultyVersion=="challenge-v2")
        for (key,value) in [("rating",Double.nan),("rating",3500.0),("complexity",-1.0),("uncertainty",0.0)] {
            var invalid=valid;invalid[key]=value
            do {try calibrated.applyDifficulty(["difficulty":invalid]);check(false,"Reject invalid measurement")}catch{check(true)}
        }
        // A fresh composition must not silently inherit its parent's rating.
        if var q=sample.composition(seed:42) {
            check(q.difficultyVersion==nil);check(!migration.acceptsComposition(q,from:sample))
            do {try q.applyDifficulty([:]);check(false,"Missing measurements must fail closed")}catch{check(true)}
        }
        report=["status":"passed","checks":checks,"simulations":simulations,"progressions":progressions]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
    }
}
