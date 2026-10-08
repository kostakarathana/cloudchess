import SwiftUI
import SceneKit

@main struct CloudChessApp:App {
    var body:some Scene {WindowGroup {CloudChessView().preferredColorScheme(.light)}}
}

/// Challenge instructions are the only prose in the play scene.
struct CloudChessView:View {
    @StateObject private var game=GameModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings=false
    @State private var showingProfile=false
    @State private var showingLegal=false
    @State private var scoreEmphasis=false
    @State private var displayedScoreEvent=0
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private var modalVisible:Bool {settings || showingProfile || showingLegal || game.showInfo || game.showReturn || game.showSkip || game.showUndo || game.showHint || !game.promotion.isEmpty || game.phase=="error"}
    private var sceneryPaused:Bool {modalVisible}
    var body:some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                CloudAtmosphere(motion:!game.isGenerating && game.motion && !reduceMotion && !game.presentingReward && !sceneryPaused,field:game.world.cloudField).ignoresSafeArea()
                ChessSceneView(world:game.world,revision:game.revision,concealed:!game.boardRevealed || game.showReturn || game.presentingReward,paused:sceneryPaused,inputBlocked:modalVisible || game.replayActive || game.journeyActive)
                    .ignoresSafeArea().opacity(game.boardRevealed && !game.showReturn && !game.presentingReward ? 1:0)
                    .accessibilityHidden(modalVisible || !game.boardRevealed || game.showInfo || game.showReturn || game.replayActive || game.journeyActive || game.presentingReward).accessibilityIdentifier("chessboard")
                if !game.journeyActive && !game.replayActive {
                VStack(spacing:0) {
                    HStack {
                        Button {if game.coach.session?.recorded==true {Task{await game.newGame()}}else{game.showSkip=true}} label:{symbol("forward.end",size:18)}.accessibilityLabel(game.coach.session?.recorded==true ? "Next puzzle":"Skip puzzle").disabled(game.busy || game.puzzle==nil)
                        Spacer()
                        scoreDisplay
                        Spacer()
                        Button {withAnimation(reduceMotion || !game.motion ? nil:.spring(response:0.4,dampingFraction:0.8)){settings.toggle()}} label:{symbol(settings ? "xmark":"slider.horizontal.3",size:18)}.accessibilityLabel("Settings")
                    }.padding(.horizontal,27).padding(.top,18)
                    challengeCloud.padding(.top,12).padding(.horizontal,22)
                    Spacer(minLength:0)
                    
                    if let activity=game.evaluationActivity,!game.isGenerating,!game.showInfo,!game.showReturn {
                        EngineThinkingIndicator(activity:activity,reduced:reduceMotion || !game.motion)
                            .padding(.bottom,14).allowsHitTesting(false)
                    }
                    if game.challengeKind == .tenMoves,game.puzzle != nil,!game.showInfo,!game.showReturn,!game.presentingReward {
                        HorizontalEvaluationBar(pieceTheme:game.displayedPieces,centipawns:game.coach.session?.evaluation ?? 0,solverWhite:game.solverWhite,reducedMotion:reduceMotion || !game.motion,pending:game.evaluationPending)
                            .opacity(game.evaluationPending ? 0.35:1)
                            .accessibilityHidden(game.evaluationPending)
                            .frame(maxWidth:340).padding(.horizontal,24).padding(.bottom,16).allowsHitTesting(false)
                    }
                    if game.challengeKind == .whosWinning,game.puzzle != nil,!game.showInfo,!game.showReturn {
                        JudgmentControls(game:game).padding(.horizontal,22).padding(.bottom,12)
                    }
                    if game.challengeKind != .whosWinning || game.hasReplay {
                    HStack(spacing:0) {
                        if game.challengeKind != .whosWinning {
                        control("arrow.counterclockwise","Undo move",disabled:!game.canUndo){game.showUndo=true}
                        control("sparkles","Hint",disabled:!game.canHint){game.requestHint()}
                        }
                        if game.hasReplay {control("play.rectangle","Watch the key moment",disabled:game.busy){Task{await game.watchReplay()}}}
                    }.padding(.horizontal,12).padding(.vertical,4).background {CloudChromeSurface(puffiness:0.45)}.frame(width:(game.challengeKind == .whosWinning ? 24:144)+(game.hasReplay ? 58:0)).padding(.bottom,32)
                    }
                }.opacity(game.isGenerating || game.journeyActive || game.replayActive ? 0:1).allowsHitTesting(!modalVisible && !game.isGenerating && !game.journeyActive && !game.replayActive && !game.presentingReward).accessibilityHidden(modalVisible || game.isGenerating || game.journeyActive || game.replayActive || game.showInfo || game.showReturn || game.presentingReward)
                }
                if settings {settingsPanel.zIndex(5)}
                if !game.promotion.isEmpty {promotionPanel.zIndex(5)}
                if showingProfile {
                    ProfileAnalysisPanel(close:{showingProfile=false}).zIndex(5)
                }
                if showingLegal {CloudLegalPanel(close:{showingLegal=false}).zIndex(5)}
                if let started=game.journeyStarted {
                    CloudJourneyVeil(started:started,reveal:game.journeyReveal,reduced:reduceMotion || !game.motion,field:game.journeyClouds)
                        .ignoresSafeArea().allowsHitTesting(true).accessibilityHidden(true).zIndex(9)
                }
                if game.replayActive {replayControls.zIndex(8)}
                if game.showsGeneration {
                    PuzzleGenerationView(step:game.generationStep,reduced:reduceMotion || !game.motion).transition(.opacity).zIndex(11)
                }
                if game.phase=="error",!game.isGenerating {
                    CloudPopup(title:"Let’s try that again",symbol:"cloud.bolt",dismiss:nil) {
                        Text("Your puzzle couldn’t be completed. Try again to continue your session.").font(.body).foregroundStyle(ink.opacity(0.75))
                    } actions: {
                        Button {Task{await game.start()}} label:{Label("Try again",systemImage:"arrow.clockwise").frame(maxWidth:.infinity)}
                            .buttonStyle(CloudActionStyle()).disabled(game.busy).accessibilityLabel("Try generating again")
                    }.zIndex(12)
                }

