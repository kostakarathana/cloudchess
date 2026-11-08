import SwiftUI
import SceneKit

@main struct CloudChessApp:App {
    var body:some Scene {WindowGroup {CloudChessView().preferredColorScheme(.light)}}
}

/// Challenge instructions are the only prose in the play scene.
struct CloudChessView:View {
    @StateObject private var game=GameModel()
    @ObservedObject private var subscription=SubscriptionStore.shared
    @ObservedObject private var connectivity=Connectivity.shared
    @ObservedObject private var ads=GoogleRewardedAds.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings=false
    @State private var showingProfile=false
    @State private var showingLegal=false
    @State private var scoreEmphasis=false
    @State private var displayedScoreEvent=0
    /// Measured header bottom and bottom-controls top (global points): the board fits between.
    @State private var headerBottom:CGFloat=0
    @State private var dockTop:CGFloat=0
    @State private var barTop:CGFloat?
    private func updateHUDEdges() {
        let bottom=min(dockTop>0 ? dockTop:.infinity,barTop ?? .infinity)
        game.world.setHUDEdges(top:Float(headerBottom),bottom:bottom.isFinite ? Float(bottom):0)
    }
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    /// Pale ink for the few HUD glyphs drawn directly on the sky; cards and
    /// popups keep the global ink on their white chrome.
    private var hudInk:Color {game.night ? Color(red:0.93,green:0.96,blue:1):ink}
    private var modalVisible:Bool {game.showSubscription || game.showAdBreak || game.showOffline || game.houseAd != nil || settings || showingProfile || showingLegal || game.showInfo || game.showSkip || game.showHint || game.showNoWin || game.showFailure || !game.promotion.isEmpty || game.phase=="error"}
    private var sceneryPaused:Bool {modalVisible}
    /// DEBUG tutorial-art captures show only the board (and its material bar).
    private var captureHUD:Double {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tutorial-capture") {return 0}
        #endif
        return 1
    }
    var body:some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                CloudAtmosphere(motion:!game.isGenerating && game.motion && !reduceMotion && !game.presentingReward && !sceneryPaused,night:game.night,field:game.world.cloudField).ignoresSafeArea()
                ChessSceneView(world:game.world,revision:game.revision,concealed:!game.boardRevealed || game.presentingReward,paused:sceneryPaused,inputBlocked:modalVisible || game.replayActive || game.journeyActive)
                    .ignoresSafeArea().opacity(game.boardRevealed && !game.presentingReward ? 1:0)
                    .accessibilityHidden(modalVisible || !game.boardRevealed || game.showInfo || game.replayActive || game.journeyActive || game.presentingReward).accessibilityIdentifier("chessboard")
                if !game.journeyActive && !game.replayActive {
                VStack(spacing:0) {
                    HStack {
                        Button {if game.coach.session?.recorded==true {Task{await game.newGame()}}else{game.showSkip=true}} label:{symbol("forward.end",size:18)}.accessibilityLabel(game.coach.session?.recorded==true ? "Next puzzle":"Skip puzzle").disabled(game.busy || game.puzzle==nil)
                        Spacer()
                        scoreDisplay
                        Spacer()
                        Button {withAnimation(reduceMotion || !game.motion ? nil:.spring(response:0.4,dampingFraction:0.8)){settings.toggle()}} label:{symbol(settings ? "xmark":"slider.horizontal.3",size:18)}.accessibilityLabel("Settings")
                    }.foregroundStyle(hudInk).padding(.horizontal,27).padding(.top,18).opacity(captureHUD)
                    // Before any puzzle exists (an ad break or offline card at launch) there is no challenge to describe.
                    challengeCloud
                        .onGeometryChange(for:CGFloat.self,of:{$0.frame(in:.global).maxY}){headerBottom=$0;updateHUDEdges()}
                        .padding(.top,12).padding(.horizontal,22).opacity(game.puzzle == nil && game.challengeNotice == nil ? 0:captureHUD).accessibilityHidden(game.puzzle == nil && game.challengeNotice == nil)
                    Spacer(minLength:0)
                    
                    if let activity=game.evaluationActivity,!game.isGenerating,!game.showInfo {
                        EngineThinkingIndicator(activity:activity,reduced:reduceMotion || !game.motion)
                            .padding(.bottom,14).allowsHitTesting(false)
                    }
                    if game.challengeKind == .tenMoves,game.puzzle != nil,!game.showInfo,!game.presentingReward {
                        HorizontalEvaluationBar(pieceTheme:game.displayedPieces,centipawns:game.coach.session?.evaluation ?? 0,solverWhite:game.solverWhite,reducedMotion:reduceMotion || !game.motion,pending:game.evaluationPending)
                            .opacity(game.evaluationPending ? 0.35:1)
                            .accessibilityHidden(game.evaluationPending)
                            .frame(maxWidth:340).padding(.horizontal,24).padding(.bottom,16).allowsHitTesting(false)
                    }
                    if game.showsMaterialBar,!game.showInfo,!game.presentingReward {
                        MaterialBar(pieceTheme:game.displayedPieces,balance:game.materialBalance,start:game.startingMaterial,solverWhite:game.solverWhite,reducedMotion:reduceMotion || !game.motion)
                            .frame(maxWidth:340)
                            .onGeometryChange(for:CGFloat.self,of:{$0.frame(in:.global).minY}){barTop=$0;updateHUDEdges()}
                            .onDisappear{barTop=nil;updateHUDEdges()}
                            .padding(.horizontal,24).padding(.bottom,16).allowsHitTesting(false)
                    }
                    if game.challengeKind == .whosWinning,game.puzzle != nil,!game.showInfo {
                        JudgmentControls(game:game).padding(.horizontal,22).padding(.bottom,12)
                    }
                    if game.undoTip != nil,!modalVisible {
                        UndoTipToast(dismiss:{game.dismissUndoTip()})
                            .padding(.horizontal,24).padding(.bottom,10)
                            .transition(reduceMotion || !game.motion ? .opacity:.move(edge:.bottom).combined(with:.opacity))
                    }
                    if game.challengeKind != .whosWinning {
                    // Undo is free and immediate; a hint confirms its reward cost first.
                    HStack(spacing:0) {
                        control("arrow.counterclockwise","Undo move",disabled:!game.canUndo){Task{await game.undo()}}
                        control("lightbulb","Hint",disabled:!game.canHint){Task{await game.requestHint()}}
                    }.padding(.horizontal,12).padding(.vertical,4).background {CloudChromeSurface(puffiness:0.45)}.frame(width:144)
                        .onGeometryChange(for:CGFloat.self,of:{$0.frame(in:.global).minY}){dockTop=$0;updateHUDEdges()}
                        .padding(.bottom,32).opacity(captureHUD)
                    }
                }.overlay(alignment:.bottomTrailing) {
                    Button {game.night.toggle();if game.sound {UISelectionFeedbackGenerator().selectionChanged()}} label:{
                        symbol(game.night ? "sun.max.fill":"moon.fill",size:18)
                            .contentTransition(reduceMotion || !game.motion ? .identity:.symbolEffect(.replace))
                            .padding(4)
                            .background {CloudChromeSurface(puffiness:0.45)}
                            .contentShape(Circle())
                    }.padding(.trailing,27).padding(.bottom,32).opacity(captureHUD)
                        .accessibilityLabel("Night mode").accessibilityValue(game.night ? "On":"Off")
                        .accessibilityAddTraits(game.night ? .isSelected:[]).accessibilityIdentifier("night-toggle")
                }.opacity(game.isGenerating || game.journeyActive || game.replayActive ? 0:1).allowsHitTesting(!modalVisible && !game.isGenerating && !game.journeyActive && !game.replayActive && !game.presentingReward).accessibilityHidden(modalVisible || game.isGenerating || game.journeyActive || game.replayActive || game.showInfo || game.presentingReward)
                }
                if settings {settingsPanel.zIndex(5)}
                if !game.promotion.isEmpty {promotionPanel.zIndex(5)}
                if showingProfile {
                    ProfileAnalysisPanel(close:{showingProfile=false}).zIndex(5)
                }
                if showingLegal {CloudLegalPanel(close:{showingLegal=false}).zIndex(5)}
                if let started=game.journeyStarted {
                    CloudJourneyVeil(started:started,reveal:game.journeyReveal,reduced:reduceMotion || !game.motion,night:game.night,field:game.journeyClouds)
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

                if game.showInfo {
                    ChallengeIntermission(
                        firstIntroduction:game.firstTypeIntroduction,
                        title:game.challengeTitle,
                        explanation:game.instructionExplanation,
                        tutorial:TutorialContent.pages(type:game.instructionType,moves:game.puzzle?.solverMoves ?? 1),
                        score:game.liveScore,
                        rewardMultiplier:game.challengeKind.rewardMultiplier,
                        reducedMotion:reduceMotion || !game.motion,
                        busy:game.busy,
                        proceed:{Task{await game.acknowledgeInstructions()}}
                    ).transition(.opacity).zIndex(10)
                }
                if game.showSkip || game.showHint {confirmationPanel.zIndex(15)}
                if game.showNoWin {noWinPanel.zIndex(15)}
                if game.showFailure {failurePanel.zIndex(14)}
                if game.showAdBreak,let offer=game.adOffer,!game.showSubscription {
                    AdBreakPanel(offer:offer,busy:game.busy,watch:{kind in Task{await game.watchAdBreak(kind)}},premium:{game.showSubscription=true}).zIndex(16)
                }
                if game.showOffline && !game.showSubscription {
                    OfflinePanel(premium:{game.showSubscription=true},retry:{Task{await game.continueWithAccess()}}).zIndex(16)
                }
                if let ad=game.houseAd {
                    HouseAdView(index:ad.index,count:ad.count,seconds:game.houseAdSeconds,finish:{game.finishHouseAd()},premium:{game.showSubscription=true}).id(ad.id).transition(.opacity).zIndex(18)
                }
                if game.showSubscription {
                    UnlimitedPuzzlePanel(store:subscription,prompted:game.premiumPrompt,close:{game.closeSubscription()}).zIndex(20)
                }
                if game.waitingForAccess && !game.showSubscription && !game.showAdBreak && !game.showOffline && game.houseAd == nil {
                    VStack { Spacer();Button("Continue playing") {Task{await game.continueWithAccess()}}.buttonStyle(CloudActionStyle()).padding(.bottom,90) }.zIndex(4)
                }
                }.accessibilityHidden(game.presentingReward).allowsHitTesting(!game.presentingReward)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    Color.clear.frame(width:1,height:1).accessibilityElement().accessibilityLabel("Puzzle diagnostics").accessibilityIdentifier("puzzle-status").accessibilityValue(game.diagnostic)
                }
                #endif
            }.foregroundStyle(ink).buttonStyle(CloudPressStyle()).animation(.easeOut(duration:0.18),value:game.showsGeneration)
            .animation(reduceMotion || !game.motion ? nil:.spring(response:0.4,dampingFraction:0.8),value:game.undoTip)
        }
        .environment(\.cloudMotion,game.motion)
        .statusBarHidden(true)
        .task{game.configureMotion(reduced:reduceMotion);game.configureNight(animated:false);await game.start()}
        .task{await game.requestAdConsent()}
        // Switching between cards remains one overlay transaction and one save.
        .onChange(of:modalVisible || game.replayActive){_,_ in updateOverlay()}
        .onChange(of:scenePhase){_,phase in game.setActive(phase == .active);if phase == .active {Task{await subscription.refreshEntitlements()}};if phase == .background {settings=false;showingProfile=false;showingLegal=false;game.showSkip=false;game.showHint=false;game.showNoWin=false;game.promotion=[];game.didEnterBackground()};if phase != .active {game.world.onCancelDrag?()};if phase == .background,ProfileAnalysisFeature.enabled {Task{await OnDeviceProfiles.shared.pause()}}}
        .onChange(of:game.motion){_,_ in game.configureMotion(reduced:reduceMotion)}
        .onChange(of:connectivity.online){_,_ in Task{await game.accessConditionsChanged()}}
        .onChange(of:subscription.unlimited){_,unlimited in if unlimited && game.waitingForAccess && !game.showSubscription {Task{await game.continueWithAccess()}}}
        .onChange(of:reduceMotion){_,_ in game.configureMotion(reduced:reduceMotion)}
    }
    private func updateOverlay() {
        game.world.onCancelDrag?()
        game.setOverlay(modalVisible || game.replayActive)
    }
    private var replayControls:some View {
        VStack {
            HStack {Spacer();Button {game.dismissReplay()} label:{symbol("xmark",size:18).padding(14).background(.regularMaterial,in:Circle())}
                .accessibilityLabel("Close replay").accessibilityIdentifier("close-replay")}.padding(24)
            Spacer()
            VStack(spacing:14) {
                HStack(spacing:7) {ForEach(0..<game.replayCount,id:\.self) {i in
                    Circle().fill(ink.opacity(i<=game.replayIndex ? 0.8:0.15)).frame(width:6,height:6)
                }}.accessibilityElement().accessibilityLabel("Replay progress").accessibilityValue("\(game.replayIndex) of \(max(0,game.replayCount-1)) moves")
                HStack(spacing:24) {
                    Button {game.stepReplay(-1)} label:{symbol(game.replayManual ? "arrow.left":"backward.end",size:20)}.disabled(game.replayIndex==0).accessibilityLabel("Previous replay move").accessibilityIdentifier("replay-back")
                    if !game.replayManual {
                        Button {game.toggleReplay()} label:{symbol(game.replayPlaying ? "pause.fill":"play.fill",size:22)}.accessibilityLabel(game.replayPlaying ? "Pause replay":"Play replay").accessibilityIdentifier("replay-play")
                    }
                    Button {game.stepReplay(1)} label:{symbol(game.replayManual ? "arrow.right":"forward.end",size:20)}.disabled(game.replayIndex>=game.replayCount-1).accessibilityLabel("Next replay move").accessibilityIdentifier("replay-next")
                }
            }.padding(.horizontal,28).padding(.vertical,18).background(.regularMaterial,in:RoundedRectangle(cornerRadius:28)).shadow(color:ink.opacity(0.10),radius:18,y:6).padding(.bottom,32)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("replay-controls")
    }
    private var scoreDisplay:some View {
        VStack(spacing:2) {
            Text(Int(game.liveScore).formatted()).lineLimit(1).minimumScaleFactor(0.6).font(.system(size:38,weight:.bold,design:.rounded)).monospacedDigit()
                .foregroundStyle(scoreEmphasis ? (game.scoreDirection>0 ? (game.night ? Color(red:0.45,green:0.85,blue:0.62):Color(red:0.10,green:0.48,blue:0.31)):(game.night ? Color(red:1.0,green:0.50,blue:0.56):Color(red:0.80,green:0.13,blue:0.22))):hudInk)
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
                .font(.system(size:13,weight:.semibold)).foregroundStyle(hudInk.opacity(0.6)).padding(.top,2)
                .accessibilityElement(children:.ignore).accessibilityLabel("All-time high")
                .accessibilityValue(Int(game.coach.scoring?.best ?? 0).formatted()).accessibilityIdentifier("all-time-high")
            if game.challengeKind.usesHearts,game.puzzle != nil {
                HStack(spacing:7) {ForEach(0..<3) {i in
                    Image(systemName:i<game.coach.remainingHearts ? "heart.fill":"heart")
                        .foregroundStyle(i<game.coach.remainingHearts ? Color(red:0.80,green:0.35,blue:0.40):hudInk.opacity(0.25))
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
                Text(game.challengeTitle).font(.system(size:23,weight:.bold,design:.rounded)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.75).accessibilityAddTraits(.isHeader)
                Button {game.requestInstructions()} label: {
                    Image(systemName:"info.circle").font(.system(size:17))
                        .frame(width:44,height:44)
                        // A custom button style otherwise hits only the 17pt glyph.
                        .contentShape(Rectangle())
                }.accessibilityLabel("Challenge information").disabled(game.busy)
            }
            if game.challengeKind == .tactics,let p=game.puzzle {
                HStack(spacing:7) {ForEach(0..<p.solverMoves,id:\.self) {i in
                    Circle().fill(ink.opacity(i<game.movesUsed ? 0.78:0.16)).frame(width:7,height:7)
                }}.padding(.top,-2)
                    .accessibilityElement(children:.ignore).accessibilityLabel("Moves used")
                    .accessibilityValue("\(game.movesUsed) of \(p.solverMoves)").accessibilityIdentifier("moves-used")
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
                menuRow(subscription.unlimited ? "Premium":"Go Premium",symbol:"cloud.fill") {settings=false;game.showSubscription=true}
                if ProfileAnalysisFeature.enabled {menuRow("Profile analysis",symbol:"person.crop.circle") {settings=false;showingProfile=true}}
                menuRow("Privacy & support",symbol:"hand.raised") {settings=false;showingLegal=true}
                if ads.privacyOptionsRequired {menuRow("Ad privacy choices",symbol:"checkmark.shield") {settings=false;Task{await ads.presentPrivacyOptions()}}}
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
    private var noWinPanel:some View {
        CloudPopup(title:"No winning moves in this position!",symbol:"lightbulb.slash",dismiss:{game.showNoWin=false}) {
            Text("Maybe undo a few moves...").font(.body).foregroundStyle(ink.opacity(0.75)).fixedSize(horizontal:false,vertical:true)
                .accessibilityIdentifier("no-win-message")
        } actions: {
            VStack(spacing:8) {
                Button {Task{await game.undoFromNoWin()}} label:{Label("Undo move",systemImage:"arrow.counterclockwise").frame(maxWidth:.infinity)}
                    .buttonStyle(CloudActionStyle()).disabled(game.busy || !game.canUndo).accessibilityIdentifier("no-win-undo")
                Button("Keep thinking") {game.showNoWin=false}.font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).frame(maxWidth:.infinity,minHeight:48).accessibilityIdentifier("no-win-close")
            }
        }.accessibilityIdentifier("no-win-panel")
    }
    /// Out of hearts: after the shake, the solution, a guided solve or the next puzzle.
    private var failurePanel:some View {
        CloudPopup(title:game.failureSkipped ? "Puzzle skipped":"Out of hearts",symbol:game.failureSkipped ? "forward.end":"heart.slash",dismiss:nil) {
            HStack(spacing:10) {ForEach(0..<3,id:\.self) {i in
                Image(systemName:i<game.coach.remainingHearts ? "heart.fill":"heart").font(.system(size:24,weight:.medium)).foregroundStyle(Color(red:0.80,green:0.35,blue:0.40).opacity(0.75))
            }}.frame(maxWidth:.infinity).accessibilityHidden(true)
        } actions: {
            VStack(spacing:8) {
                Button {Task{await game.showSolution()}} label:{Label("Show solution",systemImage:"play.rectangle").frame(maxWidth:.infinity)}
                    .buttonStyle(CloudActionStyle()).disabled(game.busy).accessibilityIdentifier("failure-solution")
                Button {Task{await game.solveWithArrows()}} label:{Label("Solve with arrows",systemImage:"arrow.up.right").frame(maxWidth:.infinity)}
                    .buttonStyle(CloudActionStyle()).disabled(game.busy).accessibilityIdentifier("failure-guided")
                Button {Task{await game.nextAfterFailure()}} label:{Label("Next puzzle",systemImage:"forward.end").frame(maxWidth:.infinity)}
                    .font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).frame(maxWidth:.infinity,minHeight:48).disabled(game.busy).accessibilityIdentifier("failure-next")
            }
        }.accessibilityIdentifier("failure-panel")
    }
    private func cancelConfirmation() {game.showSkip=false;game.showHint=false}
    private var confirmationPanel:some View {
        let skip=game.showSkip
        let title=skip ? "Skip this puzzle?":game.hintTitle
        return CloudPopup(title:title,symbol:skip ? "forward.end":"lightbulb",dismiss:cancelConfirmation) {
            if skip {
                Text("Skipping costs \(Int(ChallengeScore.value(rating:game.puzzle?.rating ?? 400,kind:game.challengeKind)*0.5).formatted()) points—half this puzzle’s value.").font(.body).foregroundStyle(ink.opacity(0.75)).fixedSize(horizontal:false,vertical:true)
            } else {
                HintCostGraphic(reward:game.puzzleReward,reduced:reduceMotion || !game.motion)
            }
        } actions: {
            VStack(spacing:8) {
                Button {
                    cancelConfirmation()
                    Task{if skip {await game.newGame()}else {await game.hint()}}
                } label:{Text(skip ? "Skip puzzle":"Reveal hint").frame(maxWidth:.infinity)}
                    .buttonStyle(CloudActionStyle(destructive:skip)).disabled(game.busy).accessibilityIdentifier("confirm-action")
                if skip && game.challengeKind == .tactics {
                    // Skipping can also show how it's solved, at the same cost.
                    Button {cancelConfirmation();Task{await game.skipToSolution(guided:false)}} label:{Label("Show solution",systemImage:"play.rectangle").frame(maxWidth:.infinity)}
                        .buttonStyle(CloudActionStyle()).disabled(game.busy).accessibilityIdentifier("skip-solution")
                    Button {cancelConfirmation();Task{await game.skipToSolution(guided:true)}} label:{Label("Solve with arrows",systemImage:"arrow.up.right").frame(maxWidth:.infinity)}
                        .buttonStyle(CloudActionStyle()).disabled(game.busy).accessibilityIdentifier("skip-guided")
                }
                Button(skip ? "Keep playing":"Keep thinking",action:cancelConfirmation).font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).frame(maxWidth:.infinity,minHeight:48).accessibilityIdentifier("cancel-action")
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

/// Improve in x: the prover's material balance (P1 N3 B3 R5 Q9) against a
/// marker at the starting balance. Ending above the marker succeeds. No engine
/// search, so it never dims or waits.
struct MaterialBar:View {
    let pieceTheme:Int
    let balance:Int,start:Int,solverWhite:Bool,reducedMotion:Bool
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private func whiteShare(_ solver:Int)->Double {0.5+0.48*tanh(Double(solverWhite ? solver:-solver)/8)}
    private var ahead:Bool {balance>start}
    var body:some View {
        GeometryReader {geo in
            let current=geo.size.width*whiteShare(balance),mark=geo.size.width*whiteShare(start)
            ZStack(alignment:.leading) {
                Color(uiColor:CollectionArt.pieceColor(white:false,theme:pieceTheme))
                Color(uiColor:CollectionArt.pieceColor(white:true,theme:pieceTheme)).frame(width:current)
                Rectangle().fill(Color(red:0.54,green:0.62,blue:0.69)).frame(width:1).offset(x:current-0.5)
                Capsule().fill(ahead ? Color(red:0.18,green:0.62,blue:0.38):Color(red:0.95,green:0.70,blue:0.25))
                    .overlay(Capsule().stroke(.white,lineWidth:1))
                    .frame(width:4,height:22).position(x:mark,y:geo.size.height/2)
            }.clipShape(RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(ahead ? Color(red:0.18,green:0.62,blue:0.38).opacity(0.8):ink.opacity(0.20),lineWidth:ahead ? 1.5:1))
        }.frame(height:16).accessibilityHidden(true)
            .padding(.horizontal,16).padding(.vertical,12)
            .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.65),lineWidth:0.8))
            .animation(reducedMotion ? nil:.easeInOut(duration:0.45),value:balance)
            .accessibilityElement(children:.ignore).accessibilityLabel("Material balance")
            .accessibilityValue(balance>start ? "Up \(balance-start) from the start":balance<start ? "Down \(start-balance) from the start":"Level with the start")
            .accessibilityIdentifier("material-bar")
    }
}

/// Shown after a lost heart when the engine proves no solution remains from here.
struct UndoTipToast:View {
    let dismiss:()->Void
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    var body:some View {
        Button(action:dismiss) {
            HStack(spacing:12) {
                Image(systemName:"lightbulb.fill").font(.system(size:20)).foregroundStyle(Color(red:0.98,green:0.72,blue:0.16)).accessibilityHidden(true)
                Text("Hint: you may want to undo some previous moves!").font(.system(size:16,weight:.semibold,design:.rounded))
                    .multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                Image(systemName:"arrow.uturn.backward").font(.system(size:15,weight:.bold)).opacity(0.6).accessibilityHidden(true)
            }.foregroundStyle(ink).padding(.horizontal,18).padding(.vertical,14)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
                .overlay(RoundedRectangle(cornerRadius:20).stroke(Color(red:0.98,green:0.72,blue:0.16).opacity(0.7),lineWidth:1.2))
                .shadow(color:ink.opacity(0.16),radius:14,y:6)
        }.buttonStyle(CloudPressStyle()).frame(maxWidth:400)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityLabel("Hint: you may want to undo some previous moves!").accessibilityHint("Dismisses this tip")
            .accessibilityIdentifier("undo-tip")
    }
}

/// The hint's price at a glance: the reward bar loses a 10% slice.
struct HintCostGraphic:View {
    let reward:Double,reduced:Bool
    @State private var cut=false
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private let keep=Color(red:0.18,green:0.62,blue:0.38),lose=Color(red:0.86,green:0.27,blue:0.33)
    var body:some View {
        VStack(spacing:14) {
            ZStack {
                Circle().fill(Color(red:1.0,green:0.85,blue:0.40).opacity(0.35)).frame(width:74,height:74)
                Image(systemName:"lightbulb.max.fill").font(.system(size:36)).symbolRenderingMode(.palette)
                    .foregroundStyle(Color(red:0.98,green:0.72,blue:0.16),ink.opacity(0.75))
            }.accessibilityHidden(true)
            GeometryReader {geo in
                ZStack(alignment:.leading) {
                    Capsule().fill(ink.opacity(0.10))
                    HStack(spacing:2) {
                        Capsule().fill(keep).frame(width:geo.size.width*0.9-1)
                        Capsule().fill(lose.opacity(cut ? 0.25:1)).frame(width:geo.size.width*0.1-1)
                            .offset(y:cut && !reduced ? 10:0).rotationEffect(.degrees(cut && !reduced ? 18:0))
                    }
                }
            }.frame(height:18).accessibilityHidden(true)
            HStack(spacing:10) {
                Text(Int(reward).formatted()).strikethrough(cut,color:lose)
                Image(systemName:"arrow.right").font(.system(size:15,weight:.bold)).accessibilityHidden(true)
                Text(Int(reward*0.9).formatted()).foregroundStyle(keep)
                Text("−10%").font(.system(size:15,weight:.bold,design:.rounded)).foregroundStyle(.white)
                    .padding(.horizontal,8).padding(.vertical,3).background(lose,in:Capsule())
            }.font(.system(size:20,weight:.bold,design:.rounded)).monospacedDigit().foregroundStyle(ink)
                .accessibilityElement(children:.ignore).accessibilityLabel("This puzzle’s reward drops 10%, from \(Int(reward).formatted()) to \(Int(reward*0.9).formatted()) points. Your score stays the same.")
                .accessibilityIdentifier("hint-cost")
        }.frame(maxWidth:.infinity).padding(.vertical,4)
            .onAppear {withAnimation(reduced ? nil:.spring(response:0.55,dampingFraction:0.6).delay(0.35)){cut=true}}
    }
}

/// One illustrated step of a puzzle type's introduction. Images are real
/// renders of the app's board with arrows (scripts/build_tutorial_art.swift).
struct TutorialPage:Identifiable {
    let id:Int,image:String,title:String,text:String
}
enum TutorialContent {
    static func pages(type:String,moves:Int)->[TutorialPage]? {
        let movesText=moves==1 ? "1 move":"\(moves) moves"
        let undo=TutorialPage(id:2,image:"tutorial-undo",title:"Undo to find the way",
            text:"To succeed, you may need to undo moves. Undo takes back your move and the reply so you can try another path. Undo is free; each hint lowers this puzzle’s reward.")
        switch type {
        case "mate":return [
            TutorialPage(id:0,image:"tutorial-mate-goal",title:"Mate in \(moves)",
                text:"Checkmate the king within \(movesText). Your opponent defends after each of your moves."),
            TutorialPage(id:1,image:"tutorial-mate-hearts",title:"Three hearts",
                text:"A wrong move doesn’t end the puzzle. You lose a heart only when you’ve used \(movesText) without checkmate. Lose all three and you can see the solution."),
            undo]
        case "improvement":return [
            TutorialPage(id:0,image:"tutorial-improve-goal",title:"Improve position in \(moves)",
                text:"Within \(movesText), come out ahead: win more material than you give up. Your opponent defends after each of your moves."),
            TutorialPage(id:1,image:"tutorial-improve-bar",title:"Finish above the marker",
                text:"The bar shows the material balance and the marker shows where you started. If you finish at or below it, you lose a heart. Lose all three and you can see the solution."),
            undo]
        default:return nil
        }
    }
}

/// A compact modal retains the board context and blocks underlying input.
struct ChallengeIntermission:View {
    let firstIntroduction:Bool
    let title:String,explanation:String
    var tutorial:[TutorialPage]?=nil
    let score:Double
    var rewardMultiplier:Double=1
    let reducedMotion:Bool,busy:Bool
    let proceed:()->Void
    @State private var appeared=false
    @State private var page=0
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    private var lastPage:Bool {page>=(tutorial?.count ?? 1)-1}
    var body:some View {
        GeometryReader {geo in
            ZStack {
                ink.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                VStack(spacing:0) {
                    if let tutorial {
                        Text(firstIntroduction ? "The next puzzle is…":"How to play")
                            .font(.system(size:16,weight:.medium,design:.rounded)).foregroundStyle(ink.opacity(0.65)).padding(.top,20)
                            .accessibilityIdentifier(firstIntroduction ? "first-instruction-notice":"instruction-heading")
                        TabView(selection:$page) {
                            ForEach(tutorial) {step in
                                ScrollView {
                                    VStack(spacing:12) {
                                        Image(step.image).resizable().scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius:14))
                                            .padding(12)
                                            .frame(maxWidth:.infinity).frame(height:min(250,geo.size.height*0.32))
                                            .background(.white.opacity(0.55),in:RoundedRectangle(cornerRadius:22))
                                            .overlay(RoundedRectangle(cornerRadius:22).stroke(.white.opacity(0.85),lineWidth:1))
                                            .padding(.horizontal,4)
                                            .accessibilityHidden(true)
                                        Text(step.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                        Text(step.text).font(.body).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                                            .accessibilityIdentifier(step.id==0 ? "challenge-explanation":"tutorial-step-\(step.id)")
                                    }.multilineTextAlignment(.center).padding(.horizontal,24).padding(.top,10).padding(.bottom,8)
                                }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize).tag(step.id)
                            }
                        }.tabViewStyle(.page(indexDisplayMode:.never)).frame(height:min(440,geo.size.height*0.58))
                        HStack(spacing:8) {ForEach(tutorial) {step in
                            Circle().fill(ink.opacity(step.id==page ? 0.75:0.18)).frame(width:7,height:7)
                        }}.accessibilityElement(children:.ignore).accessibilityLabel("Page").accessibilityValue("\(page+1) of \(tutorial.count)")
                        Button {
                            if lastPage {proceed()} else {withAnimation(reducedMotion ? nil:.easeInOut(duration:0.25)){page+=1}}
                        } label: {
                            HStack(spacing:12) {Text(lastPage ? "Got it!":"Next");Image(systemName:"arrow.right")}
                                .font(.system(size:17,weight:.semibold,design:.rounded)).frame(maxWidth:.infinity).padding(.vertical,17)
                                .background(ink,in:Capsule()).foregroundStyle(.white)
                        }.disabled(busy).opacity(busy ? 0.5:1).accessibilityIdentifier(lastPage ? "acknowledge-instructions":"tutorial-next").padding(22)
                    } else {
                    ScrollView {
                        VStack(spacing:geo.size.height<720 ? 13:18) {
                            Image(systemName:"cloud.fill")
                                .font(.system(size:46,weight:.light)).symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white,Color(red:0.95,green:0.80,blue:0.48))
                                .shadow(color:ink.opacity(0.15),radius:12,y:5).accessibilityHidden(true)
                            Text(firstIntroduction ? "The next puzzle is…":"How to play")
                                .font(.system(size:16,weight:.medium,design:.rounded)).foregroundStyle(ink.opacity(0.65))
                            Text(title).font(.title2.weight(.semibold))
                            if rewardMultiplier>1 {Text("\(rewardMultiplier.formatted())× puzzle points").font(.system(size:15,weight:.semibold,design:.rounded)).padding(.horizontal,16).padding(.vertical,8).background(.white.opacity(0.65),in:Capsule()).accessibilityIdentifier("long-puzzle-reward")}
                            Text(explanation).font(.body).lineSpacing(4).accessibilityIdentifier("challenge-explanation")
                            if firstIntroduction {Text("This panel tells you how to play the next puzzle.").font(.system(size:14,design:.rounded)).foregroundStyle(ink.opacity(0.65)).accessibilityIdentifier("first-instruction-notice")}
                        }.multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.horizontal,26).padding(.top,geo.size.height<720 ? 22:28).padding(.bottom,12)
                    }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize).frame(maxHeight:min(410,geo.size.height*0.56))
                    Button(action:proceed) {
                        HStack(spacing:12) {Text("Got it!");Image(systemName:"arrow.right")}
                            .font(.system(size:17,weight:.semibold,design:.rounded)).frame(maxWidth:.infinity).padding(.vertical,17)
                            .background(ink,in:Capsule()).foregroundStyle(.white)
                    }.disabled(busy).opacity(busy ? 0.5:1).accessibilityIdentifier("acknowledge-instructions").padding(22)
                    }
                }.frame(width:min(440,geo.size.width-36))
                    .modifier(CloudCardSurface())
                    .scaleEffect(appeared ? 1:0.96).opacity(appeared ? 1:0)
                    .accessibilityElement(children:.contain).accessibilityIdentifier("instruction-panel").accessibilityAddTraits(.isModal)
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
    let started:Date,reveal:Date?,reduced:Bool,night:Bool,field:CloudAtmosphereDynamics
    var body:some View {
        CloudAtmosphere(motion:!reduced,night:night,field:field)
            .mask {
                TimelineView(.animation(minimumInterval:1.0/30,paused:reduced)) {timeline in
                    let age=max(0,timeline.date.timeIntervalSince(started))
                    let opening=reveal.map{min(1,max(0,timeline.date.timeIntervalSince($0)/0.4))} ?? 0
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
