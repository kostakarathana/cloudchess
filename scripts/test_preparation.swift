import Foundation
@main struct PreparationRegression {
 static func main() async throws {
    let base:[String:Any]=["action":"analyse","moves":["e2e4","e7e5"],"nodes":200000,"multipv":3]
    let start=Date(),first=try await NativeChess.call(base),cold=Date().timeIntervalSince(start)
    var checks=0
    let data=try JSONSerialization.data(withJSONObject:first,options:.sortedKeys)
    let warmStart=Date()
    for _ in 0..<1000 {
        let next=try await NativeChess.call(base)
        let encoded=try JSONSerialization.data(withJSONObject:next,options:.sortedKeys);precondition(encoded==data);checks+=1
    }
    let cachedMean=Date().timeIntervalSince(warmStart)/1000
    precondition(cachedMean<cold/5)
    // A distinct history, budget, root constraint and MultiPV must not alias.
    for (key,value) in [("moves",["d2d4"] as Any),("nodes",10000 as Any),("multipv",1 as Any),("root","g1f3" as Any)] {
        var request=base;request[key]=value
        let next=try await NativeChess.call(request)
        let encoded=try JSONSerialization.data(withJSONObject:next,options:.sortedKeys);precondition(encoded != data);checks+=1
        if key=="root" {precondition(((next["evaluations"] as! [[String:Any]])[0]["pv"] as! [String])[0]=="g1f3")}
    }
    var maxState=0.0,maxYield=0.0
    for cycle in 0..<20 {
        let epoch=CCBackgroundEpoch()
        let background=Task {try await NativeChess.$backgroundEpoch.withValue(epoch) {try await NativeChess.call(["action":"analyse","moves":cycle%2==0 ? ["d2d4"]:["e2e4"],"nodes":8000000,"multipv":3])}}
        try await Task.sleep(nanoseconds:30_000_000)
        for _ in 0..<50 {
            let t=Date();let local=try await NativeChess.call(["action":"state","moves":["e2e4","e7e5","g1f3"]]);maxState=max(maxState,Date().timeIntervalSince(t));precondition((local["legal"] as! [String]).count==29);checks+=1
        }
        let t=Date();NativeChess.cancelPreparation()
        do {_ = try await background.value;preconditionFailure("Cancelled search was accepted")}catch{checks+=1}
        maxYield=max(maxYield,Date().timeIntervalSince(t))
        do {_ = try await NativeChess.$backgroundEpoch.withValue(epoch){try await NativeChess.call(base)};preconditionFailure("Stale epoch reached cache")}catch{checks+=1}
        // Cancellation applies only to background. It must not stop a foreground search.
        let foreground=Task {try await NativeChess.call(["action":"analyse","moves":["b1c3"],"nodes":100000+cycle,"multipv":1])}
        try await Task.sleep(nanoseconds:1_000_000);NativeChess.cancelPreparation()
        let result=try await foreground.value
        precondition(result["error"]==nil && result["limitedStrength"] as? Bool==false)
        precondition((result["evaluations"] as! [[String:Any]])[0]["nodes"] as! Int >= 100000);checks+=2
    }
    precondition(maxState<0.5 && maxYield<1.0)
    print("{\"status\":\"passed\",\"checks\":\(checks),\"coldSeconds\":\(cold),\"cachedMeanSeconds\":\(cachedMean),\"maxLocalStateSeconds\":\(maxState),\"maxBackgroundYieldSeconds\":\(maxYield)}")
 }
}