                if game.showInfo || game.showReturn {
                    ChallengeIntermission(
                        returning:game.showReturn,
                        firstIntroduction:game.firstTypeIntroduction,
                        title:game.challengeTitle,
                        explanation:game.instructionExplanation,
                        score:game.liveScore,
                        rewardMultiplier:game.challengeKind.rewardMultiplier,
                        reducedMotion:reduceMotion || !game.motion,
                        busy:game.busy,
                        proceed:{Task{if game.showReturn {await game.continueAfterReturn()} else {await game.acknowledgeInstructions()}}}
                    ).transition(.opacity).zIndex(10)
                }
                if game.showSkip || game.showUndo || game.showHint {confirmationPanel.zIndex(15)}
                }.accessibilityHidden(game.presentingReward).allowsHitTesting(!game.presentingReward)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    Color.clear.frame(width:1,height:1).accessibilityElement().accessibilityLabel("Puzzle diagnostics").accessibilityIdentifier("puzzle-status").accessibilityValue(game.diagnostic)
                }
                #endif
            }.foregroundStyle(ink).buttonStyle(CloudPressStyle()).animation(.easeOut(duration:0.18),value:game.showsGeneration)
        }
        .environment(\.cloudMotion,game.motion)
        .statusBarHidden(true)
        .task{game.configureMotion(reduced:reduceMotion);await game.start()}
        // Switching between cards remains one overlay transaction and one save.
        .onChange(of:modalVisible || game.replayActive){_,_ in updateOverlay()}
        .onChange(of:scenePhase){_,phase in game.setActive(phase == .active);if phase == .background {settings=false;showingProfile=false;showingLegal=false;game.showSkip=false;game.showUndo=false;game.showHint=false;game.promotion=[];game.didEnterBackground()};if phase != .active {game.world.onCancelDrag?();Task{await OnDeviceProfiles.shared.pause()}}}
        .onChange(of:game.motion){_,_ in game.configureMotion(reduced:reduceMotion)}
        .onChange(of:reduceMotion){_,_ in game.configureMotion(reduced:reduceMotion)}
    }
    private func updateOverlay() {
        game.world.onCancelDrag?()
        game.setOverlay(modalVisible || game.replayActive)
    }
    private var replayControls:some View {
        VStack {
            HStack {Spacer();Button {game.closeReplay()} label:{symbol("xmark",size:18).padding(14).background(.regularMaterial,in:Circle())}
                .accessibilityLabel("Close replay").accessibilityIdentifier("close-replay")}.padding(24)
            Spacer()
            VStack(spacing:14) {
                HStack(spacing:7) {ForEach(0..<game.replayCount,id:\.self) {i in
                    Circle().fill(ink.opacity(i<=game.replayIndex ? 0.8:0.15)).frame(width:6,height:6)
                }}.accessibilityElement().accessibilityLabel("Replay progress").accessibilityValue("\(game.replayIndex) of \(max(0,game.replayCount-1)) moves")
                HStack(spacing:24) {
                    Button {game.stepReplay(-1)} label:{symbol("backward.end",size:20)}.disabled(game.replayIndex==0).accessibilityLabel("Previous replay move").accessibilityIdentifier("replay-back")
                    Button {game.toggleReplay()} label:{symbol(game.replayPlaying ? "pause.fill":"play.fill",size:22)}.accessibilityLabel(game.replayPlaying ? "Pause replay":"Play replay").accessibilityIdentifier("replay-play")
                    Button {game.stepReplay(1)} label:{symbol("forward.end",size:20)}.disabled(game.replayIndex>=game.replayCount-1).accessibilityLabel("Next replay move").accessibilityIdentifier("replay-next")
                }
            }.padding(.horizontal,28).padding(.vertical,18).background(.regularMaterial,in:RoundedRectangle(cornerRadius:28)).shadow(color:ink.opacity(0.10),radius:18,y:6).padding(.bottom,32)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("replay-controls")
    }
    private var scoreDisplay:some View {
        VStack(spacing:2) {
            Text(Int(game.liveScore).formatted()).lineLimit(1).minimumScaleFactor(0.65).font(.system(size:26,weight:.semibold,design:.rounded)).monospacedDigit()
                .foregroundStyle(scoreEmphasis ? (game.scoreDirection>0 ? Color(red:0.10,green:0.48,blue:0.31):Color(red:0.80,green:0.13,blue:0.22)):ink)
                .scaleEffect(scoreEmphasis && !reduceMotion && game.motion ? 1.34:1)
                .contentTransition(.numericText()).accessibilityIdentifier("live-score")
                .animation(reduceMotion || !game.motion ? nil:.spring(response:0.38,dampingFraction:0.65),value:game.liveScore)
                .onDisappear {scoreEmphasis=false}
                .task(id:game.scoreFeedbackID) {
                    guard game.scoreFeedbackID>displayedScoreEvent else{return}
                    displayedScoreEvent=game.scoreFeedbackID
                    withAnimation(.easeOut(duration:0.12)){scoreEmphasis=true}
                    do {try await Task.sleep(for:.seconds(0.95))} catch {return}
                    withAnimation(.easeOut(duration:0.3)){scoreEmphasis=false}
                }
            HStack(spacing:4) {Image(systemName:"crown.fill");Text(Int(game.coach.scoring?.best ?? 0).formatted()).monospacedDigit()}
                .font(.system(size:11,weight:.medium)).foregroundStyle(ink.opacity(0.6)).padding(.top,4)
                .accessibilityElement(children:.ignore).accessibilityLabel("All-time high")
                .accessibilityValue(Int(game.coach.scoring?.best ?? 0).formatted()).accessibilityIdentifier("all-time-high")
            if game.challengeKind.usesHearts {
                HStack(spacing:7) {ForEach(0..<3) {i in
                    Image(systemName:i<game.coach.remainingHearts ? "heart.fill":"heart")
                        .foregroundStyle(i<game.coach.remainingHearts ? Color(red:0.80,green:0.35,blue:0.40):ink.opacity(0.25))
                        .frame(width:22,height:22)
                }}.font(.system(size:18)).padding(.top,6)
                    .accessibilityElement(children:.ignore).accessibilityLabel("Puzzle attempts")
                    .accessibilityValue("\(game.coach.remainingHearts) of 3 remaining").accessibilityIdentifier("puzzle-hearts")
            }
        }.accessibilityElement(children:.contain)
    }

    private var challengeCloud:some View {
        VStack(spacing:10) {
            HStack(spacing:8) {
                Text(game.challengeTitle).font(.system(size:16,weight:.medium,design:.rounded)).multilineTextAlignment(.center)
                Button {game.requestInstructions()} label: {
                    Image(systemName:"info.circle").font(.system(size:17))
                        .frame(width:44,height:44)
                        // A custom button style otherwise hits only the 17pt glyph.
                        .contentShape(Rectangle())
                }.accessibilityLabel("Challenge information").disabled(game.busy)
            }
            if let notice=game.challengeNotice {
                Text(notice).font(.system(size:13)).multilineTextAlignment(.center)
                if game.phase=="waiting" {Button {Task{await game.start()}} label:{Image(systemName:"arrow.clockwise").frame(width:44,height:44)}.accessibilityLabel("Check for personal drills").disabled(game.busy)}
            }
            if game.challengeKind == .whosWinning,game.puzzle != nil {
                HStack(spacing:6) {
                    Circle().fill(Color(uiColor:CollectionArt.pieceColor(white:game.state.turn=="white",theme:game.displayedPieces)))
                        .frame(width:9,height:9).overlay(Circle().stroke(ink.opacity(0.35),lineWidth:0.75))
                    Text("\(CollectionArt.pieceColorName(white:game.state.turn=="white",theme:game.displayedPieces)) to move")
                        .font(.system(size:13,weight:.medium,design:.rounded)).accessibilityIdentifier("judgment-turn")
                }
            }
            if game.challengeKind == .blunderPunish {Text(game.blunderStage).font(.system(size:12,weight:.medium,design:.rounded)).opacity(0.65).accessibilityIdentifier("blunder-stage")}
            if game.challengeKind == .opening,let p=game.puzzle {Text("\(min(p.solverMoves,(game.state.moves.count+1)/2)) / \(p.solverMoves)").font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit().opacity(0.6)}
            if game.challengeKind == .tenMoves,game.puzzle != nil {Text("\(min(ImprovementChallenge.turns,(game.state.moves.count+1)/2)) / \(ImprovementChallenge.turns)").font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit().opacity(0.6)}
        }.padding(.horizontal,20).padding(.vertical,12).frame(maxWidth:340)
            .background {CloudChromeSurface()}
            .animation(reduceMotion || !game.motion ? nil:.easeInOut(duration:0.2),value:game.showInfo)
    }
    private func symbol(_ name:String,size:CGFloat)->some View {Image(systemName:name).font(.system(size:size,weight:.regular)).frame(width:44,height:44).contentShape(Circle())}
    private func control(_ icon:String,_ label:String,disabled:Bool=false,action:@escaping()->Void)->some View {
        Button(action:action){Image(systemName:icon).font(.system(size:18,weight:.regular)).frame(maxWidth:.infinity).frame(height:44).contentShape(Rectangle())}.disabled(disabled).accessibilityLabel(label)
    }
    private var promotionPanel:some View {
        CloudPopup(title:"Promote pawn",symbol:"crown",dismiss:{game.promotion=[]}) {
            HStack(spacing:6) {ForEach(game.promotion,id:\.self) {move in promotionChoice(move)}}
        } actions: {EmptyView()}.accessibilityIdentifier("promotion-panel")
    }
    private func promotionChoice(_ move:String)->some View {
        let kind=String(move.suffix(1))
        let name=["q":"Queen","r":"Rook","b":"Bishop","n":"Knight"][kind] ?? "Promote"
        return Button {Task{await game.play(move)}} label:{
            PieceChoice(kind:kind,white:game.solverWhite,theme:game.displayedPieces)
                .frame(maxWidth:.infinity).frame(height:86)
                .background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:16))
        }.disabled(game.busy).accessibilityLabel(name)
    }
    private var settingsPanel:some View {
        CloudPopup(title:"Settings",symbol:"slider.horizontal.3",dismiss:{settings=false}) {
            VStack(spacing:10) {
                menuRow("Profile analysis",symbol:"person.crop.circle") {settings=false;showingProfile=true}
                menuRow("Privacy & support",symbol:"hand.raised") {settings=false;showingLegal=true}
                Divider().padding(.vertical,4)
                preferenceRow("Sound & haptics",symbol:"speaker.wave.2",value:$game.sound,identifier:"Toggle sound")
                preferenceRow("Cloud motion",symbol:"wind",value:$game.motion,identifier:"Toggle motion")
                if reduceMotion {Text("Motion follows your iPhone’s accessibility setting.").font(.footnote).foregroundStyle(ink.opacity(0.65))}
            }
        } actions: {
            Text("CloudChess · \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.footnote).dynamicTypeSize(...DynamicTypeSize.accessibility1).foregroundStyle(ink.opacity(0.5)).frame(maxWidth:.infinity)
        }.accessibilityIdentifier("settings-panel")
    }
    private func menuRow(_ title:String,symbol:String,action:@escaping()->Void)->some View {
        Button(action:action) {
            settingsRowLabel(title,symbol:symbol,accessory:"chevron.right")
                .font(.body.weight(.medium)).padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(.white.opacity(0.68),in:RoundedRectangle(cornerRadius:18,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(.white.opacity(0.7),lineWidth:0.75))
                .contentShape(RoundedRectangle(cornerRadius:18,style:.continuous))
        }.accessibilityLabel(title)
    }
    private func preferenceRow(_ title:String,symbol:String,value:Binding<Bool>,identifier:String)->some View {
        Button {value.wrappedValue.toggle()} label:{
            settingsRowLabel(title,symbol:symbol,accessory:value.wrappedValue ? "checkmark.circle.fill":"circle",accessoryOpacity:value.wrappedValue ? 1:0.3).font(.body.weight(.medium)).padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(.white.opacity(0.68),in:RoundedRectangle(cornerRadius:18,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(.white.opacity(0.7),lineWidth:0.75))
                .contentShape(RoundedRectangle(cornerRadius:18,style:.continuous))
        }.accessibilityLabel(identifier).accessibilityValue(value.wrappedValue ? "On":"Off").accessibilityAddTraits(value.wrappedValue ? .isSelected:[])
    }
    private func settingsRowLabel(_ title:String,symbol:String,accessory:String,accessoryOpacity:Double=1)->some View {
        VStack(alignment:.leading,spacing:10) {
            if textSize.isAccessibilitySize {
                HStack {Image(systemName:symbol);Spacer();Image(systemName:accessory).opacity(accessoryOpacity)}
                    .font(.system(size:20)).accessibilityHidden(true)
                Text(title).dynamicTypeSize(...DynamicTypeSize.accessibility3).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
            } else {
                HStack(spacing:14) {
                    Image(systemName:symbol).font(.system(size:20)).frame(width:25)
                    Text(title).fixedSize(horizontal:false,vertical:true);Spacer(minLength:0)
                    Image(systemName:accessory).font(.system(size:17,weight:.medium)).opacity(accessoryOpacity)
                }
            }
        }
    }
    private func cancelConfirmation() {game.showSkip=false;game.showUndo=false;game.showHint=false}
    private var confirmationPanel:some View {
        let skip=game.showSkip,hint=game.showHint
        let title=skip ? "Skip this puzzle?":hint ? game.hintTitle:"Undo your last move?"
        let message=skip ? "Skipping costs \(Int(ChallengeScore.value(rating:game.puzzle?.rating ?? 400,kind:game.challengeKind)*0.5).formatted()) points—half this puzzle’s value.":hint ? "This hint reduces the puzzle’s reward by 10%, from \(Int(game.puzzleReward).formatted()) to \(Int(game.puzzleReward*0.9).formatted()) points. Your score stays the same.":"This puzzle’s reward will drop 20%, from \(Int(game.puzzleReward).formatted()) to \(Int(game.puzzleReward*0.8).formatted()) points. Each undo reduces the remaining reward again."
        return CloudPopup(title:title,symbol:skip ? "forward.end":hint ? "sparkles":"arrow.counterclockwise",dismiss:cancelConfirmation) {
            Text(message).font(.body).foregroundStyle(ink.opacity(0.75)).fixedSize(horizontal:false,vertical:true)
        } actions: {
            VStack(spacing:8) {
                Button {
                    cancelConfirmation()
                    Task{if skip {await game.newGame()}else if hint {await game.hint()}else {await game.undo()}}
                } label:{Text(skip ? "Skip puzzle":hint ? "Reveal hint":"Undo move").frame(maxWidth:.infinity)}
                    .buttonStyle(CloudActionStyle(destructive:skip)).disabled(game.busy).accessibilityIdentifier("confirm-action")
                Button(hint ? "Keep thinking":"Keep playing",action:cancelConfirmation).font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).frame(maxWidth:.infinity,minHeight:48).accessibilityIdentifier("cancel-action")
            }
        }.accessibilityIdentifier("confirmation-panel")
    }

}

/// Indeterminate work, never a fabricated search percentage. Keep the position
/// visible, acknowledge the pending move, and expose the actual stage to VoiceOver.
private struct EngineThinkingIndicator:View {
    let activity:String,reduced:Bool
    @State private var visible=false
    var body:some View {
        HStack(spacing:12) {
            Image(systemName:"sparkle.magnifyingglass").font(.system(size:19,weight:.medium))
            if reduced {ProgressView().controlSize(.small)}
            else {
                TimelineView(.animation(minimumInterval:1.0/30)) {timeline in
                    let t=timeline.date.timeIntervalSinceReferenceDate
                    HStack(spacing:6) {
                        ForEach(0..<3) {i in
                            let wave=(sin(t*4.2-Double(i)*0.9)+1)/2
                            Circle().frame(width:5,height:5).opacity(0.35+0.65*wave).offset(y:-3*wave)
                        }
                    }.frame(height:20)
                }
            }
        }.padding(.horizontal,18).padding(.vertical,12)
            .background(.regularMaterial,in:Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.8),lineWidth:1))
            .opacity(visible ? 1:0)
            .accessibilityElement(children:.ignore).accessibilityLabel(activity)
            .accessibilityIdentifier("engine-thinking").accessibilityHidden(!visible)
            .task {
                do {try await Task.sleep(for:.milliseconds(180))} catch {return}
                withAnimation(.easeOut(duration:0.18)){visible=true}
            }
    }
}

