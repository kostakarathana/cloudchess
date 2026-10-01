import Foundation

@main struct PersistenceRegression {
    static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ reason:String){precondition(value,reason);checks+=1}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cloudchess-persistence-\(UUID())")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=PuzzleCoachStore(url:root.appendingPathComponent("coach.json"))
        let bank=try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:URL(fileURLWithPath:"CloudChess/EngineResources/puzzles.json")))
        var coach=AdaptivePuzzleCoach()
        for i in 0..<2000 {coach.begin(bank[i%bank.count]);coach.session?.elapsed=25;_ = coach.finish()}
        coach.seen=(0..<8000).map{"seen-\($0)"}
        let bytes=try JSONEncoder().encode(coach).count
        var blocking:[Double]=[],enqueue:[Double]=[]
        for _ in 0..<12 {
            let start=ProcessInfo.processInfo.systemUptime;try store.save(coach)
            blocking.append(ProcessInfo.processInfo.systemUptime-start)
        }
        // A burst of checkpoint + awaited move saves must keep FIFO mutation order,
        // use value snapshots, and never replace a new score with an older score.
        let resultQueue=DispatchQueue(label:"persistence-test-results")
        var written:[Int]=[],errors=0
        for i in 0..<60 {
            coach.total=2000+i
            let before=ProcessInfo.processInfo.systemUptime
            store.enqueue(coach) {result in
                resultQueue.sync {if case .failure=result {errors+=1};written.append(i)}
            }
            enqueue.append(ProcessInfo.processInfo.systemUptime-before)
        }
        coach.total=9001
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in store.enqueue(coach){c.resume(with:$0)} }
        check(try store.load().total==9001,"Latest score survives queued checkpoints")
        check(resultQueue.sync{written}==Array(0..<60),"Completions keep FIFO order")
        check(errors==0,"Atomic writes all completed")
        // Lifecycle flush waits for previous async checkpoints and writes the final snapshot.
        coach.total=9002;try store.save(coach)
        check(try store.load().total==9002,"Background flush is durable")
        // Reset must be ordered AFTER all old writes; no resurrection of progress.
        for _ in 0..<8 {store.enqueue(coach){_ in}}
        try await store.reset();check(!FileManager.default.fileExists(atPath:store.url.path),"Reset drains prior writes")
        try store.save(AdaptivePuzzleCoach());check(try store.load().total==0,"Fresh progress stays fresh")
        // A write failure surfaces to the caller, and every continuation completes.
        let blocked=root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to:blocked)
        let bad=PuzzleCoachStore(url:blocked.appendingPathComponent("coach.json"))
        do {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in bad.enqueue(coach){c.resume(with:$0)} }
            preconditionFailure("Expected filesystem error")
        } catch {checks+=1}
        let meanBlocking=blocking.reduce(0,+)/Double(blocking.count),meanEnqueue=enqueue.reduce(0,+)/Double(enqueue.count)
        check(meanEnqueue<meanBlocking/5,"Encoding and disk writes no longer block the enqueueing caller")
        print(String(data:try JSONSerialization.data(withJSONObject:["checks":checks,"snapshotBytes":bytes,"historyItems":2000,"syncMeanMs":meanBlocking*1000,"enqueueMeanMs":meanEnqueue*1000,"enqueueMaxMs":enqueue.max()!*1000,"scope":"Development Mac; immutable maximum-history snapshots; not phone timings","status":"passed"],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
