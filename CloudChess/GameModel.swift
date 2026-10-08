import SwiftUI
import UIKit
import AudioToolbox

struct PositionState:Codable {
    var columns:Int?=nil,rows:Int?=nil
    var fen:String,moves:[String],san:[String],legal:[String],turn:String,check:Bool,result:String?
    var capturedWhite:[String],capturedBlack:[String],lastMove:String?
}

@MainActor final class GameModel:ObservableObject {
    static let initialFEN="8/8/8/8/8/8/8/8 w - - 0 1"
    @Published var state=PositionState(fen:initialFEN,moves:[],san:[],legal:[],turn:"white",check:false,result:nil,capturedWhite:[],capturedBlack:[],lastMove:nil)
    @Published private(set) var dimensions=BoardDimensions.standard
    @Published var selected:String?
    @Published var busy=false
    @Published private(set) var pendingMove:String?
    // Explicit outcome events: restoring a session or discounting a future reward
    // must never masquerade as a change to the player's banked score.
    @Published private(set) var scoreFeedbackID=0
    @Published private(set) var scoreDirection=0
    @Published private(set) var evaluationActivity:String?
    private var mistakeFeedbackCount=0
    private var outcomeHapticCount=0
    private func scoreChanged(from previous:Double) {
        guard liveScore != previous else{return}
        scoreDirection=liveScore>previous ? 1:-1;scoreFeedbackID+=1
        outcomeHaptic(success:scoreDirection>0)
    }
    private func outcomeHaptic(success:Bool) {
        guard foreground else{return}
        outcomeHapticCount+=1
        if sound {UINotificationFeedbackGenerator().notificationOccurred(success ? .success:.warning)}
    }
    private func mistakeFeedback(at square:String,scoreBefore:Double) {
        mistakeFeedbackCount+=1
        if foreground {world.puzzleMistake(at:square);revision+=1}
        if liveScore != scoreBefore {scoreChanged(from:scoreBefore)}
        else {outcomeHaptic(success:false)}
    }
    @Published var finishing=false
    @Published var connected=false
    @Published var error:String?
    @Published var revision=0
    @Published var promotion:[String]=[]
    @Published var showUndo=false
    @Published var showSkip=false
    @Published var showHint=false
    @Published private(set) var journeyStarted:Date?
    @Published private(set) var journeyReveal:Date?
    @Published private(set) var journeyFallback=false
    private var journeyWatchdog:Task<Void,Never>?
    let journeyClouds=CloudAtmosphereDynamics()
    private var journeyEntered=false
    private var lastJourneyDuration:Double=0
    private var journeyFallbacks=0
    var journeyActive:Bool {journeyStarted != nil}
    var showsGeneration:Bool {isGenerating && (!journeyActive || journeyFallback)}
    private struct Lesson {
        let puzzle:TrainingPuzzle,history:[String],line:[String]
    }
    private struct ReplayFrame {let fen:String,move:String?}
    private var lesson:Lesson?
    @Published private(set) var hasReplay=false
    @Published private(set) var replayActive=false
    @Published private(set) var replayPlaying=false
    @Published private(set) var replayIndex=0
    @Published private(set) var replayCount=0
    private var replayFrames:[ReplayFrame]=[]
    private var replayTask:Task<Void,Never>?
    private var replayToken=UUID()
    private var replayLoading=false
    var nextHintStage:Int {coach.session?.nextHintStage ?? 1}
    var canHint:Bool {!busy && !replayActive && !showInfo && !showReturn && foreground && phase=="playing" && connected && state.result==nil && challengeKind != .whosWinning && nextHintStage<=3}
    var hintTitle:String {nextHintStage==1 ? "Reveal the area?":nextHintStage==2 ? "Reveal the piece?":"Watch the idea?"}
    func requestHint() {guard canHint else{return};showHint=true}