/// A conventional evaluation bar in the equipped piece colors; White grows right.
/// Orientation never changes score perspective, including when playing Black.
private struct HorizontalEvaluationBar:View {
    let pieceTheme:Int
    let centipawns:Double,solverWhite:Bool,reducedMotion:Bool,pending:Bool
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private var whiteCP:Double {centipawns.isFinite ? (solverWhite ? centipawns:-centipawns):0}
    private var verdict:String {abs(whiteCP)<=20 ? "The position is even":"\(CollectionArt.pieceColorName(white:whiteCP>0,theme:pieceTheme)) is winning"}
    private var whiteShare:Double {abs(whiteCP)<=20 ? 0.5:0.5+0.48*tanh(whiteCP/500)}
    var body:some View {
        VStack(spacing:10) {
            GeometryReader {geo in
                ZStack(alignment:.leading) {
                    Color(uiColor:CollectionArt.pieceColor(white:false,theme:pieceTheme))
                    Color(uiColor:CollectionArt.pieceColor(white:true,theme:pieceTheme)).frame(width:geo.size.width*whiteShare)
                    Rectangle().fill(Color(red:0.54,green:0.62,blue:0.69))
                        .frame(width:1).offset(x:geo.size.width*whiteShare-0.5)
                    Rectangle().fill(Color.gray.opacity(0.55)).frame(width:1,height:6)
                        .position(x:geo.size.width/2,y:geo.size.height/2)
                }.clipShape(RoundedRectangle(cornerRadius:4))
                    .overlay(RoundedRectangle(cornerRadius:4).stroke(ink.opacity(0.20),lineWidth:1))
            }.frame(height:16).accessibilityHidden(true)
            if pending {Color.clear.frame(height:17).accessibilityHidden(true)}
            else {
                Text(verdict).font(.system(size:14,weight:.semibold,design:.rounded)).foregroundStyle(ink)
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("evaluation-verdict")
            }
        }.padding(.horizontal,16).padding(.vertical,12)
            .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.65),lineWidth:0.8))
            .animation(reducedMotion ? nil:.easeInOut(duration:0.45),value:whiteCP)
            .accessibilityElement(children:.contain).accessibilityLabel("Position evaluation")
            .accessibilityIdentifier("evaluation-bar")
    }
}

