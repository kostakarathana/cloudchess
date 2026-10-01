import SwiftUI

/// Nine identical closed doors. All prize imagery is rasterized off-main once;
/// opening doors never adds nine live 3D renderers to the play scene.
struct RewardDoorsPresentation:View {
    @ObservedObject var game:GameModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exposed:Set<Int>=[]
    @State private var ready=false
    @State private var arrived=false
    private var reduced:Bool {reduceMotion || !game.motion}
    private let ink=Color(rgb:0x334C68)
    var body:some View {
        GeometryReader {geo in
            let width=max(180,min(440,geo.size.width-36,geo.size.height-180))
            ZStack {
                LinearGradient(colors:[Color(rgb:0xCFDFED),Color(rgb:0xEFF3F5),Color(rgb:0xDBE6F2)],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea()
                ambientClouds(size:geo.size).accessibilityHidden(true)
                if let reward=game.collection.pending {
                    VStack(spacing:26) {
                        HStack(spacing:13) {
                            ForEach(0..<2) {i in
                                Image(systemName:i<reward.choices.count ? "diamond.fill":"diamond")
                                    .font(.system(size:16,weight:.medium)).foregroundStyle(ink.opacity(i<reward.choices.count ? 0.9:0.35))
                                    .scaleEffect(i<reward.choices.count ? 1.12:1)
                            }
                        }.frame(height:24).accessibilityElement(children:.ignore)
                            .accessibilityLabel("Choose two doors")
                            .accessibilityValue("\(reward.choices.count) of 2 chosen")
                        LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:9),count:3),spacing:9) {
                            ForEach(Array(reward.shards.enumerated()),id:\.element.id) {index,shard in
                                RewardDoor(shard:shard,index:index,open:exposed.contains(index),chosen:reward.choices.contains(index),reduced:reduced) {
                                    Task {await game.openRewardDoor(index)}
                                }.disabled(game.rewardSaving || reward.complete || reward.choices.contains(index))
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius:31,style:.continuous)
                                .fill(LinearGradient(colors:[.white.opacity(0.9),Color(rgb:0xB3C6D9)],startPoint:.topLeading,endPoint:.bottomTrailing))
                                .shadow(color:ink.opacity(0.15),radius:23,x:0,y:18)
                                .overlay(RoundedRectangle(cornerRadius:31).strokeBorder(.white.opacity(0.85),lineWidth:1))
                        }
                        .frame(width:width)
                        .scaleEffect(arrived ? 1:0.96).opacity(arrived ? 1:0)
                        .accessibilityIdentifier("reward-door-grid")
                        ZStack {
                        if ready {Button {Task {await game.collectReward()}} label:{
                            Image(systemName:"checkmark").font(.system(size:22,weight:.semibold))
                                .foregroundStyle(ink).frame(width:58,height:58)
                                .background(.white.opacity(0.85),in:Circle())
                                .overlay(Circle().strokeBorder(.white,lineWidth:1))
                                .shadow(color:ink.opacity(0.1),radius:10,y:5)
                        }.buttonStyle(.plain).opacity(ready ? 1:0)
                            .scaleEffect(ready ? 1:0.8)
                            .disabled(!ready || game.busy || game.rewardSaving)
                            .accessibilityHidden(!ready)
                            .accessibilityLabel("Collect chosen shards and continue")
                            .accessibilityIdentifier("claim-reward")
                        }
                        }.frame(height:58)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    .task(id:reward.choices) {
                        ready=false
                        // A restored complete reward shows all doors without replaying loot.
                        if !arrived {
                            exposed=Set(reward.complete ? Array(0..<9):reward.choices)
                            ready=reward.complete
                            withAnimation(reduced ? nil:.easeOut(duration:0.45)){arrived=true}
                            return
                        }
                        withAnimation(reduced ? nil:.spring(response:0.6,dampingFraction:0.78)) {exposed=Set(reward.choices)}
                        guard reward.complete else{return}
                        if !reduced {try? await Task.sleep(nanoseconds:650_000_000)}
                        guard !Task.isCancelled else{return}
                        for index in 0..<9 where !reward.choices.contains(index) {
                            withAnimation(reduced ? nil:.easeInOut(duration:0.5)){_ = exposed.insert(index)}
                            if !reduced {try? await Task.sleep(nanoseconds:75_000_000)}
                            guard !Task.isCancelled else{return}
                        }
                        if !reduced {try? await Task.sleep(nanoseconds:400_000_000)}
                        guard !Task.isCancelled else{return}
                        withAnimation(reduced ? nil:.spring(response:0.4,dampingFraction:0.8)){ready=true}
                    }
                }
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier("reward-doors-presentation").accessibilityAddTraits(.isModal)
    }
    private func ambientClouds(size:CGSize)->some View {
        ZStack {
            Image(systemName:"cloud.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.46))
                .frame(width:size.width*0.85).rotationEffect(.degrees(-9)).position(x:size.width*0.14,y:size.height*0.07)
            Image(systemName:"cloud.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.5))
                .frame(width:size.width*0.95).rotationEffect(.degrees(8)).position(x:size.width*0.86,y:size.height*0.92)
        }.blur(radius:3).allowsHitTesting(false)
    }
}

private struct RewardDoor:View {
    let shard:CollectionShard,index:Int,open:Bool,chosen:Bool,reduced:Bool
    let action:()->Void
    @State private var shine:CGFloat = -1
    private var accent:Color {
        switch shard.rarity {
        case .common:return Color(rgb:0x299D70)
        case .rare:return Color(rgb:0x8852D0)
        case .legendary:return Color(rgb:0xEA861E)
        }
    }
    private var highlight:Color {
        switch shard.rarity {
        case .common:return Color(rgb:0xB2F0CC)
        case .rare:return Color(rgb:0xDFC7FF)
        case .legendary:return Color(rgb:0xFFECA3)
        }
    }
    var body:some View {
        Button(action:action) {
            GeometryReader {geo in
                ZStack {
                    RoundedRectangle(cornerRadius:20).fill(Color(rgb:0xD0DCE7))
                        .overlay(RoundedRectangle(cornerRadius:20).fill(.black.opacity(0.035)).padding(2))
                    prize(size:geo.size)
                        .scaleEffect(open ? 1:0.76).opacity(open ? 1:0)
                    lid
                        .rotation3DEffect(.degrees(open && !reduced ? -105:0),axis:(x:0,y:1,z:0),anchor:.leading,perspective:0.38)
                        .opacity(open ? 0:1)
                    if open,chosen {
                        Image(systemName:"checkmark").font(.system(size:10,weight:.bold)).foregroundStyle(.white)
                            .frame(width:21,height:21).background(accent,in:Circle())
                            .overlay(Circle().stroke(.white.opacity(0.85),lineWidth:1.5))
                            .position(x:geo.size.width-15,y:15)
                            .transition(.scale.combined(with:.opacity))
                    }
                }
                .frame(width:geo.size.width,height:geo.size.height)
                .overlay(alignment:.topLeading) {
                    if open && !reduced {
                        Rectangle().fill(LinearGradient(colors:[.clear,.white.opacity(shard.rarity == .legendary ? 0.75:0.42),.clear],startPoint:.leading,endPoint:.trailing))
                            .frame(width:geo.size.width*0.38,height:geo.size.height*2)
                            .rotationEffect(.degrees(24))
                            .offset(x:shine*geo.size.width*1.8,y:-geo.size.height*0.5)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius:20))
                .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(open && chosen ? accent.opacity(0.85):.white.opacity(0.5),lineWidth:open && chosen ? 2:1))
                .shadow(color:open && chosen ? accent.opacity(0.18):.black.opacity(0.07),radius:open && chosen ? 7:2,y:2)
            }.aspectRatio(1,contentMode:.fit)
        }.buttonStyle(RewardDoorPressStyle(reduced:reduced))
            .task(id:open) {
                guard open,!reduced else{shine = -1;return}
                shine = -1
                do {try await Task.sleep(for:.seconds(0.18))} catch{return}
                withAnimation(.easeInOut(duration:shard.rarity == .legendary ? 1.1:0.75)){shine=1}
            }
            .accessibilityRepresentation {
                Button(action:action) {Color.clear}
                    .accessibilityLabel(open ? "\(shard.rarity.title) \(CollectionTheme.find(shard.theme)?.name ?? "") \(shard.kind.rawValue) shard":"Door \(index+1)")
                    .accessibilityValue(open ? (chosen ? "Collected":"Revealed, not collected"):"Closed")
                    .accessibilityHint(open ? "":"Open this door to collect its shard. Two choices per board.")
                    .accessibilityIdentifier("reward-door-\(index)")
            }
    }

    private var lid:some View {
        ZStack {
            RoundedRectangle(cornerRadius:20)
                .fill(LinearGradient(colors:[Color(rgb:0x7898B7),Color(rgb:0x436487)],startPoint:.topLeading,endPoint:.bottomTrailing))
            RoundedRectangle(cornerRadius:14).strokeBorder(.white.opacity(0.22),lineWidth:1).padding(7)
            Image(systemName:"cloud.fill").font(.system(size:30,weight:.regular))
                .foregroundStyle(LinearGradient(colors:[.white,Color(rgb:0xCDDEEC)],startPoint:.top,endPoint:.bottom))
                .shadow(color:Color(rgb:0x253C58).opacity(0.2),radius:1,y:3)
            Circle().fill(Color(rgb:0xF5E6C5)).frame(width:5,height:5).offset(x:30,y:10)
        }
    }
    private func prize(size:CGSize)->some View {
        ZStack {
            RoundedRectangle(cornerRadius:20)
                .fill(LinearGradient(colors:[highlight,accent,accent.opacity(0.90)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(highlight.opacity(0.7),lineWidth:1).padding(4))
            Ellipse().fill(.white.opacity(0.24)).frame(width:size.width*0.80,height:size.height*0.5).blur(radius:12).offset(y:-size.height*0.2)
            if shard.rarity == .legendary {
                RoundedRectangle(cornerRadius:20).fill(LinearGradient(stops:[.init(color:.clear,location:0.1),.init(color:.white.opacity(0.5),location:0.26),.init(color:.clear,location:0.35),.init(color:highlight.opacity(0.65),location:0.72),.init(color:.clear,location:0.85)],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
            if let theme=CollectionTheme.find(shard.theme) {
                CollectionPreview(theme:theme,kind:shard.kind,count:shard.kind.shardCount,slot:shard.slot)
                    .frame(width:size.width*1.36,height:size.height*1.16)
                    .frame(width:size.width,height:size.height).offset(y:-3)
                    .saturation(1).opacity(1)
                    .shadow(color:.black.opacity(0.25),radius:3,y:4)
            }
            Image(systemName:shard.rarity.symbol).font(.system(size:11,weight:.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxHeight:.infinity,alignment:.bottom).padding(.bottom,8)
        }.frame(width:size.width,height:size.height).accessibilityHidden(true)
    }
}

/// Preserve reward color after the button becomes noninteractive. The system's
/// plain style dims disabled artwork, including the two prizes just collected.
private struct RewardDoorPressStyle:ButtonStyle {
    let reduced:Bool
    func makeBody(configuration:Configuration)->some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduced ? 0.97:1)
            .animation(reduced ? nil:.easeOut(duration:0.14),value:configuration.isPressed)
    }
}