    var canUndo:Bool {!replayActive && challengeKind != .whosWinning && !replayActive && !busy && !showInfo && !showReturn && foreground && (phase=="playing" || phase=="failed") && !(coach.session?.moves.isEmpty ?? true) && coach.session?.succeeded != true}
    var puzzleReward:Double {coach.session?.reward ?? 0}
    @Published var phase="loading"
    @Published private(set) var isGenerating=true
    @Published private(set) var generationStep=0
    private var generationStartedAt=ProcessInfo.processInfo.systemUptime
    private var generationWorkMilliseconds=0
    private var generationFullMilliseconds=0
    private func generationProgress(_ step:Int) async {
        let next=max(generationStep,min(10,step))
        if next != generationStep {generationStep=next}
        await Task.yield()
        #if DEBUG
        if testing,ProcessInfo.processInfo.arguments.contains("--loading-audit") {try? await wait(step==4 ? 8:0.35)}
        #endif
    }
    private func finishGeneration() async throws {
        // Upload meshes/materials while the loader or journey still covers the
        // board, instead of letting its first visible frame perform that work.
        await world.prepareForDisplay?()
        generationWorkMilliseconds=Int((ProcessInfo.processInfo.systemUptime-generationStartedAt)*1000)
        await generationProgress(10)
        if let started=journeyStarted {
            // A fixed cinematic window, never fabricated generation progress.
            let remaining=(world.reducedMotion ? 0.12:0.7)-Date().timeIntervalSince(started)
            if remaining>0 {try await wait(remaining)}
            journeyWatchdog?.cancel();journeyWatchdog=nil
            if foreground && !showReturn {
                // Install the complete, stationary position under the opaque veil.
                // Wait two display frames before uncovering it; no transparent
                // entrance is racing the cloud opening or the loader's removal.
                world.settleForInstructions();boardRevealed=true;journeyEntered=true
                await Task.yield();try await wait(0.05)
                journeyFallback=false;isGenerating=false;journeyReveal=Date()
                try await wait(world.reducedMotion ? 0.18:0.5)
            } else {journeyFallback=false;isGenerating=false}
            lastJourneyDuration=Date().timeIntervalSince(started)
            journeyStarted=nil;journeyReveal=nil
        } else {
            world.settleForInstructions();boardRevealed=foreground && !showReturn;journeyEntered=true
            try await wait(world.reducedMotion ? 0.05:0.2)
            isGenerating=false
        }
        generationFullMilliseconds=Int((ProcessInfo.processInfo.systemUptime-generationStartedAt)*1000)
    }
    private func cloudJourney() async throws {
        closeReplay();world.onCancelDrag?();world.moveQuality.clear()
        journeyClouds.setTheme(board:collection.selectedBoard,pieces:collection.selectedPieces)
        journeyClouds.setBoardFootprint(.zero)
        journeyStarted=Date();journeyReveal=nil;journeyFallback=false
        let token=journeyStarted
        journeyWatchdog?.cancel()
        journeyWatchdog=Task { [weak self] in
            do {try await Task.sleep(for:.seconds(1.5))} catch {return}
            guard let self,self.journeyStarted==token,self.journeyReveal==nil else{return}
            self.journeyFallback=true;self.journeyFallbacks+=1
        }
        phase="journey"
        // The veil closes in 350 ms. Retain the full outgoing board until then.
        try await wait(world.reducedMotion ? 0.13:0.38)
        world.puzzleExit(duration:0.12)
        try await nextPuzzle()
    }
    private struct PreparedPuzzle {
        var puzzle:TrainingPuzzle
        let proof:[String:Any]?
        let parentID:String?
        let ability:Double
        let created:Date
        var assessment:EngineAssessment?=nil
    }
    private var preparedPuzzles:[ChallengeKind:PreparedPuzzle]=[:]
    @Published private(set) var preparedUsed=0
    @Published private(set) var preparedReady=0
    private var preparationTask:Task<Void,Never>?
    private var preparationToken=UUID()
    @Published private(set) var preparedMoves=0
    @Published private(set) var preparedMoveUsed=0
    private var refreshingBaseline=false
    private var personalDrillsAvailable=false
    private var preparedTurnKey=""
    private var preparedTurn:[String:(decision:TurnAnalysis.Decision,quality:MoveQuality?)]=[:]
    private var preparedReplies:[String:TurnAnalysis.PreparedReply]=[:]
    private var preparedReplyUsed=0
    private var lastTurnMilliseconds=0
    private func turnKey(_ puzzle:TrainingPuzzle,_ history:[String])->String {puzzle.id+"|"+puzzle.kind.rawValue+"|"+puzzle.fen+"|"+history.joined(separator:" ")}
    private func showMoveQuality(_ quality:MoveQuality?,move:String) {
        guard foreground else{return}
        let square=String(move.dropFirst(2).prefix(2))
        world.moveQuality.show(quality,at:world.position(square),square:square,reduced:world.reducedMotion);revision+=1
    }
    var evaluationPending:Bool {evaluationActivity != nil || (challengeKind == .tenMoves && phase=="playing" && openAssessment==nil)}
    private func stopPreparation(clear:Bool=false,keepingTurn:Bool=false,source:String?=nil,move:String?=nil) {
        preparationToken=UUID();preparationTask?.cancel();preparationTask=nil
        if keepingTurn,let p=puzzle {
            let history=state.moves
            let known=preparedTurnKey==turnKey(p,history) ? Set(preparedTurn.keys):[]
            let replies=preparedTurnKey==turnKey(p,history) ? preparedReplies.mapValues(\.move):[:]
            NativeChess.cancelPreparation {r in
                TurnAnalysis.keepsPreparation(r,puzzle:p,history:history,known:known,source:source,move:move,replies:replies)
            }
        } else {NativeChess.cancelPreparation()}
        if refreshingBaseline {evaluationActivity=nil;refreshingBaseline=false}
        if clear {preparedPuzzles.removeAll();preparedTurn.removeAll();preparedReplies.removeAll();preparedTurnKey=""}
    }
    private func schedulePreparation(nextOnly:Bool=false) {
        guard preparationTask==nil,foreground,!overlay,!showInfo,!showReturn,!replayActive,
              (phase=="playing" && !busy) || (nextOnly && phase=="celebrating"),
              !bank.isEmpty,let active=puzzle else{return}
        var speculate = !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState.rawValue<2
        let prepareNext=true
        #if DEBUG
        if testing && !ProcessInfo.processInfo.arguments.contains("--prefetch-audit") && !ProcessInfo.processInfo.arguments.contains("--turn-prefetch-audit") {speculate=false}
        #endif
        // The next player's turn is usable while its full-strength baseline is
        // updated. This essential work runs before any speculative next puzzle.
        if !nextOnly,active.kind != .tactics && active.kind != .whosWinning,openAssessment==nil,
           let cached=ChallengeEngine.cached(initial:active.fen,moves:state.moves,multipv:state.moves.isEmpty ? 3:1) {
            installAssessment(cached)
        }
        if !speculate && (nextOnly || active.kind == .tactics || active.kind == .whosWinning || openAssessment != nil) {return}
        let token=UUID();preparationToken=token
        let snapshot=coach,catalog=bank,hasPersonal=personalDrillsAvailable
        let history=state.moves,position=state,baseline=openAssessment
        if !nextOnly && active.kind != .tactics && active.kind != .whosWinning && baseline==nil {refreshingBaseline=true;evaluationActivity="Updating position evaluation"}
        preparationTask=Task { [weak self] in
            await Task.yield()
            guard let self,self.preparationToken==token,!Task.isCancelled else{return}
            let epoch=CCBackgroundEpoch()
            await NativeChess.$backgroundEpoch.withValue(epoch) {
                do {
                    if !nextOnly && active.kind != .tactics && active.kind != .whosWinning {
                        let best:EngineAssessment
                        if let baseline {best=baseline}
                        else {
                            #if DEBUG
                            if self.testing,ProcessInfo.processInfo.arguments.contains("--baseline-audit") {try await self.wait(5)}
                            #endif
                            best=try await ChallengeEngine.evaluate(initial:active.fen,moves:history,multipv:history.isEmpty ? 3:1).1
                            guard self.preparationToken==token,self.puzzle?.id==active.id,self.state.moves==history,!self.busy else{throw CancellationError()}
                            self.installAssessment(best);self.refreshingBaseline=false;self.evaluationActivity=nil
                        }
                        if speculate {
                            // Likely current decisions get priority over next-puzzle
                            // generation. Bound work to three roots, never every move.
                            let book=(active.kind == .opening || !active.kind.usesHearts) ? (try await OpeningLibrary.shared.continuations(fen:position.fen)):[:]
                            var alternatives=best.alternativeMoves
                            if (active.kind == .tenMoves || active.kind == .finish),alternatives.count<2,book.count<3,position.legal.count>1 {
                                // Later baselines use single-PV analysis, which used
                                // to leave only ONE move prepared outside the book.
                                // A tiny scout ranks work; every resulting verdict
                                // below still requires the unchanged full budget.
                                let scout=try await ChallengeEngine.evaluate(initial:active.fen,moves:history,budget:60_000,multipv:3).1
                                alternatives += Array(scout.line.prefix(1))+scout.alternativeMoves
                            }
                            let candidates=TurnAnalysis.candidates(best:best.line.first,book:book,legal:position.legal,alternatives:alternatives)
                            for move in candidates {
                                try Task.checkCancellation()
                                let decision=try await TurnAnalysis.assess(active.kind,initial:active.fen,history:history,move:move,baseline:best)
                                guard self.preparationToken==token,epoch==CCBackgroundEpoch() else{throw CancellationError()}
                                let quality = !active.kind.usesHearts ? try await MoveQualityJudge.grade(initial:active.fen,history:history,move:move,beforeFEN:position.fen,decision:decision,elo:snapshot.modeAbility(active.kind),book:book[move] != nil):nil
                                guard self.preparationToken==token,epoch==CCBackgroundEpoch(),self.state.moves==history,self.puzzle?.id==active.id else{throw CancellationError()}
                                let key=self.turnKey(active,history)
                                if self.preparedTurnKey != key {self.preparedTurn.removeAll();self.preparedReplies.removeAll();self.preparedTurnKey=key}
                                self.preparedTurn[move]=(decision,quality)
                                self.preparedMoves+=1
                                if active.kind == .tenMoves || active.kind == .finish {
                                    let nextHistory=history+[move]
                                    let after=try await ChallengeEngine.state(active,moves:nextHistory)
                                    if after["result"] is NSNull {
                                        let elo=snapshot.session?.opponentElo ?? snapshot.ability.mean
                                        let reply=try await ChallengeEngine.opponent(initial:active.fen,moves:nextHistory,elo:elo)
                                        guard self.preparationToken==token,epoch==CCBackgroundEpoch(),self.state.moves==history,self.puzzle?.id==active.id else{throw CancellationError()}
                                        self.preparedReplies[move]=TurnAnalysis.PreparedReply(initial:active.fen,history:nextHistory,elo:elo,move:reply)
                                        #if DEBUG
                                        if self.testing {self.revision+=1}
                                        #endif
                                    }
                                }
                            }
                            if active.kind == .blunderPunish,snapshot.session?.blunderPly==nil,(history.count+2)/2>=BlunderEngine.targetTurn(seed:active.blunderSeed ?? 0) {
                                for move in candidates {
                                    try Task.checkCancellation()
                                    _ = try await BlunderEngine.find(initial:active.fen,moves:history+[move],seed:active.blunderSeed ?? 0)
                                }
                            }
                            // Only the best continuation's successor is pre-evaluated;
                            // current alternatives above always have first priority.
                            if (active.kind == .opening || active.kind == .personal),let move=best.line.first,
                               let decision=self.preparedTurn[move]?.decision,!decision.rejected {
                                let after=try await ChallengeEngine.state(active,moves:history+[move])
                                if after["result"] is NSNull,let reply=TurnAnalysis.reply(move:move,assessment:decision.played,legal:after["legal"] as? [String] ?? []) {
                                    _ = try await ChallengeEngine.evaluate(initial:active.fen,moves:history+[move,reply])
                                }
                            }
                            if (active.kind == .tenMoves || active.kind == .finish),let move=best.line.first,
                               let reply=self.preparedReplies[move] {
                                _ = try await ChallengeEngine.evaluate(initial:active.fen,moves:reply.history+[reply.move])
                            }
                        }
                    } else if !nextOnly && speculate && active.kind == .tactics {
                        // Tactical grading and its defense can also be ready before a drop.
                        let winners=Array((self.guide["winning"] as? [String] ?? []).prefix(2))
                        for move in winners {
                            var judge=active.request("judge",moves:history);judge["candidate"]=move;judge["budget"]=1_000_000
                            let verdict=try await NativeChess.call(judge)
                            if verdict["accepted"] as? Bool==true {
                                let nextHistory=history+[move]
                                let defense=try await NativeChess.call(active.request("guide",moves:nextHistory))
                                if let reply=(defense["line"] as? [String])?.first,nextHistory.count+1<active.plies {
                                    _ = try await NativeChess.call(active.request("guide",moves:nextHistory+[reply]))
                                }
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled || epoch != CCBackgroundEpoch() {return}
                    // Failed speculation never grades a move or disables play.
                    if self.preparationToken==token {self.refreshingBaseline=false;self.evaluationActivity=nil}
                }
                guard speculate,prepareNext,!Task.isCancelled,self.preparationToken==token else{return}
                // Allow the current move/entrance to settle before filling the
                // next-puzzle buffer. No competing Stockfish instance is started.
                do {try await Task.sleep(nanoseconds:300_000_000)}catch{return}
                var forecast=snapshot
                if forecast.session?.recorded==false {_ = forecast.finish()}
                self.preparedPuzzles=self.preparedPuzzles.filter {kind,entry in
                    Date().timeIntervalSince(entry.created)<600 && abs(forecast.challengeLevel(kind)-entry.ability)<=150
                }
                let ready=Set(self.preparedPuzzles.keys)
                var selector=forecast
                let predicted=selector.selectChallengeKind(personalAvailable:hasPersonal)
                let selectionSnapshot=selector
                var kinds=[predicted]
                kinds.removeAll{ready.contains($0) || $0 == .personal}
                for kind in kinds {
                    guard !Task.isCancelled,self.preparationToken==token,epoch==CCBackgroundEpoch() else{break}
                    do {
                        let result:PreparedPuzzle
                        if kind == .tactics {
                            let choices=await Task.detached(priority:.utility) {var c=selectionSnapshot;return c.candidates(catalog)}.value
                            var found:PreparedPuzzle?
                            for parent in choices.prefix(4) {
                                try Task.checkCancellation()
                                guard parent.id != forecast.session?.puzzle.id else{continue}
                                var p=parent
                                // Composition uses a private RNG; live selection state is untouched.
                                if let proposal=parent.composition(seed:selector.nextRandom()),!forecast.seen.contains(proposal.id),forecast.allowsNextPuzzle(proposal) {
                                    var r=proposal.request("certify");r["budget"]=parent.compositionBudget;r["measureDifficulty"]=true
                                    if let proof=try? await NativeChess.call(r) {
                                        var measured=proposal;try measured.applyDifficulty(proof)
                                        if forecast.acceptsComposition(measured,from:parent) {p=measured;found=PreparedPuzzle(puzzle:p,proof:proof,parentID:parent.id,ability:forecast.challengeLevel(kind),created:Date());break}
                                    }
                                }
                                var r=p.request("certify");if p.difficultyVersion != "challenge-v2" {r["measureDifficulty"]=true}
                                if let proof=try? await NativeChess.call(r) {
                                    if p.difficultyVersion != "challenge-v2" {try p.applyDifficulty(proof)}
                                    found=PreparedPuzzle(puzzle:p,proof:proof,parentID:parent.id,ability:forecast.challengeLevel(kind),created:Date());break
                                }
                            }
                            guard let found else{continue};result=found
                        } else {
                            let p:TrainingPuzzle
                            if kind == .opening {p=try await OpeningLibrary.shared.generate(rating:forecast.targetRating(for:kind),seed:selector.nextRandom(),excluding:Set(forecast.seen+[forecast.session?.puzzle.id ?? ""]),avoiding:forecast.blockedPuzzleKeys,skills:forecast.skills,progress:nil)}
                            else if kind == .whosWinning {p=try await JudgmentLibrary.shared.generate(rating:forecast.targetRating(for:kind),draw:forecast.judgmentDraws ?? 0,seed:selector.nextRandom(),excluding:Set(forecast.seen),avoiding:forecast.blockedPuzzleKeys)}
                            else if kind == .blunderPunish {p=try await BlunderEngine.generate(rating:forecast.targetRating(for:kind),seed:selector.nextRandom(),opponent:forecast.opponentRating(for:kind),excluding:Set(forecast.seen),avoiding:forecast.blockedPuzzleKeys)}
                            else {p=try await ChallengeEngine.generated(kind,rating:forecast.targetRating(for:kind),seed:selector.nextRandom(),opponentElo:forecast.opponentRating(for:kind),learner:forecast.challengeLevel(kind),targetSuccess:forecast.target(for:kind),opponentBounds:forecast.opponentBounds(for:kind),excluding:Set(forecast.seen+[forecast.session?.puzzle.id ?? ""]),avoiding:forecast.blockedPuzzleKeys)}
                            result=PreparedPuzzle(puzzle:p,proof:nil,parentID:nil,ability:forecast.challengeLevel(kind),created:Date(),assessment:ChallengeEngine.cached(initial:p.fen,moves:[],multipv:3))
                        }
                        guard !Task.isCancelled,self.preparationToken==token,epoch==CCBackgroundEpoch() else{break}
                        guard forecast.allowsNextPuzzle(result.puzzle) else{continue}
                        self.preparedPuzzles[kind]=result;self.preparedReady=self.preparedPuzzles.count
                        if kind == .opening {
                            let candidate=result.puzzle
                            let (position,best)=try await ChallengeEngine.evaluate(initial:candidate.fen,multipv:3)
                            if let move=best.line.first {
                                let after=try await ChallengeEngine.state(candidate,moves:[move])
                                if let reply=TurnAnalysis.reply(move:move,assessment:best,legal:after["legal"] as? [String] ?? []),position["result"] is NSNull {
                                    _ = try await ChallengeEngine.evaluate(initial:candidate.fen,moves:[move,reply])
                                }
                            }
                        }
                    } catch {if Task.isCancelled || epoch != CCBackgroundEpoch(){break}}
                }
            }
            if self.preparationToken==token {self.preparationTask=nil}
        }
    }
    private func takePrepared(_ kind:ChallengeKind,parents:[TrainingPuzzle]=[])->PreparedPuzzle? {
        guard var ready=preparedPuzzles.removeValue(forKey:kind) else{return nil}
        #if DEBUG
        #endif
        guard let validated=PreparedChallengeGate.revalidate(ready.puzzle,ability:ready.ability,age:Date().timeIntervalSince(ready.created),coach:coach,excluded:excludedPuzzleID,instruction:requiredInstructionType,parent:parents.first{$0.id==ready.parentID}) else{return nil}
        ready.puzzle=validated
        preparedUsed+=1
        return ready
    }
    @Published var coach=AdaptivePuzzleCoach()
    var presentingReward:Bool {false}
    // Collection progress remains archived in coach.collection; no grants or skins are active.
    var collection:CollectionProgress {CollectionProgress()}
    var displayedPieces:Int {0}
    @Published var showInfo=false
    @Published var showReturn=false
    @Published private(set) var boardRevealed=false
    @Published private(set) var firstTypeIntroduction=false
    private var requiredInstructionType:String?
    private var excludedPuzzleID:String?
    var instructionType:String {coach.session?.instructionType ?? challengeKind.rawValue}
    var instructionExplanation:String {
        if instructionType=="mate" {return "Find the winning moves and checkmate the king."}
        if instructionType=="improvement" {return "Find the winning continuation to improve your position."}
        return challengeExplanation
    }
    @Published var challengeNotice:String?
    var challengeKind:ChallengeKind {puzzle?.kind ?? coach.challengeMode ?? .tactics}
    var challengeTitle:String {challengeKind == .tactics ? ((puzzle?.mate ?? 0)>0 ? "Checkmate the king":"Improve your position"):challengeKind.title}
    var challengeExplanation:String {challengeKind.explanation(mate:puzzle?.mate ?? 0,plies:puzzle?.plies ?? 0)}
    var liveScore:Double {
        coach.currentScore
    }
    @Published var sound:Bool {didSet{UserDefaults.standard.set(sound,forKey:"cloudchess.sound")}}
    @Published var motion:Bool {didSet{UserDefaults.standard.set(motion,forKey:"cloudchess.motion")}}
    @Published private(set) var boardStyle=BoardStyle.ocean
    let world=CloudScene()
    private let styleDefaults:UserDefaults,store:PuzzleCoachStore
    #if DEBUG
    private let testing=ProcessInfo.processInfo.arguments.contains("--uitesting")
    #else
    private let testing=false
    #endif
    private var bank:[TrainingPuzzle]=[]
    private var guide:[String:Any]=[:]
    private var openAssessment:EngineAssessment?
    private var moveQueued=false,foreground=true,overlay=false
    private var systemReducedMotion=false
    func configureMotion(reduced:Bool) {systemReducedMotion=reduced;world.setMotion(reduced || !motion);if (reduced || !motion) && replayPlaying {toggleReplay()}}
    private var clockStarted:TimeInterval?
    private var ticker:Task<Void,Never>?
    #if DEBUG
    private var smoothnessAudit:MainThreadPulseAudit?
    #endif
    var puzzle:TrainingPuzzle? {coach.session?.puzzle}
    var solverWhite:Bool {puzzle?.white ?? true}
    var blunderProgress:Int {guard let injected=coach.session?.blunderPly else{return 0};return min(3,max(0,(state.moves.count-injected+1)/2))}
    var blunderStage:String {coach.session?.blunderPly==nil ? "Stay balanced":"Keep the advantage · \(blunderProgress) / 3"}
    var remaining:Int {coach.session?.recorded==true ? 0:max(0,(puzzle?.solverMoves ?? 1)-(state.moves.count+1)/2)}
    var diagnostic:String {
        "generationWorkMs:\(generationWorkMilliseconds),generationFullMs:\(generationFullMilliseconds),errorDetail:\((error ?? "").replacingOccurrences(of:",",with:";").replacingOccurrences(of:"\n",with:" ")),searchExecuted:\(NativeChess.searchMetrics["executed"] ?? 0),searchJoined:\(NativeChess.searchMetrics["joined"] ?? 0),searchPreserved:\(NativeChess.searchMetrics["preserved"] ?? 0),lastJourneyMs:\(Int(lastJourneyDuration*1000)),journeyFallbacks:\(journeyFallbacks),hintMarks:\(world.marks.childNodes.count),boardMatches:\(world.symbols==CloudScene.decode(state.fen).filter{dimensions.position($0.key) != nil} ? 1:0),journey:\(journeyActive ? 1:0),journeyFallback:\(journeyFallback ? 1:0),replay:\(replayActive ? 1:0),replayIndex:\(replayIndex),replayCount:\(replayCount),hintStage:\(coach.session?.hintStage ?? 0),hintDiscounts:\(coach.session?.hintDiscounts ?? 0),moveGrade:\(world.moveQuality.lastQuality),gradeEvents:\(world.moveQuality.events),gradeSquare:\(world.moveQuality.square),judgmentAnswer:\(puzzle?.judgment?.verdict.rawValue ?? ""),blunderPly:\(coach.session?.blunderPly ?? -1),blunderProgress:\(blunderProgress),challengeLevel:\(Int(coach.challengeLevel(challengeKind))),opponent:\(Int(coach.session?.opponentElo ?? 0)),modeAbility:\(Int(coach.modeAbility(challengeKind))),targetRating:\(Int(coach.targetRating(for:challengeKind))),scoreEvents:\(scoreFeedbackID),scoreDirection:\(scoreDirection),mistakeFeedback:\(mistakeFeedbackCount),outcomeHaptics:\(outcomeHapticCount),evaluating:\(evaluationActivity == nil ? 0:1)," +
        "hearts:\(coach.remainingHearts),best:\(Int(coach.scoring?.best ?? 0)),generating:\(isGenerating ? 1:0),generationStep:\(generationStep),contents:\(collection.pending?.shards.count ?? 0),undos:\(coach.session?.undoCount ?? 0),reward:\(Int(puzzleReward))," +
        "lastTurnMs:\(lastTurnMilliseconds),preparedReplyUsed:\(preparedReplyUsed),preparedReplies:\(preparedReplies.count),preparedMoves:\(preparedMoves),preparedMoveUsed:\(preparedMoveUsed),preparedReady:\(preparedReady),preparedUsed:\(preparedUsed),pendingMove:\(pendingMove ?? ""),visibleSquares:\(world.symbols.keys.sorted().joined(separator:"|")),rewardPicks:\(collection.pending?.choices.count ?? 0),rewardChosen:\((collection.pending?.choices ?? []).map(String.init).joined(separator:"|")),rewardOwned:\(collection.quantities.values.reduce(0,+)),profileSaved:\(UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!.object(forKey:"cloudchess.profileLink")==nil ? 0:1),profileFile:\(FileManager.default.fileExists(atPath:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CloudChess/profiles.sqlite3").path) ? 1:0),motion:\(motion ? 1:0),boardTheme:\(collection.selectedBoard),pieceTheme:\(collection.selectedPieces),ownedBoards:\(collection.masks.count),collectionSolved:\(collection.successes),rewardBoard:\(collection.pending == nil ? 0:1),winning:\((guide["winning"] as? [String] ?? []).joined(separator:"|")),instructionType:\(instructionType),revealed:\(boardRevealed ? 1:0),kind:\(challengeKind.rawValue),cp:\(Int(coach.session?.evaluation ?? 0)),score:\(Int(liveScore)),selected:\(selected ?? ""),moves:\(state.moves.count),error:\(error == nil ? 0:1),itemRating:\(Int(puzzle?.rating ?? 0)),difficulty:\(puzzle?.difficultyVersion ?? "legacy"),side:\(solverWhite ? "white":"black"),phase:\(phase),ready:\(!busy && phase=="playing" && !showReturn ? 1:0),completed:\(coach.total),mistakes:\(coach.session?.mistakes ?? 0),hints:\(coach.session?.hints ?? 0),rating:\(Int(coach.ability.mean)),id:\(puzzle?.id ?? ""),next:\((guide["line"] as? [String])?.first ?? ""),legal:\(state.legal.joined(separator:"|")),confetti:\(world.celebration.count),bursts:\(world.celebration.bursts)"
    }
    init() {
        NativeChess.setGameplayActive(true)
        styleDefaults=testing ? UserDefaults(suiteName:"com.maroon.CloudChess.uitests")!:UserDefaults.standard
        if testing && !ProcessInfo.processInfo.arguments.contains("--preserve-style") {styleDefaults.removeObject(forKey:"cloudchess.boardStyle")}
        sound=testing ? false:(UserDefaults.standard.object(forKey:"cloudchess.sound") as? Bool ?? true)
        motion=testing ? !ProcessInfo.processInfo.arguments.contains("--reduced-motion"):(UserDefaults.standard.object(forKey:"cloudchess.motion") as? Bool ?? true)
        store=PuzzleCoachStore(testing:testing)
        if testing && !ProcessInfo.processInfo.arguments.contains("--preserve-coach") {try? FileManager.default.removeItem(at:store.url)}
        do {coach=try store.load()} catch {self.error=error.localizedDescription}
        coach.scoring?.total=max(0,coach.scoring?.total ?? 0)
        coach.scoring?.best=max(coach.scoring?.best ?? 0,coach.scoring?.total ?? 0)
        showReturn=coach.session != nil
        #if DEBUG
        if testing,!ProcessInfo.processInfo.arguments.contains("--preserve-coach"),let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--score=")}),let value=Double(arg.dropFirst(8)) {coach.scoring=ChallengeScore(total:max(0,value),best:max(0,value))}
        if testing,ProcessInfo.processInfo.arguments.contains("--collection-fixture") {var value=CollectionProgress();value.masks=["board-1":255,"board-3":3,"pieces-2":63];coach.collection=value}
        if testing,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--collection-audit=")}),let theme=Int(arg.dropFirst(19)),CollectionTheme.find(theme) != nil {
            var value=CollectionProgress();value.masks=["board-\(theme)":255,"pieces-\(theme)":63];value.selectedBoard=theme;value.selectedPieces=theme;coach.collection=value
        }
        if testing,ProcessInfo.processInfo.arguments.contains("--reset-fixture") {
            let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CloudChess")
            if let archive=try? NativeProfileStore(url:base.appendingPathComponent("profiles.sqlite3")) {try? archive.put("game","reset-fixture","test",["sample":true])}
            UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!.set("fixture",forKey:"cloudchess.profileLink")
        }
        if testing,ProcessInfo.processInfo.arguments.contains("--reward-soon") {var value=CollectionProgress();value.successes=2;value.target=3;coach.collection=value}
        if testing,ProcessInfo.processInfo.arguments.contains("--reward-doors") {var value=CollectionProgress();value.pending=RewardBoard(seed:42);coach.collection=value}
        #endif
        coach.activateFocusedPuzzles()
        showReturn=coach.session != nil
        if testing,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--board=")}) {
            let parts=arg.dropFirst(8).split(separator:"x").compactMap{Int($0)}
            if parts.count==2,let size=BoardDimensions(columns:parts[0],rows:parts[1]) {coach.preferredColumns=size.columns;coach.preferredRows=size.rows}
        }
        if !styleDefaults.bool(forKey:"cloudchess.dynamicCloudsV2"),!testing {
            motion=true;styleDefaults.set(true,forKey:"cloudchess.dynamicCloudsV2")
        }
        coach.preferredColumns=nil;coach.preferredRows=nil
        #if DEBUG
        if testing,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--judgment-draw=")}),let index=Int(arg.dropFirst(16)) {coach.judgmentDraws=index}
        #endif
        #if DEBUG
        if testing,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--board=")}) {
            let parts=arg.dropFirst(8).split(separator:"x").compactMap{Int($0)}
            if parts.count==2 {coach.preferredColumns=parts[0];coach.preferredRows=parts[1]}
        }
        #endif
        boardStyle=BoardStyle(rawValue:styleDefaults.string(forKey:"cloudchess.boardStyle") ?? "") ?? .ocean
        world.setBoardStyle(boardStyle);world.setCollection(board:collection.selectedBoard,pieces:collection.selectedPieces);world.island.opacity=0
        world.onSquare={ [weak self] in self?.choose($0) }
        world.canDrag={ [weak self] in self?.canPickUp($0) ?? false }
        world.onDragBegin={ [weak self] in self?.beginDrag($0) ?? false }
        world.canDrop={ [weak self] in self?.canDrop(from:$0,to:$1) ?? false }
        world.onDrop={ [weak self] in self?.drop(from:$0,to:$1) ?? false }
    }
    deinit {ticker?.cancel();replayTask?.cancel();journeyWatchdog?.cancel()}
    func setBoardStyle(_ style:BoardStyle) {
        guard style != boardStyle else{return}
        boardStyle=style;world.setBoardStyle(style);styleDefaults.set(style.rawValue,forKey:"cloudchess.boardStyle")
        if sound {UISelectionFeedbackGenerator().selectionChanged()}
    }
    func pauseClock() {
        if let start=clockStarted {
            let seconds=max(0,ProcessInfo.processInfo.systemUptime-start)
            coach.session?.elapsed+=seconds
        }
        clockStarted=nil
    }
    private func resumeClock() {
        NativeChess.setGameplayActive(foreground && !overlay)
        schedulePreparation()
        if foreground && !replayActive && !overlay && !busy && !showInfo && !showReturn && boardRevealed && phase=="playing" && coach.session?.recorded==false && clockStarted==nil {clockStarted=ProcessInfo.processInfo.systemUptime}
    }
    func setActive(_ active:Bool) {
        if !active {closeReplay();showHint=false;stopPreparation();world.moveQuality.clear()}
        pauseClock();foreground=active;NativeChess.setGameplayActive(active && !overlay);checkpoint();resumeClock()
        if active {Task{await refreshConnectedProfile()}}
    }
    func didEnterBackground() {
        stopPreparation()
        pauseClock();foreground=false;NativeChess.setGameplayActive(false)
        if puzzle != nil {
            showReturn=true;showInfo=false;boardRevealed=false
            world.onCancelDrag?()
        }
        checkpoint(flush:true)
    }
    func setOverlay(_ visible:Bool) {if visible {stopPreparation()};pauseClock();overlay=visible;if !visible{loadProfilePrior()};checkpoint();resumeClock()}
    private func checkpoint(flush:Bool=false) {
        // Background is the durability barrier. Ordinary HUD/collection changes
        // enqueue synchronously in mutation order, then return to animation.
        if flush {do {try store.save(coach)} catch {handle(error)};return}
        store.enqueue(coach) { [weak self] result in
            if case .failure(let error)=result {Task { @MainActor in self?.handle(error)}}
        }
    }
    private func save() async throws {
        // Register with the FIFO before suspension so a newer checkpoint can
        // never be overwritten by an older asynchronously scheduled snapshot.
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            store.enqueue(coach) {continuation.resume(with:$0)}
        }
    }
    private func loadProfilePrior() {
        let defaults=testing ? UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!:UserDefaults.standard
        if let data=defaults.data(forKey:"cloudchess.profileReport"),let report=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {coach.importProfile(report)}
    }
    private var importedReportKey:String?
    private func refreshConnectedProfile() async {
        let defaults=testing ? UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!:UserDefaults.standard
        guard let id=defaults.string(forKey:"cloudchess.profileJob") else{return}
        do {
            let status=try await OnDeviceProfiles.shared.upgradeIfNeeded(id)
            if status["status"] as? String=="completed" {
                let key=id+"|"+(status["report"] as? String ?? "")
                guard importedReportKey != key else{return}
                let report=try await OnDeviceProfiles.shared.report(id)
                coach.importProfile(report)
                defaults.set(try JSONSerialization.data(withJSONObject:report),forKey:"cloudchess.profileReport")
                importedReportKey=key
            }
        }catch {
            // A disconnected profile never disables the offline puzzle bank.
            if coach.challengeMode == .personal {challengeNotice="Open your profile to resume game analysis."}
        }
    }
    func start() async {
        #if DEBUG
        if testing,ProcessInfo.processInfo.arguments.contains("--smoothness-audit"),smoothnessAudit==nil {
            smoothnessAudit=MainThreadPulseAudit { [weak self] in
                guard let self else{return "released"}
                if self.isGenerating {return "generation-stage-\(self.generationStep)"}
                if self.showInfo || self.showReturn {return "instructions"}
                return self.evaluationActivity != nil ? "analysis":"playing"
            }
        }
        #endif
        guard !busy else{return};busy=true;pauseClock();defer{evaluationActivity=nil;isGenerating=false;busy=false;resumeClock()}
            if ticker==nil {ticker=Task{[weak self] in
                while !Task.isCancelled {
                    do {try await Task.sleep(nanoseconds:10_000_000_000)} catch{return}
                    guard let self else{return};guard self.clockStarted != nil else{continue}
                    self.pauseClock();self.checkpoint();self.resumeClock()
                }
            }}
        do {
            #if DEBUG
            if testing,ProcessInfo.processInfo.arguments.contains("--premium-art-audit") {await CollectionArt.premiumAudit()}
            if testing,ProcessInfo.processInfo.arguments.contains("--art-audit") {await CollectionArt.audit()}
            #endif
            await generationProgress(1)
            if bank.isEmpty {
                guard let url=Bundle.main.url(forResource:"puzzles",withExtension:"json",subdirectory:"EngineResources") else{throw failure("Missing offline puzzle bank")}
                bank=try await Task.detached(priority:.userInitiated){try JSONDecoder().decode([TrainingPuzzle].self,from:Data(contentsOf:url))}.value
            }
            if showReturn {return}
            coach.migrateDifficulty()
            #if DEBUG
            if testing,let a=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--challenge=")}),let k=ChallengeKind(rawValue:String(a.dropFirst(12))) {coach.challengeMode=k}
            #endif
            loadProfilePrior()
            await refreshConnectedProfile()
            #if DEBUG
            if testing,coach.total==0,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--learner=")}),let rating=Double(arg.dropFirst(10)) {coach.ability.mean=min(3000,max(350,rating))}
            #endif
            if let s=coach.session,!s.recorded,s.puzzle.kind == .tactics,s.puzzle.difficultyVersion != "challenge-v2" {
                var request=s.puzzle.request("certify");request["measureDifficulty"]=true
                let certificate=try await NativeChess.call(request)
                var measured=s.puzzle;try measured.applyDifficulty(certificate)
                coach.session?.puzzle=measured;try await save()
            }
            if let s=coach.session,!s.recorded {
                let response=try await NativeChess.call(s.puzzle.request(moves:s.moves))
                await prepareScene(response);apply(response);connected=true;error=nil
                if s.puzzle.kind != .tactics {
                    try await resumeOpenChallenge();enterBoard()
                }
                else if response["solved"] as? Bool==true {
                    if let tags=response["tags"] as? [String] {coach.session?.puzzle.tags=tags}
                    try await complete()
                }
                else {try await continueDefense();phase="playing";enterBoard();try await wait(0.02);introduce()}
            } else {try await nextPuzzle()}

        } catch {handle(error)}
    }
    private func failure(_ message:String)->NSError {NSError(domain:"CloudChess.Puzzle",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    private func wait(_ seconds:Double) async throws {try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
    private func nextPuzzle() async throws {
        async let sharedAssets:Void = CollectionArt.prepareShared(board:displayedBoard,pieces:displayedPieces)
        try await generateNextPuzzle()
        await sharedAssets
    }
    private func generateNextPuzzle() async throws {
        closeReplay();showHint=false
        stopPreparation()
        evaluationActivity=nil;world.moveQuality.clear()
        generationStartedAt=ProcessInfo.processInfo.systemUptime
        isGenerating=true;generationStep=0;error=nil
        await generationProgress(1)
        pauseClock();boardRevealed=false;phase="arriving";finishing=false;promotion=[];selected=nil;guide=[:]
        loadProfilePrior()
        await refreshConnectedProfile()
        await generationProgress(2)
        #if DEBUG
        if testing,journeyActive,ProcessInfo.processInfo.arguments.contains("--journey-slow") {try await wait(4)}
        #endif
        personalDrillsAvailable=false
        coach.challengeMode = .tactics

        let snapshot=coach,catalog=bank.filter {p in
            p.id != excludedPuzzleID && (requiredInstructionType==nil || (requiredInstructionType=="mate" ? p.mate>0:p.mate==0))
        }
        let selection=await Task.detached(priority:.userInitiated){
            var model=snapshot;let candidates=model.candidates(catalog)
            return (candidates,model.sequence,model.focusedSelection)
        }.value
        await generationProgress(3)
        coach.sequence=selection.1;coach.focusedSelection=selection.2
        try await save()
        var candidates=selection.0
        #if DEBUG
        if testing,coach.total==0,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--puzzle-mate=")}),let mate=Int(arg.dropFirst(14)) {
            candidates=catalog.filter{p in p.mate==mate && (coach.preferredColumns==nil || (p.columns==coach.preferredColumns && p.rows==coach.preferredRows))}.prefix(16).map{$0.variant(0)}
        }
        if testing,coach.total==0,ProcessInfo.processInfo.arguments.contains("--puzzle-promotion") {
            candidates=bank.filter{$0.mate==1 && $0.columns==6 && $0.rows==6 && $0.line.first?.count==5}.prefix(16).map{$0.variant($0.white ? 2:0)}
        }
        if testing,coach.total==0,ProcessInfo.processInfo.arguments.contains("--occluded-target"),var fixture=bank.first(where:{$0.columns==6 && $0.rows==6}) {
            fixture.id="regression-occluded-square";fixture.source=fixture.id
            fixture.fen="8/8/Q4b2/1p1k4/1Brppn2/4P3/5p2/5K2 w - - 0 1"
            fixture.mate=1;fixture.plies=1;fixture.line=[];fixture.difficultyVersion=nil;fixture.botSuccess=nil
            candidates=[fixture]
        }
        if testing,coach.total==0,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--solver=")}) {
            let white=arg=="--solver=white"
            candidates=candidates.map{$0.white==white ? $0:$0.variant(2)}
        }
        #endif
        candidates=candidates.filter{coach.allowsNextPuzzle($0) && $0.id != excludedPuzzleID && (requiredInstructionType==nil || (requiredInstructionType=="mate" ? $0.mate>0:$0.mate==0))}
        if let ready=takePrepared(.tactics,parents:candidates),let proof=ready.proof {
            var p=ready.puzzle;p.tags=proof["tags"] as? [String] ?? p.tags;p.line=proof["line"] as? [String] ?? p.line;p.nodes=proof["nodes"] as? Int ?? p.nodes
            coach.begin(p);try await save();guide=proof;await prepareScene(proof);apply(proof);connected=true;error=nil
            await generationProgress(9);try await finishGeneration();phase="playing";introduce();enterBoard();try await wait(0.02);return
        }
        var lastError:Error=failure("No certified puzzle available")
        for p in candidates {
            do {
                var generated=p
                var certificate:[String:Any]?
                // Fixed, reproducible work budget. Failed candidates never reach
                // the board, and offline play never waits indefinitely to create
                // a new position. Proven bank variations provide the fallback.
                await generationProgress(4)
                let reviewing=coach.reviews.contains{$0.due<=coach.total && $0.puzzle.id==p.id}
                if (!testing || ProcessInfo.processInfo.arguments.contains("--compose")) && !reviewing {
                    for _ in 0..<3 {
                        guard let proposal=p.composition(seed:coach.nextRandom()),!coach.seen.contains(proposal.id),coach.allowsNextPuzzle(proposal) else{continue}
                        var request=proposal.request("certify");request["budget"]=p.compositionBudget;request["measureDifficulty"]=true
                        if let proof=try? await NativeChess.call(request) {
                            var measured=proposal;try measured.applyDifficulty(proof)
                            if coach.acceptsComposition(measured,from:p) {generated=measured;certificate=proof;break}
                        }
                    }
                }
                await generationProgress(6)
                let certified: [String:Any]
                if let certificate {certified=certificate} else {
                    var request=p.request("certify")
                    if p.difficultyVersion != "challenge-v2" {request["measureDifficulty"]=true}
                    certified=try await NativeChess.call(request)
                    if p.difficultyVersion != "challenge-v2" {try generated.applyDifficulty(certified)}
                }
                await generationProgress(8)
                generated.tags=certified["tags"] as? [String] ?? p.tags
                generated.line=certified["line"] as? [String] ?? p.line
                generated.nodes=certified["nodes"] as? Int ?? p.nodes
                coach.begin(generated);try await save();guide=certified;await prepareScene(certified);apply(certified);connected=true;error=nil
                await generationProgress(9);try await finishGeneration()
                phase="playing";introduce();enterBoard();try await wait(0.02);return
            } catch {lastError=error}
        }
        throw lastError
    }
    private func prepareScene(_ response:[String:Any]) async {
        let size=BoardDimensions(columns:response["columns"] as? Int ?? 8,rows:response["rows"] as? Int ?? 8) ?? .standard
        await CollectionArt.prepare(board:displayedBoard,pieces:displayedPieces,dimensions:size)
    }
    private var displayedBoard:Int {0}
    private func apply(_ response:[String:Any],animated:Bool=false) {
        do {
            openAssessment=nil
            let next=try JSONDecoder().decode(PositionState.self,from:JSONSerialization.data(withJSONObject:response))
            dimensions=BoardDimensions(columns:next.columns ?? 8,rows:next.rows ?? 8)!
            world.additionalBottomClearance=puzzle?.kind == .whosWinning ? 140:(puzzle?.kind == .tenMoves ? 85:0)
            world.orient(whiteAtBottom:solverWhite)
            state=next;selected=nil;world.display(next.fen,move:animated ? next.lastMove:nil,dimensions:dimensions)
            #if DEBUG
            if testing,ProcessInfo.processInfo.arguments.contains("--piece-gallery") {world.display(dimensions.initialFEN,dimensions:dimensions)}
            #endif
            revision+=1
        } catch {handle(error)}
    }
    private func refreshGuide() async throws {
        guard let p=puzzle else{throw failure("Missing active puzzle")}
        guide=try await NativeChess.call(p.request("guide",moves:state.moves));revision+=1
    }
    private func continueDefense() async throws {
        guard let p=puzzle else{return}
        if state.turn != (p.white ? "white":"black"),state.result==nil,state.moves.count<p.plies {
            try await refreshGuide()
            guard let move=(guide["line"] as? [String])?.first else{throw failure("Missing certified defense")}
            try await advance(move)
        }
        if coach.session?.recorded != true,state.moves.count<p.plies,state.result==nil {try await refreshGuide()}
    }
    private func advance(_ move:String,prepared:[String:Any]?=nil) async throws {
        guard let p=puzzle else{throw failure("Missing active puzzle")}
        let history=state.moves+[move]
        let next: [String:Any]
        if let prepared {next=prepared} else {next=try await NativeChess.call(p.request(moves:history))}
        // Persist before animation: a termination can never lose a verified move.
        coach.session?.moves=history;try await save();guide=[:];apply(next,animated:prepared==nil);if prepared==nil {feedback()}
        if next["solved"] as? Bool==true {
            if let tags=next["tags"] as? [String] {coach.session?.puzzle.tags=tags}
            try await complete()
        }
        // A verified preview has already landed while its proof was running.
        // Only an actual new animation (the defense) needs this settling window.
        else if prepared==nil {try await wait(world.moveAnimationDuration+0.10)}
    }
    private func complete() async throws {
        pauseClock();finishing=true;phase="celebrating";guide=[:]
        if let s=coach.session,[ChallengeKind.tactics,.personal,.opening].contains(s.puzzle.kind),!s.moves.isEmpty {
            let count=min(6,s.moves.count)
            lesson=Lesson(puzzle:s.puzzle,history:Array(s.moves.dropLast(count)),line:Array(s.moves.suffix(count)));hasReplay=true
        }
        evaluationActivity=nil
        let previousScore=liveScore
        let newlyFinished=coach.finish()
        try await save()
        if newlyFinished {scoreChanged(from:previousScore)}
        // Use the celebration window with the UPDATED coach. Fast solvers still
        // give the next puzzle useful preparation time between boards.
        schedulePreparation(nextOnly:true)
        if state.check,state.legal.isEmpty {world.checkmateKing(white:state.turn=="white")}
        try await wait(world.moveAnimationDuration)
        world.celebration.play(in:world);revision+=1
        try await wait(world.reducedMotion ? 0.2:0.65)
        #if DEBUG
        if testing,ProcessInfo.processInfo.arguments.contains("--hold-completion") {phase="won";return}
        #endif
        try await cloudJourney()
    }
    private func canPickUp(_ square:String)->Bool {
        challengeKind != .whosWinning && !replayActive && !busy && !moveQueued && !overlay && !showInfo && !showReturn && foreground && promotion.isEmpty && connected && phase=="playing" && state.result==nil && state.turn==(solverWhite ? "white":"black") && world.symbols[square]?.isUppercase==solverWhite
    }
    private func beginDrag(_ square:String)->Bool {
        guard canPickUp(square) else{return false};stopPreparation(keepingTurn:true,source:square);selected=square
        world.mark(selected:square,legal:state.legal.filter{$0.hasPrefix(square)},last:state.lastMove)
        if sound {UIImpactFeedbackGenerator(style:.soft).impactOccurred(intensity:0.45)};return true
    }
    private func canDrop(from:String,to:String)->Bool {canPickUp(from) && state.legal.contains(where:{$0.hasPrefix(from+to)})}
    private func drop(from:String,to:String)->Bool {
        guard selected==from,canDrop(from:from,to:to) else{return false}
        let moves=state.legal.filter{$0.hasPrefix(from+to)}
        if moves.count>1 {promotion=moves;pauseClock();return false}
        guard let move=moves.first else{return false};queue(move);return true
    }
    private func queue(_ move:String) {moveQueued=true;Task{defer{moveQueued=false};await play(move)}}
    func choose(_ square:String) {
        guard challengeKind != .whosWinning,!replayActive,!busy,!moveQueued,!overlay,!showInfo,!showReturn,foreground,promotion.isEmpty,connected,phase=="playing",state.turn==(solverWhite ? "white":"black"),dimensions.position(square) != nil else{return}
        if let from=selected {
            let candidates=state.legal.filter{$0.hasPrefix(from+square)}
            if candidates.count>1 {promotion=candidates;pauseClock();return}
            if let move=candidates.first {queue(move);return}
        }
        if canPickUp(square) {selected=selected==square ? nil:square;if sound{UISelectionFeedbackGenerator().selectionChanged()}} else{return}
        world.mark(selected:selected,legal:state.legal.filter{$0.hasPrefix(selected ?? "--")},last:state.lastMove)
    }
    func play(_ move:String) async {
        guard challengeKind != .whosWinning,!replayActive,!busy,!showInfo,!showReturn,foreground,connected,phase=="playing",state.turn==(solverWhite ? "white":"black"),state.result==nil,state.legal.contains(move),let p=puzzle else{return}
        stopPreparation(keepingTurn:true,move:move);pauseClock();busy=true;promotion=[];error=nil;evaluationActivity="Checking move";defer{pendingMove=nil;evaluationActivity=nil;busy=false;resumeClock()}
        do {
            if p.kind != .tactics {try await playOpen(move);return}
            // Render the legal drop before any objective search. The pending
            // preview never changes the saved attempt until it is proven.
            let previewStarted=ProcessInfo.processInfo.systemUptime
            let preview=try await previewMove(move)
            var request=p.request("judge",moves:state.moves)
            request["candidate"]=move;request["budget"]=1_000_000
            let judgement=try await NativeChess.call(request)
            try await finishLanding(since:previewStarted)
            guard let accepted=judgement["accepted"] as? Bool else{throw failure("Move could not be proven; attempt not graded")}
            if !accepted {
                if try await registerMistake(at:String(move.dropFirst(2).prefix(2))) {return}
                phase="retry";try await wait(world.reducedMotion ? 0.12:0.35)
                world.display(state.fen,dimensions:dimensions);selected=nil;revision+=1;phase="playing";return
            }
            try await advance(move,prepared:preview)
            // complete() replaces the session. Never make an old puzzle's reply
            // on the freshly arrived position.
            if puzzle?.id==p.id,coach.session?.recorded != true {try await continueDefense()}
        } catch {world.display(state.fen,dimensions:dimensions);handle(error)}
    }
    func newGame() async {
        guard !busy else{return};stopPreparation();pauseClock();busy=true;defer{busy=false;resumeClock()}
        do {
            let previousScore=liveScore
            if coach.session?.recorded==false {coach.session?.extraPenalty=(coach.session?.extraPenalty ?? 0)+0.5}
            coach.finish(skipped:true)
            try await save();scoreChanged(from:previousScore)
            if liveScore != previousScore {try await wait(0.7)}
            try await cloudJourney()
        }catch{handle(error)}
    }
    func undo() async {
        guard canUndo,let p=puzzle,var attempt=coach.session else{return}
        stopPreparation();pauseClock();busy=true;evaluationActivity="Checking restored position";defer{evaluationActivity=nil;busy=false;resumeClock()}
        do {
            guard attempt.undoLastDecision() else{return}
            // Prepare a legal rewind before charging its reward reduction.
            let response:[String:Any]
            var assessment:EngineAssessment?
            if p.kind == .tactics {response=try await NativeChess.call(p.request("guide",moves:attempt.moves))}
            else {
                response=try await ChallengeEngine.state(p,moves:attempt.moves)
                assessment=try await ChallengeEngine.evaluate(initial:p.fen,moves:attempt.moves).1
                attempt.evaluation=assessment?.forSolver(turn:p.white ? "white":"black",white:p.white)
            }
            _ = try JSONDecoder().decode(PositionState.self,from:JSONSerialization.data(withJSONObject:response))
            coach.session=attempt;try await save();apply(response)
            openAssessment=assessment
            if let assessment {guide=["line":assessment.line]} else {guide=response}
            challengeNotice=nil;promotion=[];phase="playing";connected=true;error=nil;revision+=1
        }catch{handle(error)}
    }
    func hint() async {
        guard canHint,let p=puzzle else{return}
        showHint=false;stopPreparation();pauseClock();busy=true;evaluationActivity="Finding a hint"
        defer {evaluationActivity=nil;busy=false;resumeClock()}
        do {
            if p.kind == .tactics {
                if guide["winning"]==nil {try await refreshGuide()}
            } else if openAssessment==nil {try await refreshOpenEvaluation()}
            let line=guide["line"] as? [String] ?? []
            guard let move=line.first,state.legal.contains(move),foreground,!showReturn else{return}
            let stage=nextHintStage
            let frames = stage==3 ? try await frames(for:Lesson(puzzle:p,history:state.moves,line:Array(line.prefix(3)))):[]
            guard foreground,!showReturn else{return}
            var session=coach.session!;session.revealHint()
            // Save before displaying assistance; failure never grants an uncharged hint.
            let previous=coach.session;coach.session=session
            do {try await save()} catch {coach.session=previous;throw error}
            if stage==1 {selected=nil;world.hintRegion(around:String(move.prefix(2)))}
            else if stage==2 {selected=String(move.prefix(2));world.mark(selected:selected,legal:[],last:nil)}
            else {beginReplay(frames,puzzle:p)}
            revision+=1
        } catch {handle(error)}
    }
    private func enterBoard() {
        if journeyEntered {journeyEntered=false;return}
        if showInfo {world.settleForInstructions()} else {world.puzzleEntrance()}
    }
    private func frames(for lesson:Lesson) async throws->[ReplayFrame] {
        var result:[ReplayFrame]=[],history=lesson.history
        for move in [String?](arrayLiteral:nil)+lesson.line.prefix(6).map({Optional($0)}) {
            try Task.checkCancellation()
            if let move {history.append(move)}
            let response = lesson.puzzle.kind == .tactics ? try await NativeChess.call(lesson.puzzle.request(moves:history)):try await ChallengeEngine.state(lesson.puzzle,moves:history)
            guard let fen=response["fen"] as? String else{throw failure("Replay unavailable")}
            result.append(ReplayFrame(fen:fen,move:move))
        }
        return result
    }
    func watchReplay() async {
        guard hasReplay,let lesson,!busy,!replayLoading,!replayActive,!showInfo,!showReturn,foreground,phase=="playing" || phase=="failed" || phase=="won" else{return}
        stopPreparation();pauseClock();replayLoading=true;busy=true
        let token=UUID();replayToken=token
        defer {replayLoading=false;busy=false;resumeClock()}
        // State replay is rules-only: never start an engine search to open a lesson.
        do {
            let prepared=try await frames(for:lesson)
            guard replayToken==token,foreground,!showReturn else{return}
            beginReplay(prepared,puzzle:lesson.puzzle)
        } catch {if replayToken==token {hasReplay=false}}
    }
    private func beginReplay(_ frames:[ReplayFrame],puzzle:TrainingPuzzle) {
        guard !frames.isEmpty else{return}
        world.onCancelDrag?();world.moveQuality.clear();selected=nil
        replayFrames=frames;replayCount=frames.count;replayIndex=0;replayActive=true
        world.additionalBottomClearance=0
        world.orient(whiteAtBottom:puzzle.white)
        world.display(frames[0].fen,dimensions:BoardDimensions(columns:puzzle.columns,rows:puzzle.rows))
        world.settleForInstructions();revision+=1
        if !world.reducedMotion {toggleReplay()}
    }
    func toggleReplay() {
        guard replayActive else{return}
        replayTask?.cancel();replayPlaying.toggle()
        guard replayPlaying else{return}
        if replayIndex>=replayCount-1 {renderReplay(0,animated:false)}
        let token=replayToken
        replayTask=Task { [weak self] in
            do {
                while let self,self.replayActive,self.replayPlaying,self.replayToken==token,self.replayIndex<self.replayCount-1 {
                    try await Task.sleep(for:.seconds(1.6));try Task.checkCancellation()
                    self.renderReplay(self.replayIndex+1,animated:true)
                }
                guard let self,self.replayToken==token else{return};self.replayPlaying=false
            } catch {}
        }
    }
    func stepReplay(_ delta:Int) {
        guard replayActive else{return};replayTask?.cancel();replayPlaying=false
        renderReplay(replayIndex+delta,animated:delta==1)
    }
    private func renderReplay(_ index:Int,animated:Bool) {
        replayIndex=min(max(0,index),replayFrames.count-1)
        let frame=replayFrames[replayIndex]
        world.display(frame.fen,move:animated ? frame.move:nil);revision+=1
        if UIAccessibility.isVoiceOverRunning,let move=frame.move {UIAccessibility.post(notification:.announcement,argument:"Replay move \(move)")}
    }
    func closeReplay() {
        replayToken=UUID();replayTask?.cancel();replayTask=nil;replayPlaying=false
        guard replayActive else{return}
        replayActive=false;replayFrames=[];replayCount=0;replayIndex=0
        world.additionalBottomClearance=puzzle?.kind == .whosWinning ? 140:(puzzle?.kind == .tenMoves ? 85:0)
        world.orient(whiteAtBottom:solverWhite);world.display(state.fen,dimensions:dimensions)
        world.settleForInstructions();revision+=1;resumeClock()
    }
    private func introduce() {
        requiredInstructionType=nil;excludedPuzzleID=nil
        if !foreground {showReturn=true}
        guard !showReturn else{return}
        let key="type-v2:"+instructionType
        if !(coach.introductions ?? []).contains(key) {
            pauseClock();firstTypeIntroduction=true
            boardRevealed=true;showInfo=true;world.settleForInstructions()
        } else {boardRevealed=true}
        checkpoint()
    }
    func requestInstructions() {
        guard !busy,puzzle != nil else{return}
        stopPreparation();pauseClock();world.onCancelDrag?();world.moveQuality.clear();firstTypeIntroduction=false;boardRevealed=true;showInfo=true;world.settleForInstructions()
    }
    func acknowledgeInstructions() async {
        guard !busy else{return}
        coach.introductions=(coach.introductions ?? []).union(["type-v2:"+instructionType])
        showInfo=false;checkpoint();boardRevealed=true;resumeClock()
    }
    func continueAfterReturn() async {
        guard !busy else{return}
        showReturn=false;await replaceCurrentPuzzle()
    }
    private func replaceCurrentPuzzle(instructionType:String?=nil) async {
        pauseClock();busy=true;defer{busy=false;resumeClock()}
        requiredInstructionType=instructionType;excludedPuzzleID=puzzle?.id
        // Reading instructions or returning is not evidence of chess weakness.
        var score=coach.scoring ?? ChallengeScore();score.total=liveScore
        if let session=coach.session {score.completed.insert(session.id)}
        coach.scoring=score;coach.challengeMode=challengeKind;coach.session=nil
        do {try await save();try await cloudJourney()}catch{handle(error)}
    }
    private func nextOpenChallenge(_ kind:ChallengeKind) async throws {
        let p:TrainingPuzzle
        var preparedAssessment:EngineAssessment?
        #if DEBUG
        if testing,kind != .whosWinning,kind != .blunderPunish,let fixture=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--challenge-fixture=")}) {
            var q=bank[0];q.columns=8;q.rows=8;q.id=fixture+"-\(coach.total)";q.source="test";q.challengeType=kind.rawValue;q.difficultyVersion="open-play-v1";q.mate=0;q.plies=kind == .tenMoves ? ImprovementChallenge.plies:1
            q.fen=fixture.hasSuffix("black") ? "8/8/8/8/8/5kq1/8/7K b - - 0 1":"7k/8/5KQ1/8/8/8/8/8 w - - 0 1"
            if fixture.hasSuffix("middlegame") {q.fen="r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P4/2PBPN2/PP1N1PPP/R1BQ1RK1 w - - 2 8"}
            if kind == .opening {
                q.fen=fixture.hasSuffix("black") ? "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
                if fixture.hasSuffix("blunder") {q.fen="rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"}
                q.plies=5;q.source="Opening drill";q.tags=["opening"]
            }
            q.initialEvaluation=kind == .tenMoves || kind == .opening ? 0:99999
            coach.begin(q);try await save()
            let response=try await ChallengeEngine.state(q,moves:[]);await prepareScene(response);apply(response);connected=true;error=nil
            try await refreshOpenEvaluation();try await finishGeneration();enterBoard();phase="playing";introduce();return
        }
        #endif
        if let ready=takePrepared(kind) {p=ready.puzzle;preparedAssessment=ready.assessment}
        else if kind == .personal {
            let defaults=testing ? UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!:UserDefaults.standard
            guard let job=defaults.string(forKey:"cloudchess.profileJob") else {
                challengeNotice="Connect your profile to create drills from your games.";phase="waiting";isGenerating=false;world.island.opacity=0;connected=true;return
            }
            guard let candidate=try await OnDeviceProfiles.shared.selectDrill(jobID:job,learner:coach,excluding:excludedPuzzleID) else {
                challengeNotice="Your game analysis is still collecting missed opportunities. Open your profile to check progress.";phase="waiting";isGenerating=false;world.island.opacity=0;connected=true;return
            }
            p=candidate.difficultyVersion==ModeDifficulty.version ? candidate:try await ChallengeEngine.calibrated(candidate)
        } else if kind == .whosWinning {
            p=try await JudgmentLibrary.shared.generate(rating:coach.targetRating(for:kind),draw:coach.judgmentDraws ?? 0,seed:coach.nextRandom(),excluding:Set(coach.seen),avoiding:coach.blockedPuzzleKeys)
        } else if kind == .blunderPunish {
            var seed=coach.nextRandom()
            #if DEBUG
            if testing,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--blunder-seed=")}),let fixed=UInt64(arg.dropFirst(15)) {seed=fixed}
            #endif
            p=try await BlunderEngine.generate(rating:coach.targetRating(for:kind),seed:seed,opponent:coach.opponentRating(for:kind),excluding:Set(coach.seen),avoiding:coach.blockedPuzzleKeys)
        } else if kind == .opening {
            p=try await OpeningLibrary.shared.generate(rating:coach.targetRating(for:.opening),seed:coach.nextRandom(),excluding:Set(coach.seen),avoiding:coach.blockedPuzzleKeys,skills:coach.skills,progress:{ [weak self] step in await self?.generationProgress(step) })
        } else {
            p=try await ChallengeEngine.generated(kind,rating:coach.targetRating(for:kind),seed:coach.nextRandom(),opponentElo:coach.opponentRating(for:kind),learner:coach.challengeLevel(kind),targetSuccess:coach.target(for:kind),opponentBounds:coach.opponentBounds(for:kind),excluding:Set(coach.seen),avoiding:coach.blockedPuzzleKeys,progress:{ [weak self] step in await self?.generationProgress(step) })
        }
        guard coach.allowsNextPuzzle(p) else{throw failure("No fresh puzzle available. Try again.")}
        await generationProgress(8)
        coach.begin(p);try await save()
        if p.kind == .whosWinning {try await displayJudgment()} else {
            let response=try await ChallengeEngine.state(p,moves:[]);await prepareScene(response);apply(response)
        }
        connected=true;error=nil;challengeNotice=nil
        if p.kind != .whosWinning {if let preparedAssessment {installAssessment(preparedAssessment)} else {try await refreshOpenEvaluation()}};await generationProgress(9);try await finishGeneration();phase="playing";introduce();enterBoard();try await wait(0.02)
    }
    private func installAssessment(_ e:EngineAssessment) {
        guard let p=puzzle else{return}
        openAssessment=e;coach.session?.evaluation=e.forSolver(turn:state.turn,white:p.white)
        guide=["line":e.line];revision+=1
        // The live baseline is recoverable. Persist it with the next move or
        // lifecycle checkpoint, not a full history rewrite while input is active.
    }
    private func refreshOpenEvaluation() async throws {
        guard let p=puzzle else{return}
        if !isGenerating {evaluationActivity="Updating position evaluation"}
        let (_,e)=try await ChallengeEngine.evaluate(initial:p.fen,moves:state.moves,multipv:state.moves.isEmpty ? 3:1)
        installAssessment(e)
    }
    private func resumeOpenChallenge() async throws {
        guard let p=puzzle else{return}
        if p.kind == .whosWinning {try await displayJudgment();phase="playing";introduce();return}
        if state.result != nil {try await finishOpenIfNeeded();return}
        if p.kind == .tenMoves,ImprovementChallenge.isComplete(plies:state.moves.count) {
            try await refreshOpenEvaluation();_ = try await finishOpenIfNeeded();return
        }
        if (p.kind == .personal || p.kind == .opening),(state.moves.count+1)/2>=p.solverMoves {
            try await refreshOpenEvaluation();_ = try await finishOpenIfNeeded();return
        }
        if state.turn != (p.white ? "white":"black") {
            if p.kind == .blunderPunish,let move=state.moves.last {
                let history=Array(state.moves.dropLast())
                let decision=try await TurnAnalysis.assess(p.kind,initial:p.fen,history:history,move:move)
                try await continueBlunder(move:move,history:history,decision:decision)
                guard puzzle?.id==p.id,coach.session?.recorded != true else{return}
            } else {try await openDefense()}
        }
        if coach.session?.recorded != true {try await refreshOpenEvaluation();if try await finishOpenIfNeeded(){return};phase="playing";introduce()}
    }
    private func previewMove(_ move:String) async throws->[String:Any] {
        guard let p=puzzle else{throw failure("Missing puzzle")}
        let next: [String:Any]
        if p.kind == .tactics {next=try await NativeChess.call(p.request(moves:state.moves+[move]))}
        else {next=try await ChallengeEngine.state(p,moves:state.moves+[move])}
        guard let fen=next["fen"] as? String else{throw failure("Move position unavailable")}
        selected=nil;pendingMove=move;world.display(fen,move:move,dimensions:dimensions);feedback();revision+=1
        // Analysis starts after placement and runs DURING the landing animation.
        // The caller waits only its unelapsed remainder before showing a verdict.
        return next
    }
    private func finishLanding(since started:TimeInterval) async throws {
        let duration=world.reducedMotion ? 0.08:world.moveAnimationDuration
        let remaining=duration-(ProcessInfo.processInfo.systemUptime-started)
        if remaining>0 {try await wait(remaining)}
    }
    private func openAdvance(_ move:String,waitForAnimation:Bool=true) async throws {
        guard let p=puzzle else{return}
        let history=state.moves+[move],next=try await ChallengeEngine.state(p,moves:history)
        coach.session?.moves=history;try await save();apply(next,animated:true);feedback()
        if waitForAnimation {try await wait(world.moveAnimationDuration+0.1)}
    }
    private func openDefense(analyzedReply:String?=nil,preparedReply:TurnAnalysis.PreparedReply?=nil) async throws {
        guard let p=puzzle,state.result==nil else{return}
        if !isGenerating {evaluationActivity="Opponent is thinking"}
        let move:String
        if (p.kind == .tenMoves || p.kind == .finish),let preparedReply,
           preparedReply.matches(initial:p.fen,history:state.moves,elo:coach.session?.opponentElo ?? coach.ability.mean,legal:state.legal) {
            move=preparedReply.move;preparedReplyUsed+=1
        } else if let analyzedReply,(p.kind == .personal || p.kind == .opening),state.legal.contains(analyzedReply) {
            move=analyzedReply
        } else if p.kind == .personal || p.kind == .opening {
            let (_,best)=try await ChallengeEngine.evaluate(initial:p.fen,moves:state.moves)
            guard let fallback=best.line.first else{return}
            // Restored sessions or a truncated PV need one fresh strong search.
            // Do not add another root search just to randomize a book reply.
            move=fallback
        } else {move=try await ChallengeEngine.opponent(initial:p.fen,moves:state.moves,elo:coach.session?.opponentElo ?? coach.ability.mean)}
        try await openAdvance(move)
    }
    @discardableResult private func finishOpenIfNeeded() async throws->Bool {
        guard let p=puzzle else{return false}
        let won=state.result == (p.white ? "White wins":"Black wins")
        let playerMoves=(state.moves.count+1)/2
        let limitReached=p.kind == .tenMoves ? ImprovementChallenge.isComplete(plies:state.moves.count) : (p.kind == .personal || p.kind == .opening) && playerMoves>=p.solverMoves
        guard state.result != nil || limitReached else{return false}
        let success=won || (state.result==nil && (p.kind == .personal || p.kind == .opening || (p.kind == .tenMoves && (coach.session?.evaluation ?? -100000)>(p.initialEvaluation ?? 0))))
        if success {try await complete()}
        else {
            pauseClock();evaluationActivity=nil
            let previousScore=liveScore,unrecorded=coach.session?.recorded==false
            if unrecorded {coach.session?.extraPenalty=(coach.session?.extraPenalty ?? 0)+2}
            coach.finish(skipped:true);try await save()
            if unrecorded {mistakeFeedback(at:String(state.lastMove?.suffix(2) ?? "a1"),scoreBefore:previousScore)}
            phase="failed";finishing=false;challengeNotice=state.result=="Draw" ? "Draw. Try again?":"Try again?";revision+=1
        }
        return true
    }
    private func displayJudgment() async throws {
        guard let j=puzzle?.judgment else{throw failure("Missing judgment evidence")}
        var response=try await NativeChess.call(["action":"state","initial":j.initial,"moves":j.history])
        response["moves"]=[];response["san"]=[];response["lastMove"]=NSNull()
        await prepareScene(response);apply(response);guide=[:]
    }
    func answerJudgment(_ answer:JudgmentVerdict) async {
        guard challengeKind == .whosWinning,let truth=puzzle?.judgment?.verdict,!busy,phase=="playing",!showInfo,!showReturn,foreground else{return}
        stopPreparation();pauseClock();busy=true;defer{busy=false;resumeClock()}
        do {
            if answer==truth {try await complete()}
            else {_ = try await registerMistake(at:"e4")}
        }catch{handle(error)}
    }
    private func failBlunder() async throws {
        guard coach.session?.recorded==false else{return}
        let score=liveScore;coach.session?.extraPenalty=(coach.session?.extraPenalty ?? 0)+2
        coach.finish(skipped:true);try await save();phase="failed";evaluationActivity=nil
        mistakeFeedback(at:String(state.lastMove?.suffix(2) ?? "e4"),scoreBefore:score)
        try await wait(world.reducedMotion ? 0.2:0.9)
        try await cloudJourney()
    }
    private func continueBlunder(move:String,history:[String],decision:TurnAnalysis.Decision) async throws {
        guard let p=puzzle else{return}
        if state.result != nil {
            if state.result==(p.white ? "White wins":"Black wins") {try await complete()} else {try await failBlunder()};return
        }
        if let injected=coach.session?.blunderPly {
            var cp=decision.played.cp
            if !BlunderEngine.retained(cp) {cp=try await ChallengeEngine.evaluate(initial:p.fen,moves:history,root:move,budget:8_000_000).1.cp}
            guard BlunderEngine.retained(cp) else{try await failBlunder();return}
            if decision.loss>=75 {let score=liveScore;_ = coach.mistakenMove();mistakeFeedback(at:String(move.suffix(2)),scoreBefore:score)}
            coach.session?.evaluation=cp;try await save()
            if (state.moves.count-injected+1)/2>=3 {try await complete();return}
            try await openDefense()
            if state.result != nil {if state.result==(p.white ? "White wins":"Black wins") {try await complete()} else {try await failBlunder()}}
            return
        }
        // A large learner blunder ends the balanced setup fairly; never pretend
        // an already lost position is the opponent's scheduled mistake.
        if decision.played.cp < -150 {
            let verified=try await ChallengeEngine.evaluate(initial:p.fen,moves:history,root:move,budget:8_000_000).1
            if verified.cp < -150 {try await failBlunder();return}
        }
        if decision.loss>=75 {let score=liveScore;_ = coach.mistakenMove();mistakeFeedback(at:String(move.suffix(2)),scoreBefore:score);try await save()}
        let turn=(state.moves.count+1)/2,target=BlunderEngine.targetTurn(seed:p.blunderSeed ?? 0)
        if turn>=target {
            evaluationActivity="Preparing opponent move"
            if let opportunity=try await BlunderEngine.find(initial:p.fen,moves:state.moves,seed:p.blunderSeed ?? 0) {
                coach.session?.blunderPly=state.moves.count+1
                coach.session?.evaluation=opportunity.advantage
                try await openAdvance(opportunity.move);return
            }
            if turn>=3 {
                // Some legal player deviations leave only forced replies. Replace
                // that unplayable setup without any penalty or fabricated blunder.
                var score=coach.scoring ?? ChallengeScore();if let session=coach.session {score.completed.insert(session.id)}
                coach.scoring=score;excludedPuzzleID=p.id;coach.session=nil;requiredInstructionType=ChallengeKind.blunderPunish.rawValue
                try await save();try await cloudJourney();return
            }
        }
        // Stay on the sound equal-position line until the scheduled mistake.
        if let reply=TurnAnalysis.reply(move:move,assessment:decision.played,legal:state.legal) {try await openAdvance(reply)}
        else {let e=try await ChallengeEngine.evaluate(initial:p.fen,moves:state.moves).1;if let reply=e.line.first {try await openAdvance(reply)}}
    }
    private func playOpen(_ move:String) async throws {
        guard let p=puzzle else{return}
        let history=state.moves,cached=openAssessment,beforeFEN=state.fen
        let prepared=preparedTurnKey==turnKey(p,history) ? preparedTurn[move]:nil
        let preparedReply=preparedTurnKey==turnKey(p,history) ? preparedReplies.removeValue(forKey:move):nil
        preparedReplies.removeAll()
        let started=ProcessInfo.processInfo.systemUptime
        defer {lastTurnMilliseconds=Int((ProcessInfo.processInfo.systemUptime-started)*1000)}
        var pending:[String:Any]?
        if p.kind.usesHearts {pending=try await previewMove(move)}
        else {
            // Publish the placement and start the local badge before any search.
            // Strong grading overlaps the existing landing animation.
            try await openAdvance(move,waitForAnimation:false)
            showMoveQuality(prepared?.quality,move:move)
        }
        #if DEBUG
        if testing,ProcessInfo.processInfo.arguments.contains("--evaluation-audit") {try await wait(8)}
        #endif
        if prepared != nil || move==cached?.line.first || ChallengeEngine.cached(initial:p.fen,moves:history,root:move) != nil {preparedMoveUsed+=1}
        let decision:TurnAnalysis.Decision
        if let prepared {decision=prepared.decision}
        else {decision=try await TurnAnalysis.assess(p.kind,initial:p.fen,history:history,move:move,baseline:cached)}
        if p.kind.usesHearts {try await finishLanding(since:started)}
        if !p.kind.usesHearts {
            if prepared?.quality==nil {
                let book=try? await OpeningLibrary.shared.continuations(fen:beforeFEN)
                let quality=try await MoveQualityJudge.grade(initial:p.fen,history:history,move:move,beforeFEN:beforeFEN,decision:decision,elo:coach.modeAbility(p.kind),book:book?[move] != nil)
                showMoveQuality(quality,move:move)
            }
            // Never animate the opponent over a piece that is still landing.
            let remaining=world.moveAnimationDuration+0.1-(ProcessInfo.processInfo.systemUptime-started)
            if remaining>0 {try await wait(remaining)}
        }
        let best=decision.best,played=decision.played
        if decision.loss>=100,played.line.first==move,played.line.count>=2 {
            lesson=Lesson(puzzle:p,history:history,line:Array(played.line.prefix(6)));hasReplay=true
        }
        if p.kind == .blunderPunish {try await continueBlunder(move:move,history:history,decision:decision);return}
        if p.kind == .opening || p.kind == .personal {
            if decision.rejected {
                if try await registerMistake(at:String(move.dropFirst(2).prefix(2))) {return}
                try await wait(world.reducedMotion ? 0.12:0.35);world.display(state.fen,dimensions:dimensions);selected=nil;revision+=1;return
            }
        } else {
            if best.cp-played.cp>=75 {
                let previousScore=liveScore
                _ = coach.mistakenMove();mistakeFeedback(at:String(move.dropFirst(2).prefix(2)),scoreBefore:previousScore)
            }
        }
        try await save()
        if let pending {coach.session?.moves=history+[move];try await save();apply(pending)}
        // Judge six-move play after the opponent's sixth reply; a terminal result
        // is judged immediately. Personal drills end at their final solver move.
        if state.result != nil || ((p.kind == .personal || p.kind == .opening) && (state.moves.count+1)/2>=p.solverMoves) {
            _ = try await finishOpenIfNeeded();return
        }
        let reply=TurnAnalysis.reply(move:move,assessment:played,legal:state.legal)
        try await openDefense(analyzedReply:reply,preparedReply:preparedReply)
        // Only a terminal objective needs the evaluation before play continues.
        // Otherwise unlock input immediately; resumeClock prioritizes the exact
        // current baseline and publishes it without holding the board busy.
        if p.kind == .tenMoves,state.result==nil,ImprovementChallenge.isComplete(plies:state.moves.count) {try await refreshOpenEvaluation()}
        _ = try await finishOpenIfNeeded()
    }
    @discardableResult private func registerMistake(at square:String) async throws->Bool {
        evaluationActivity=nil
        let previousScore=liveScore,failed=coach.mistakenMove()
        if failed {
            // The final strike replaces its quarter-value charge with the
            // existing two-value failure charge. Never reset the banked total.
            coach.session?.extraPenalty=(coach.session?.extraPenalty ?? 0)+1.75
            coach.finish(skipped:true);try await save();phase="failed"
            mistakeFeedback(at:square,scoreBefore:previousScore)
            try await wait(0.9)
            try await cloudJourney();return true
        }
        try await save();mistakeFeedback(at:square,scoreBefore:previousScore);return false
    }
    func feedback(){if sound{UIImpactFeedbackGenerator(style:.soft).impactOccurred(intensity:0.6);AudioServicesPlaySystemSound(1104)}}
    private func handle(_ failure:Error){stopPreparation(clear:true);journeyWatchdog?.cancel();journeyStarted=nil;journeyReveal=nil;journeyFallback=false;journeyEntered=false;closeReplay();world.moveQuality.clear();evaluationActivity=nil;isGenerating=false;pauseClock();error=failure.localizedDescription;connected=false;phase="error";finishing=false;revision+=1}
}