/// A compact modal retains the board context and blocks underlying input.
struct ChallengeIntermission:View {
    let returning:Bool,firstIntroduction:Bool
    let title:String,explanation:String
    let score:Double
    var rewardMultiplier:Double=1
    let reducedMotion:Bool,busy:Bool
    let proceed:()->Void
    @State private var appeared=false
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    var body:some View {
        GeometryReader {geo in
            ZStack {
                ink.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                VStack(spacing:0) {
                    ScrollView {
                        VStack(spacing:geo.size.height<720 ? 13:18) {
                            Image(systemName:returning ? "cloud.sun.fill":"cloud.fill")
                                .font(.system(size:46,weight:.light)).symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white,Color(red:0.95,green:0.80,blue:0.48))
                                .shadow(color:ink.opacity(0.15),radius:12,y:5).accessibilityHidden(true)
                            Text(returning ? "Welcome back":(firstIntroduction ? "The next puzzle is…":"How to play"))
                                .font(.system(size:16,weight:.medium,design:.rounded)).foregroundStyle(ink.opacity(0.65))
                            if returning {
                                Text(Int(score).formatted()).font(.system(size:42,weight:.semibold,design:.rounded)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1).accessibilityIdentifier("return-score")
                                Text("Continue with your current score?").font(.system(size:20,weight:.medium,design:.rounded))
                                Text("You'll start with a fresh puzzle.").font(.system(size:16,design:.rounded)).foregroundStyle(ink.opacity(0.65))
                            } else {
                                Text(title).font(.title2.weight(.semibold))
                                if rewardMultiplier>1 {Text("\(rewardMultiplier.formatted())× puzzle points").font(.system(size:15,weight:.semibold,design:.rounded)).padding(.horizontal,16).padding(.vertical,8).background(.white.opacity(0.65),in:Capsule()).accessibilityIdentifier("long-puzzle-reward")}
                                Text(explanation).font(.body).lineSpacing(4).accessibilityIdentifier("challenge-explanation")
                                if firstIntroduction {Text("This panel tells you how to play the next puzzle.").font(.system(size:14,design:.rounded)).foregroundStyle(ink.opacity(0.65)).accessibilityIdentifier("first-instruction-notice")}
                            }
                        }.multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.horizontal,26).padding(.top,geo.size.height<720 ? 22:28).padding(.bottom,12)
                    }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize).frame(maxHeight:min(410,geo.size.height*0.56))
                    Button(action:proceed) {
                        HStack(spacing:12) {Text(returning ? "Continue":"Got it!");Image(systemName:"arrow.right")}
                            .font(.system(size:17,weight:.semibold,design:.rounded)).frame(maxWidth:.infinity).padding(.vertical,17)
                            .background(ink,in:Capsule()).foregroundStyle(.white)
                    }.disabled(busy).opacity(busy ? 0.5:1).accessibilityIdentifier(returning ? "continue-session":"acknowledge-instructions").padding(22)
                }.frame(width:min(440,geo.size.width-36))
                    .modifier(CloudCardSurface())
                    .scaleEffect(appeared ? 1:0.96).opacity(appeared ? 1:0)
                    .accessibilityElement(children:.contain).accessibilityIdentifier(returning ? "return-panel":"instruction-panel").accessibilityAddTraits(.isModal)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.foregroundStyle(ink).onAppear {withAnimation(.easeOut(duration:reducedMotion ? 0:0.24)){appeared=true}}
    }
}

