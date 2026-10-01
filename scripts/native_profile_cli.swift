import Foundation
@main struct NativeProfileCLI {
    static func main() async throws {
        let args=CommandLine.arguments
        if args.count>1 && args[1]=="selftest" {
            var checks=0
            let good=try OnDeviceProfiles.identity("https://lichess.org/@/Tester")
            precondition(good.0=="lichess" && good.1=="tester");checks+=1
            for link in ["http://lichess.org/@/a","https://evil.com/@/a","https://lichess.org.evil/@/a","https://lichess.org/@/a?x=1"] {
                do{_=try OnDeviceProfiles.identity(link);fatalError("Unsafe URL accepted")}catch{checks+=1}
            }
            let pgn="""
            [White "Tester"]
            [Black "Other"]
            [Result "0-1"]

            1. f3 { [%clk 0:03:00] } (1. e4 e5 (1... c5)) e5 2.g4 $2 Qh4# 0-1
            """
            let parsed=try NativePGN(pgn);precondition(parsed.san==["f3","e5","g4","Qh4#"]);precondition(parsed.clocks[0]==180);checks+=2
            let legal=try await NativeChess.call(["action":"parse","moves":parsed.san]);precondition(legal["check"] as? Bool==true);checks+=1
            var rng:UInt64=771
            func random()->Double{rng=rng&*6364136223846793005&+1;return Double(rng>>11)/Double(UInt64.max>>11)}
            for _ in 0..<2000 {
                let a=random()*4000-2000,b=random()*4000-2000
                let best:[String:Any]=["cp":max(a,b)],played:[String:Any]=["cp":min(a,b)]
                let loss=NativeSkillModel.loss(best,played);precondition(loss>=0 && loss<=1)
                precondition(NativeSkillModel.loss(played,best)==0);checks+=2
            }
            var rows:[[String:Any]]=[]
            for game in 0..<140 {
                for j in 0..<8 {
                    let fork=j%2==0,pressure=random()<0.2,error=random()<(fork ? 0.72:0.10)+(pressure ? 0.08:0)
                    rows.append(["game":String(game),"ply":j,"fen":"position-\(j) w - - 0 1","tags":[fork ? "fork":"absolutePin"],"complexity":30+random()*60,"clock":["pressure":pressure],"speed":"blitz","color":"white","ended":1700000000.0+Double(game)*86400,"forced":false,"stable":true,"error":error])
                }
            }
            let model=NativeSkillModel.diagnose(rows,now:1713000000)
            let skills=model["skills"] as! [[String:Any]],fork=skills.first{$0["tag"] as? String=="fork"}!,pin=skills.first{$0["tag"] as? String=="absolutePin"}!
            precondition((fork["priority"] as! Double)>(pin["priority"] as! Double));precondition(fork["status"] as! String=="likely_weakness");checks+=2
            let validation=model["validation"] as! [String:Any]
            precondition((validation["brier"] as! Double)<(validation["baselineBrier"] as! Double));checks+=1
            let sparse=NativeSkillModel.diagnose(Array(rows.prefix(16)),now:1713000000)
            precondition((sparse["trainingPrior"] as! [String:Double]).isEmpty);checks+=1
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store=try NativeProfileStore(url:dir.appendingPathComponent("test.sqlite3"))
            try store.put("game","a","u",["value":42]);try store.put("game","a","u",["value":43]);let count=try store.count("game","u"),record=try store.get("game","a");precondition(count==1);precondition(record?["value"] as? Int==43);checks+=2
            print("{\"status\":\"passed\",\"checks\":\(checks),\"modelBrier\":\(validation["brier"]!),\"baselineBrier\":\(validation["baselineBrier"]!)}")
            return
        }
        guard args.count>1 else{return}
        let job=try await OnDeviceProfiles.shared.start(args[1],limit:args.count>2 ? Int(args[2]):nil),id=job["id"] as! String
        var last=""
        while true {
            let status=try await OnDeviceProfiles.shared.status(id),phase=status["status"] as! String
            if phase != last {FileHandle.standardError.write(Data((phase+"\n").utf8));last=phase}
            if phase=="completed" {
                let report=try await OnDeviceProfiles.shared.report(id)
                print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
                break
            }
            if ["failed","cancelled","interrupted"].contains(phase){throw NSError(domain:"Test",code:1,userInfo:[NSLocalizedDescriptionKey:String(describing:status)])}
            try await Task.sleep(for:.seconds(1))
        }
    }
}