#if DEBUG
/// Measures main-run-loop delivery during loading AND play. Unlike the SceneKit
/// audit this includes covered frames; it is not a GPU or touch latency metric.
private final class MainThreadPulseAudit:NSObject {
    private var link:CADisplayLink?
    private var previous:Double?
    private var samples:[(String,Double)]=[]
    private let stage:()->String
    init(stage:@escaping ()->String) {
        self.stage=stage;super.init()
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {try? FileManager.default.removeItem(at:root.appendingPathComponent("main-thread-pulse.json"))}
        link=CADisplayLink(target:self,selector:#selector(tick))
        link?.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:60,preferred:60)
        link?.add(to:.main,forMode:.common)
    }
    @objc private func tick() {
        let now=CACurrentMediaTime();defer{previous=now}
        guard let previous else{return}
        samples.append((stage(),now-previous))
        guard samples.count>=900 else{return}
        link?.invalidate();link=nil
        var report:[String:Any]=["recordedAt":ISO8601DateFormatter().string(from:Date()),"scope":"Main-run-loop display-link delivery, including loading; simulator timings, not GPU duration", "samples":samples.count]
        for key in Set(samples.map(\.0)) {
            let times=samples.filter{$0.0==key}.map{$0.1*1000}.sorted()
            report[key]=["samples":times.count,"maxMs":times.last!,"p95Ms":times[Int(Double(times.count-1)*0.95)],"over100ms":times.filter{$0>100}.count]
        }
        guard let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        DispatchQueue.global(qos:.utility).async {try? data.write(to:root.appendingPathComponent("main-thread-pulse.json"),options:.atomic)}
    }
}
#endif