struct PieceChoice:UIViewRepresentable {
    var kind:String
    var white:Bool=true
    var theme:Int=0
    func makeUIView(context:Context)->SCNView {
        let view=SCNView();let scene=SCNScene();view.scene=scene;view.backgroundColor = .clear;view.autoenablesDefaultLighting=true;view.antialiasingMode = .multisampling4X
        let piece=CollectionArt.piece(Character(white ? kind.uppercased():kind.lowercased()),theme:theme);scene.rootNode.addChildNode(piece)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=0.80;camera.position=SCNVector3(0,3.2,4.5);camera.look(at:SCNVector3(0,0.64,0));scene.rootNode.addChildNode(camera);view.pointOfView=camera;return view
    }
    func updateUIView(_ view:SCNView,context:Context){}
}


/// Small, static cloud contours keep chrome related to the atmosphere without
/// adding another animation loop or changing the controls' layout/hit regions.
private struct CloudChromeSurface:View {
    var puffiness:CGFloat=1
    var body:some View {
        CloudMessageShape(puffiness:puffiness)
            .fill(LinearGradient(colors:[.white.opacity(0.98),Color(red:0.96,green:0.98,blue:1).opacity(0.96),Color(red:0.86,green:0.92,blue:0.97).opacity(0.94)],startPoint:.top,endPoint:.bottom))
            .overlay {
                CloudMessageShape(puffiness:puffiness)
                    .stroke(LinearGradient(colors:[.white.opacity(0.95),.white.opacity(0.2)],startPoint:.top,endPoint:.bottom),lineWidth:0.75)
            }
            .shadow(color:Color(red:0.29,green:0.46,blue:0.62).opacity(0.12),radius:12,y:6)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CloudMessageShape:Shape {
    var puffiness:CGFloat=1
    func path(in rect:CGRect)->Path {
        let w=rect.width,h=rect.height
        // A single-icon dock is too narrow for legible lobes.
        guard w>=100 else {return Path(roundedRect:rect,cornerRadius:min(w,h)/2)}
        let r=min(25,h/2,w/2)
        let puff=min(10,h*0.18,w*0.045)*puffiness
        // Three low, uneven lobes; broad shoulders and a calm underside preserve
        // a generous flat interior for long mode titles and multi-line notices.
        var p=Path();p.move(to:CGPoint(x:0,y:h/2))
        p.addCurve(to:CGPoint(x:r,y:puff),control1:CGPoint(x:0,y:puff),control2:CGPoint(x:r*0.5,y:puff))
        p.addCurve(to:CGPoint(x:w*0.34,y:puff*0.62),control1:CGPoint(x:w*0.15,y:-puff*0.3),control2:CGPoint(x:w*0.25,y:-puff*0.3))
        p.addCurve(to:CGPoint(x:w*0.67,y:puff*0.48),control1:CGPoint(x:w*0.41,y:-puff*0.34),control2:CGPoint(x:w*0.59,y:-puff*0.34))
        p.addCurve(to:CGPoint(x:w-r,y:puff),control1:CGPoint(x:w*0.77,y:-puff*0.2),control2:CGPoint(x:w*0.85,y:puff*0.1))
        p.addCurve(to:CGPoint(x:w,y:h/2),control1:CGPoint(x:w-r*0.4,y:puff),control2:CGPoint(x:w,y:puff))
        p.addCurve(to:CGPoint(x:w-r,y:h-1),control1:CGPoint(x:w,y:h-1),control2:CGPoint(x:w-r*0.45,y:h-1))
        p.addCurve(to:CGPoint(x:r,y:h-1),control1:CGPoint(x:w*0.68,y:h-puff*0.2),control2:CGPoint(x:w*0.32,y:h-puff*0.2))
        p.addCurve(to:CGPoint(x:0,y:h/2),control1:CGPoint(x:r*0.45,y:h-1),control2:CGPoint(x:0,y:h-1))
        p.closeSubpath()
        return p.offsetBy(dx:rect.minX,dy:rect.minY)
    }
}

/// Ten completed work stages, with a bounded sequential domino cascade.
private struct PuzzleGenerationView:View {
    let step:Int,reduced:Bool
    @State private var dominoes=KingDominoPhysics()
    @State private var lastFrame=Date()
    private let ink=Color(red:0.12,green:0.22,blue:0.34)
    var body:some View {
        ZStack {
            Color(rgb:0xDDEAF4).opacity(0.24).ignoresSafeArea()
            VStack(spacing:20) {
                GeometryReader {geo in
                    let cell=geo.size.width/11.2
                    HStack(alignment:.bottom,spacing:0) {
                        ForEach(0..<10) {i in
                            LoadingKing().fill(i.isMultiple(of:2) ? Color.white:ink)
                                .overlay(LoadingKing().stroke(ink.opacity(0.24),lineWidth:1))
                                .frame(width:cell*0.64,height:cell*1.45)
                                .shadow(color:ink.opacity(0.18),radius:2,y:3)
                                .scaleEffect(reduced ? 1:1+0.022*sin(lastFrame.timeIntervalSinceReferenceDate*2.6-Double(i)*0.38),anchor:.bottom)
                                .rotationEffect(.radians(reduced ? 0:dominoes.angles[i]),anchor:.bottom)
                                .offset(y:reduced ? 0:-dominoes.impacts[i]*2)
                                .opacity(reduced && i<step ? 0.45:1)
                                .frame(width:cell,height:70,alignment:.bottom)
                        }
                    }
                }.frame(height:70).accessibilityHidden(true)
                GeometryReader {geo in
                    Capsule().fill(ink.opacity(0.1))
                    Capsule().fill(ink).frame(width:geo.size.width*Double(step)/10)
                }.frame(height:5).accessibilityElement().accessibilityLabel("Generating puzzle")
                    .accessibilityValue("\(step) of 10 stages complete").accessibilityIdentifier("generation-progress")
                Text("please wait while your puzzle is fully generated by your phone!")
                    .font(.system(size:13,weight:.medium,design:.rounded)).foregroundStyle(ink.opacity(0.7))
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("generation-message")
            }.padding(26).frame(maxWidth:380).modifier(CloudCardSurface()).padding(.horizontal,20)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("puzzle-generation").accessibilityAddTraits(.isModal)
        .onReceive(Timer.publish(every:reduced ? 3600:1.0/60,on:.main,in:.common).autoconnect()) {now in
            let elapsed=now.timeIntervalSince(lastFrame);lastFrame=now
            if !reduced {dominoes.advance(seconds:elapsed,completed:step)}
        }

    }
}
private struct LoadingKing:Shape {
    func path(in rect:CGRect)->Path {
        var p=Path()
        p.addRoundedRect(in:CGRect(x:0.42,y:0,width:0.16,height:0.25),cornerSize:CGSize(width:0.025,height:0.025))
        p.addRoundedRect(in:CGRect(x:0.28,y:0.07,width:0.44,height:0.11),cornerSize:CGSize(width:0.025,height:0.025))
        p.move(to:CGPoint(x:0.18,y:0.3));p.addQuadCurve(to:CGPoint(x:0.82,y:0.3),control:CGPoint(x:0.5,y:0.15))
        p.addLine(to:CGPoint(x:0.7,y:0.48));p.addLine(to:CGPoint(x:0.63,y:0.54))
        p.addQuadCurve(to:CGPoint(x:0.87,y:0.87),control:CGPoint(x:0.63,y:0.73))
        p.addLine(to:CGPoint(x:0.13,y:0.87));p.addQuadCurve(to:CGPoint(x:0.37,y:0.54),control:CGPoint(x:0.37,y:0.73))
        p.addLine(to:CGPoint(x:0.3,y:0.48));p.closeSubpath()
        p.addRoundedRect(in:CGRect(x:0.07,y:0.9,width:0.86,height:0.1),cornerSize:CGSize(width:0.04,height:0.04))
        return p.applying(CGAffineTransform(a:rect.width,b:0,c:0,d:rect.height,tx:rect.minX,ty:rect.minY))
    }
}


/// Uniform 20×23 vector trophies. All five silhouettes share the same baseline
/// and height, use the opponent's actual body tint, and never become color emoji.
private struct CapturedPieceIcon:Shape {
    let kind:String
    func path(in rect:CGRect)->Path {
        var p=Path()
        func move(_ x:CGFloat,_ y:CGFloat){p.move(to:CGPoint(x:x,y:y))}
        func line(_ x:CGFloat,_ y:CGFloat){p.addLine(to:CGPoint(x:x,y:y))}
        func curve(_ x:CGFloat,_ y:CGFloat,_ cx:CGFloat,_ cy:CGFloat){p.addQuadCurve(to:CGPoint(x:x,y:y),control:CGPoint(x:cx,y:cy))}
        switch kind {
        case "P":
            p.addEllipse(in:CGRect(x:0.27,y:0.03,width:0.46,height:0.37))
            move(0.31,0.39);line(0.69,0.39);line(0.69,0.48);line(0.61,0.52)
            curve(0.78,0.85,0.60,0.75);line(0.22,0.85);curve(0.39,0.52,0.40,0.75);line(0.31,0.48);p.closeSubpath()
        case "R":
            move(0.15,0.03);line(0.31,0.03);line(0.31,0.18);line(0.42,0.18);line(0.42,0.03)
            line(0.58,0.03);line(0.58,0.18);line(0.69,0.18);line(0.69,0.03);line(0.85,0.03)
            line(0.85,0.32);line(0.70,0.40);line(0.66,0.72);line(0.79,0.85);line(0.21,0.85)
            line(0.34,0.72);line(0.30,0.40);line(0.15,0.32);p.closeSubpath()
        case "B":
            move(0.50,0.03);curve(0.79,0.35,0.87,0.25);curve(0.60,0.48,0.79,0.44)
            line(0.62,0.66);curve(0.78,0.85,0.66,0.79);line(0.22,0.85)
            curve(0.38,0.66,0.34,0.79);line(0.40,0.48);curve(0.24,0.29,0.12,0.45)
            line(0.39,0.14);line(0.55,0.34);line(0.64,0.28);line(0.45,0.09);p.closeSubpath()
        case "N":
            move(0.57,0.03);line(0.62,0.15);curve(0.81,0.48,0.86,0.23)
            line(0.78,0.85);line(0.22,0.85);curve(0.47,0.49,0.25,0.66)
            line(0.32,0.43);line(0.20,0.52);line(0.09,0.43);line(0.25,0.21)
            line(0.41,0.15);line(0.44,0.03);line(0.51,0.14);p.closeSubpath()
            p.addEllipse(in:CGRect(x:0.34,y:0.25,width:0.06,height:0.05))
        default:
            move(0.12,0.13);line(0.30,0.34);line(0.31,0.08);line(0.46,0.30)
            line(0.50,0.03);line(0.55,0.30);line(0.70,0.08);line(0.71,0.34);line(0.88,0.13)
            line(0.73,0.51);line(0.62,0.55);curve(0.79,0.85,0.63,0.75)
            line(0.21,0.85);curve(0.38,0.55,0.37,0.75);line(0.27,0.51);p.closeSubpath()
        }
        p.addRoundedRect(in:CGRect(x:0.12,y:0.87,width:0.76,height:0.10),cornerSize:CGSize(width:0.035,height:0.035))
        return p.applying(CGAffineTransform(a:rect.width,b:0,c:0,d:rect.height,tx:rect.minX,ty:rect.minY))
    }
}

private struct JudgmentControls:View {
    @ObservedObject var game:GameModel
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private func captured(_ white:Bool)->some View {
        let pieces=white ? game.state.capturedWhite:game.state.capturedBlack
        let groups=CapturedMaterial.groups(pieces,capturedByWhite:white)
        let opponent=CollectionArt.pieceColorName(white:!white,theme:game.displayedPieces)
        let description=groups.map {"\($0.count) \(opponent.lowercased()) \($0.name)\($0.count==1 ? "":"s")"}.joined(separator:", ")
        return VStack(alignment:.leading,spacing:5) {
            HStack(spacing:4) {
                Circle().fill(Color(uiColor:CollectionArt.pieceColor(white:white,theme:game.displayedPieces))).frame(width:8,height:8)
                    .overlay(Circle().stroke(ink.opacity(0.25),lineWidth:0.6))
                Text("\(CollectionArt.pieceColorName(white:white,theme:game.displayedPieces)) captured").lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength:0)
                Text("\(CapturedMaterial.value(pieces)) pts").monospacedDigit()
            }.font(.system(size:11,weight:.semibold,design:.rounded))
            HStack(alignment:.top,spacing:4) {
                ForEach(groups) {group in
                    VStack(spacing:1) {
                        CapturedPieceIcon(kind:group.kind)
                            .fill(Color(uiColor:CollectionArt.pieceColor(white:group.white,theme:game.displayedPieces)))
                            .overlay(CapturedPieceIcon(kind:group.kind).stroke(ink.opacity(0.7),style:StrokeStyle(lineWidth:0.7,lineJoin:.round)))
                            .frame(width:20,height:23)
                        Text(group.count>1 ? "×\(group.count)":" ")
                            .font(.system(size:10,weight:.semibold,design:.rounded)).monospacedDigit().frame(height:11)
                    }.frame(width:22)
                }
                if groups.isEmpty {Text("—").foregroundStyle(ink.opacity(0.4)).frame(height:23)}
                Spacer(minLength:0)
            }.frame(height:35)
        }.padding(.horizontal,10).padding(.vertical,8)
            .frame(maxWidth:.infinity).background(.white.opacity(0.78),in:RoundedRectangle(cornerRadius:13))
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("\(CollectionArt.pieceColorName(white:white,theme:game.displayedPieces)) captured")
            .accessibilityValue("\(groups.isEmpty ? "No pieces":description), \(CapturedMaterial.value(pieces)) points")
            .accessibilityIdentifier(white ? "captured-by-white":"captured-by-black")
    }
    var body:some View {
        VStack(spacing:9) {
            HStack(spacing:8) {captured(true);captured(false)}
            HStack(spacing:8) {
                ForEach([JudgmentVerdict.white,.even,.black],id:\.rawValue) {answer in
                    Button {Task{await game.answerJudgment(answer)}} label:{
                        HStack(spacing:6) {
                            if answer != .even {Circle().fill(Color(uiColor:CollectionArt.pieceColor(white:answer == .white,theme:game.displayedPieces))).frame(width:12,height:12).overlay(Circle().stroke(ink.opacity(0.3),lineWidth:1))}
                            Text(answer == .even ? "Even":CollectionArt.pieceColorName(white:answer == .white,theme:game.displayedPieces))
                                .font(.system(size:13,weight:.semibold,design:.rounded)).lineLimit(1).minimumScaleFactor(0.7)
                        }.frame(maxWidth:.infinity).frame(height:46)
                            .background(.white.opacity(0.92),in:Capsule()).overlay(Capsule().stroke(ink.opacity(0.12),lineWidth:1))
                    }.buttonStyle(.plain).disabled(game.busy || game.phase != "playing")
                        .accessibilityIdentifier("judgment-"+answer.rawValue)
                }
            }
        }.frame(maxWidth:360).foregroundStyle(ink)
    }
}

/// The same volumetric art as the sky passes IN FRONT of the board. Its opaque
/// two-bank mask conceals the handoff; the existing GPU resources are shared.
private struct CloudJourneyVeil:View {
    let started:Date,reveal:Date?,reduced:Bool,field:CloudAtmosphereDynamics
    var body:some View {
        CloudAtmosphere(motion:!reduced,field:field)
            .mask {
                TimelineView(.animation(minimumInterval:1.0/30,paused:reduced)) {timeline in
                    let age=max(0,timeline.date.timeIntervalSince(started))
                    let opening=reveal.map{min(1,max(0,timeline.date.timeIntervalSince($0)/0.5))} ?? 0
                    let coverage=reduced ? (reveal==nil ? 1.0:0.0):min(1,age/0.35)*(1-opening)
                    Canvas {ctx,size in
                        let smooth=coverage*coverage*(3-2*coverage)
                        for side in 0..<2 {
                            let travel=size.width*(1-smooth)*0.88
                            let offset=side==0 ? -travel:travel
                            var bank=Path()
                            let x=side==0 ? -size.width*0.4:size.width*0.45
                            bank.addRect(CGRect(x:x+offset,y:-size.height*0.2,width:size.width*0.95,height:size.height*1.4))
                            for puff in 0..<9 {
                                let t=Double(puff)/8
                                let radius=size.width*(0.19+0.045*sin(Double(puff*7+side)*1.2))
                                let edge=side==0 ? size.width*0.48:size.width*0.52
                                let drift=sin(age*0.75+Double(puff)*1.7)*7
                                bank.addEllipse(in:CGRect(x:edge+offset-radius,y:size.height*t-radius+drift,width:radius*2,height:radius*2))
                            }
                            ctx.fill(bank,with:.color(.white))
                        }
                    }.blur(radius:reduced ? 0:9).opacity(reduced ? coverage:1)
                }
            }
    }
}

/// One modal language across instructions, settings, confirmations and recovery.
struct CloudCardSurface:ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content:Content)->some View {
        content.background {
            if opaque {RoundedRectangle(cornerRadius:30).fill(Color(rgb:0xEFF5FA))}
            else {RoundedRectangle(cornerRadius:30).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius:30).fill(LinearGradient(colors:[.white.opacity(0.65),Color(rgb:0xDFEDF8).opacity(0.5)],startPoint:.topLeading,endPoint:.bottomTrailing)))}
        }.overlay(RoundedRectangle(cornerRadius:30).stroke(.white.opacity(0.8),lineWidth:1))
            .shadow(color:Color(rgb:0x192E49).opacity(0.18),radius:28,y:12)
    }
}
struct CloudPopup<Content:View,Actions:View>:View {
    let title:String,symbol:String,dismiss:(()->Void)?
    @ViewBuilder let content:()->Content
    @ViewBuilder let actions:()->Actions
    @AccessibilityFocusState private var focused:Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.cloudMotion) private var motion
    private var reduced:Bool {systemReduced || !motion}
    @State private var appeared=false
    @State private var headerHeight:CGFloat=100
    @State private var actionsHeight:CGFloat=160
    var body:some View {
        GeometryReader {geo in
            ZStack {
                Color(rgb:0x192E49).opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture {dismiss?()}.accessibilityHidden(true)
                VStack(spacing:0) {
                    HStack(spacing:12) {
                        Image(systemName:symbol).font(.system(size:20,weight:.medium)).accessibilityHidden(true)
                        Text(title).font(.title2.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.accessibility1).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader).accessibilityFocused($focused)
                        Spacer(minLength:0)
                        if let dismiss {Button(action:dismiss){Image(systemName:"xmark").font(.system(size:18,weight:.medium)).frame(width:44,height:44).background(.white.opacity(0.6),in:Circle()).contentShape(Rectangle())}.accessibilityLabel("Close \(title.lowercased())")}
                    }.padding(.leading,24).padding(.trailing,14).padding(.top,16).padding(.bottom,12)
                        .onGeometryChange(for:CGFloat.self,of:{$0.size.height}){headerHeight=$0}
                    ScrollView {content().frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,24).padding(.vertical,8)}
                        .scrollBounceBehavior(.basedOnSize).frame(maxHeight:max(0,min(geo.size.height*0.50,geo.size.height-headerHeight-actionsHeight-24))).fixedSize(horizontal:false,vertical:true)
                    actions().padding(24).onGeometryChange(for:CGFloat.self,of:{$0.size.height}){actionsHeight=$0}
                }.frame(width:min(440,geo.size.width-32)).modifier(CloudCardSurface())
                    .scaleEffect(appeared || reduced ? 1:0.97).opacity(appeared ? 1:0)
                    .accessibilityElement(children:.contain).accessibilityAddTraits(.isModal)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.onAppear{focused=true;withAnimation(reduced ? nil:.easeOut(duration:0.18)){appeared=true}}.accessibilityAction(.escape){dismiss?()}
    }
}
struct CloudPressStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.cloudMotion) private var motion
    private var reduced:Bool {systemReduced || !motion}
    func makeBody(configuration:Configuration)->some View {
        configuration.label.opacity(!enabled ? 0.32:configuration.isPressed ? 0.65:1)
            .scaleEffect(configuration.isPressed && enabled && !reduced ? 0.97:1)
            .animation(reduced ? nil:.easeOut(duration:0.12),value:configuration.isPressed)
    }
}
struct CloudActionStyle:ButtonStyle {
    var destructive=false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.cloudMotion) private var motion
    private var reduced:Bool {systemReduced || !motion}
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).multilineTextAlignment(.center).padding(.horizontal,20).padding(.vertical,17)
            .frame(minHeight:52).foregroundStyle(.white)
            .background(destructive ? Color(rgb:0xA83B4E):Color(rgb:0x192E49),in:RoundedRectangle(cornerRadius:20))
            .opacity(!enabled ? 0.4:configuration.isPressed ? 0.7:1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.98:1)
            .animation(reduced ? nil:.easeOut(duration:0.12),value:configuration.isPressed)
    }
}

