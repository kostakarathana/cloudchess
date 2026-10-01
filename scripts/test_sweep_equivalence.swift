import Foundation
import CryptoKit
@main struct SweepRegression {
 static func main() async throws {
    var checks=0
    func check(_ value:Bool,_ reason:String) {checks+=1;precondition(value,reason)}
    let entries=try await CertifiedChallengeBank.shared.load()
    for i in 0..<3600 {
        let entry=entries[i%entries.count],opponent=Double(100+i%59*50)
        let before=try ReferenceModeDifficulty.calibrated(entry.puzzle,response:entry.response,opponent:opponent)
        let after=try ModeDifficulty.calibrated(entry.puzzle,response:entry.response,opponent:opponent)
        check(before.successLogits==after.successLogits,"Exact forest curves through cache churn")
        check(before.rating==after.rating && before.difficultySlope==after.difficultySlope && before.uncertainty==after.uncertainty,"Frozen rating, reward inputs and uncertainty")
        if i%5==0 {
            let old=try ReferenceModeDifficulty.tuneOpponent(before,learner:Double(400+i%27*100),target:0.67,bounds:100...3000,preferred:opponent)
            let new=try ModeDifficulty.tuneOpponent(after,learner:Double(400+i%27*100),target:0.67,bounds:100...3000,preferred:opponent)
            check(old.calibrationOpponent==new.calibrationOpponent && old.successLogits==new.successLogits,"Exact tuned opponent")
        }
    }
    for i in 0..<4096 {
        let digest=SHA256.hash(data:Data((0..<(i%256)).map{UInt8(($0+i)%256)}))
        check(digest.chessHex==digest.map{String(format:"%02x",$0)}.joined(),"Exact persistent cache identity")
    }
    let modelURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CC_MODE_MODEL_PATH"]!)
    let modelData=try Data(contentsOf:modelURL)
    let model=try JSONDecoder().decode(ModeDifficulty.Model.self,from:modelData)
    let reference=try JSONDecoder().decode(ReferenceModeDifficulty.Model.self,from:modelData)
    let sample=entries[0].puzzle.difficultyFeatures!
    let lock=NSLock();var failures=0
    DispatchQueue.concurrentPerform(iterations:1200) {i in
        var x=sample;x[4]=Double(i%73)/100;x[16]=Double(i%30+1)/10
        let a=model.curve(x),b=reference.curve(x)
        if a != b {lock.lock();failures+=1;lock.unlock()}
    }
    check(failures==0,"Concurrent anchor reads and eviction")
    var object=try JSONSerialization.jsonObject(with:modelData) as! [String:Any]
    object["intercept"]=(object["intercept"] as! Double)+1
    let changed=try JSONDecoder().decode(ModeDifficulty.Model.self,from:JSONSerialization.data(withJSONObject:object))
    check(changed.curve(sample) != model.curve(sample),"Caches isolated between decoded model versions")
    print("{\"status\":\"passed\",\"checks\":\(checks),\"concurrentComparisons\":1200,\"reference\":\"ac2572e\"}")
 }
}
