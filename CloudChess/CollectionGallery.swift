import SwiftUI

struct CollectionGallery:View {
    @ObservedObject var game:GameModel
    let close:()->Void
    @State private var kind=CollectibleKind.board
    @State private var rarity:CollectionRarity?
    @State private var detail:CollectionTheme?
    private let ink=Color(rgb:0x192E49)
    private func trySkin(_ id:Int) {game.previewCollection(kind,theme:id);close()}
    var body:some View {
        GeometryReader {geo in
            ZStack {
                ink.opacity(0.24).ignoresSafeArea().onTapGesture(perform:close).accessibilityHidden(true)
                VStack(spacing:12) {
                    HStack {
                        Text(detail?.name ?? "Collection").font(.system(size:23,weight:.semibold,design:.rounded)).lineLimit(2)
                        Spacer()
                        Button {if detail != nil {detail=nil}else{close()}} label:{Image(systemName:detail==nil ? "xmark":"arrow.left").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(detail==nil ? "Close collection":"Back to collection")
                    }.padding(.horizontal,20).padding(.top,10)
                    if let theme=detail {detailView(theme)}
                    else {
                        HStack(spacing:4) {collectionTab("Boards",value:.board);collectionTab("Chess sets",value:.pieces)}
                            .padding(4).background(ink.opacity(0.07),in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,18)
                        HStack(spacing:6) {
                            filter("All",value:nil)
                            ForEach(CollectionRarity.allCases,id:\.self) {r in filter(r.title,value:r)}
                        }.padding(.horizontal,16)
                        ScrollView {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:12)],spacing:12) {
                                if rarity==nil || rarity == .common {
                                    Button {trySkin(0)} label:{
                                        VStack(spacing:14) {Image(systemName:kind == .board ? "checkerboard.rectangle":"cloud.fill").font(.system(size:38));Text("Original").font(.system(size:14,weight:.medium));RarityBadge(rarity:.common)}.frame(maxWidth:.infinity,minHeight:180).background(.white.opacity(0.8),in:RoundedRectangle(cornerRadius:22))
                                    }.overlay(alignment:.topTrailing){equipped(0)}.accessibilityLabel("Original, Common, unlocked").accessibilityIdentifier("collection-default")
                                }
                                ForEach(game.collection.ordered(kind).filter{rarity==nil || $0.rarity==rarity}) {theme in
                                    let count=game.collection.count(kind,theme.id)
                                    Button {if game.collection.unlocked(kind,theme.id){trySkin(theme.id)}else{detail=theme}} label:{
                                        VStack(spacing:4) {
                                            CollectionPreview(theme:theme,kind:kind,count:count).frame(height:112)
                                            Text(count==0 ? "Undiscovered":theme.name).font(.system(size:13,weight:.medium,design:.rounded)).lineLimit(2).frame(height:34)
                                            RarityBadge(rarity:theme.rarity)
                                            HStack(spacing:4) {ForEach(0..<kind.shardCount,id:\.self){i in Circle().fill(i<count ? Color(rgb:theme.rarity.color):ink.opacity(0.12)).frame(width:5,height:5)}}.padding(.top,5)
                                        }.padding(.bottom,14).frame(maxWidth:.infinity).background(.white.opacity(0.82),in:RoundedRectangle(cornerRadius:22))
                                            .overlay(RoundedRectangle(cornerRadius:22).stroke(Color(rgb:theme.rarity.color).opacity(theme.rarity == .common ? 0.1:0.45),lineWidth:1))
                                    }.overlay(alignment:.topTrailing){equipped(theme.id)}
                                        .accessibilityLabel("\(count==0 ? "Undiscovered":theme.name), \(theme.rarity.title)")
                                        .accessibilityValue("\(count) of \(kind.shardCount) shards\(game.collection.unlocked(kind,theme.id) ? ", unlocked":"")")
                                        .accessibilityHint(game.collection.unlocked(kind,theme.id) ? "Preview this style":"View collected shards")
                                        .accessibilityIdentifier("collection-\(kind.rawValue)-\(theme.id)")
                                }
                            }.padding(.horizontal,16).padding(.bottom,20)
                        }
                    }
                }.frame(width:min(560,geo.size.width-28),height:geo.size.height*0.85)
                    .clipShape(RoundedRectangle(cornerRadius:30)).modifier(CloudCardSurface())
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.accessibilityAction(.escape){if detail != nil {detail=nil}else{close()}}.foregroundStyle(ink).accessibilityElement(children:.contain).accessibilityIdentifier("collection-gallery").accessibilityAddTraits(.isModal)
    }
    private func collectionTab(_ title:String,value:CollectibleKind)->some View {
        Button {kind=value;detail=nil} label:{Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity,minHeight:44).background(kind==value ? .white:Color.clear,in:RoundedRectangle(cornerRadius:14))}
            .accessibilityAddTraits(kind==value ? .isSelected:[])
    }
    @ViewBuilder private func equipped(_ id:Int)->some View {
        if (kind == .board ? game.collection.selectedBoard:game.collection.selectedPieces)==id {
            Image(systemName:"checkmark.seal.fill").font(.body).foregroundStyle(.white,ink).padding(10).accessibilityLabel("Equipped")
        }
    }
    private func filter(_ title:String,value:CollectionRarity?)->some View {
        Button {rarity=value} label:{Text(title).font(.system(size:12,weight:.semibold)).frame(maxWidth:.infinity,minHeight:44).background(rarity==value ? ink:Color.white.opacity(0.65),in:Capsule()).foregroundStyle(rarity==value ? .white:ink)}.accessibilityAddTraits(rarity==value ? .isSelected:[])
    }
    private func detailView(_ theme:CollectionTheme)->some View {
        let count=game.collection.count(kind,theme.id),unlocked=game.collection.unlocked(kind,theme.id)
        return ScrollView {
            VStack(spacing:18) {
                RarityBadge(rarity:theme.rarity)
                CollectionPreview(theme:theme,kind:kind,count:count).frame(height:220)
                Text("\(count) / \(kind.shardCount)").font(.system(size:20,weight:.medium,design:.rounded)).monospacedDigit()
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:10) {
                    ForEach(0..<kind.shardCount,id:\.self) {slot in
                        CollectionPreview(theme:theme,kind:kind,count:count,slot:slot).frame(height:78)
                            .background(.white.opacity(0.65),in:RoundedRectangle(cornerRadius:16))
                    }
                }.padding(.horizontal,20)
                Button {trySkin(theme.id)} label:{
                    Label(unlocked ? "Try on":"Collect all shards",systemImage:unlocked ? "checkmark.circle":"lock.fill")
                        .font(.system(size:15,weight:.semibold)).padding(18).frame(maxWidth:.infinity)
                        .background(ink.opacity(unlocked ? 1:0.12),in:Capsule()).foregroundStyle(unlocked ? .white:ink)
                }.disabled(!unlocked).padding(.horizontal,20).accessibilityIdentifier("equip-collection")
            }.padding(.bottom,24)
        }
    }
}
struct RarityBadge:View {
    let rarity:CollectionRarity
    var body:some View {Label(rarity.title,systemImage:rarity.symbol).font(.system(size:10,weight:.bold,design:.rounded)).foregroundStyle(Color(rgb:rarity.color)).padding(.horizontal,9).padding(.vertical,5).background(Color(rgb:rarity.color).opacity(0.10),in:Capsule())}
}
extension Color {init(rgb:UInt32){self.init(uiColor:UIColor(rgb:rgb))}}