private struct CloudMotionKey:EnvironmentKey {static let defaultValue=true}
extension EnvironmentValues {
    var cloudMotion:Bool {get {self[CloudMotionKey.self]} set {self[CloudMotionKey.self]=newValue}}
}


private struct CloudLegalContent:Decodable {
    struct Section:Decodable {let title:String,body:String}
    struct ExternalLink:Decodable {let title:String,url:URL}
    struct Page:Decodable,Identifiable {let id:String,title:String,symbol:String;let sections:[Section],links:[ExternalLink]}
    let updated:String,contact:String,baseURL:URL,pages:[Page]
    static let bundled:CloudLegalContent? = {
        guard let url=Bundle.main.url(forResource:"legal-content",withExtension:"json",subdirectory:"EngineResources"),
              let data=try? Data(contentsOf:url) else{return nil}
        return try? JSONDecoder().decode(Self.self,from:data)
    }()
}
private struct CloudLegalPanel:View {
    var close:()->Void
    @State private var selection:String?
    private var content:CloudLegalContent? {CloudLegalContent.bundled}
    private var page:CloudLegalContent.Page? {content?.pages.first{$0.id==selection}}
    private var title:String {selection=="gpl" ? "GNU GPL v3":page?.title ?? "Privacy & support"}
    var body:some View {
        CloudPopup(title:title,symbol:page?.symbol ?? "hand.raised",dismiss:close) {
            VStack(alignment:.leading,spacing:18) {
                if let content {
                    if selection=="gpl" {
                        Text(license).font(.footnote).textSelection(.enabled)
                    } else if let page {
                        if page.id=="support",let email=URL(string:"mailto:"+content.contact+"?subject=CloudChess%20support") {
                            Link(destination:email) {Label("Email support",systemImage:"envelope").frame(minHeight:44)}
                                .accessibilityIdentifier("legal-email")
                        }
                        ForEach(page.sections,id:\.title) {section in
                            VStack(alignment:.leading,spacing:6) {
                                Text(section.title).font(.headline)
                                Text(section.body).font(.body).textSelection(.enabled)
                            }
                        }
                        ForEach(page.links,id:\.url) {link in
                            Link(destination:link.url) {Label(link.title,systemImage:"arrow.up.right").frame(minHeight:44)}
                        }
                        if page.id=="licenses" {
                            Button {selection="gpl"} label:{Label("Read GPL license",systemImage:"doc.text").frame(minHeight:44)}
                                .accessibilityIdentifier("legal-gpl")
                        }
                        Link(destination:content.baseURL.appendingPathComponent(page.id+".html")) {
                            Label("View on website",systemImage:"safari").frame(minHeight:44)
                        }.accessibilityIdentifier("legal-website")
                        Text("Updated "+content.updated).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(content.pages) {item in
                            Button {selection=item.id} label:{
                                HStack(spacing:12) {Image(systemName:item.symbol).frame(width:24);Text(item.title);Spacer();Image(systemName:"chevron.right")}
                                    .padding(16).frame(maxWidth:.infinity,minHeight:52,alignment:.leading)
                                    .background(.white.opacity(0.68),in:RoundedRectangle(cornerRadius:18,style:.continuous))
                                    .contentShape(RoundedRectangle(cornerRadius:18,style:.continuous))
                            }.accessibilityIdentifier("legal-"+item.id)
                        }
                    }
                } else {Text("This information could not be loaded. Please reopen the app.")}
            }.frame(maxWidth:.infinity,alignment:.leading)
        } actions: {
            if selection != nil {
                Button {selection = selection=="gpl" ? "licenses":nil} label:{Label("Back",systemImage:"chevron.left").frame(maxWidth:.infinity,minHeight:44)}
                    .accessibilityIdentifier("legal-back")
            }
        }.accessibilityIdentifier("legal-panel")
    }
    private var license:String {
        guard let url=Bundle.main.url(forResource:"Copying",withExtension:"txt",subdirectory:"EngineResources") else{return "License unavailable."}
        return (try? String(contentsOf:url,encoding:.utf8)) ?? "License unavailable."
    }
}
