import Foundation

/// Original art direction. Stable IDs are save-format identities, never display order.
struct CollectionTheme:Identifiable,Hashable {
    let id:Int,name:String,family:String,light:UInt32,dark:UInt32,accent:UInt32,pattern:Int
    var rarity:CollectionRarity {id>120 ? .legendary:(id>100 ? .rare:.common)}
    var boardID:String {"board-\(id)"}
    var setID:String {"set-\(id)"}
    var variation:Double {Double((id*37)%101)/100}
    static let all:[CollectionTheme]=rows.split(separator:"\n").map {row in
        let p=row.split(separator:"|").map(String.init)
        return CollectionTheme(id:Int(p[0])!,name:p[1],family:p[2],light:UInt32(p[3],radix:16)!,dark:UInt32(p[4],radix:16)!,accent:UInt32(p[5],radix:16)!,pattern:Int(p[0])!)
    }
    static func find(_ id:Int)->CollectionTheme? {all.first{$0.id==id}}
    static func consolidatedID(_ id:Int)->Int {
        if id==0 || find(id) != nil {return id};if id>120 {return 121};if id>100 {return 101+(id-101)%2};return 1+(max(1,id)-1)%10
    }
    private static let rows="""
    1|Thunderhead|storm|E1F1F5|183649|72D8FF
    2|Midnight Borough|city|D4E0E9|18243C|FFCC74
    3|Tidepool Aquarium|aquarium|DBF5EA|176879|FF9C86
    4|Lantern Grove|grove|EBDDBF|365C49|E8B365
    5|Lunar Expedition|lunar|E5E9F1|42536C|FA9867
    6|Sugar Workshop|candy|FFE8DA|9B4264|8ADBC7
    7|Clockmaker's Desk|clockwork|F5E3B9|3C5158|C58A43
    8|Porcelain Pagoda|paper|F4ECD8|365E8F|EC9B72
    9|Tidal Forge|forge|E8CDBB|343745|FF7844
    10|Winter Filigree|snow|E7F9FF|32608A|A6EAFF
    101|Celestial Conservatory|garden|F1E5FA|5D397D|C4E998
    102|Leviathan's Archive|reef|D7F7ED|144A63|75F6D1
    103|Phoenix Court|phoenix|FFE4CA|781D39|F5AD4E
    104|Nocturne Cathedral|cathedral|E9E4DD|273449|B6A5EC
    105|Jade Dynasty|jade|E4F1D5|164F46|E8BE70
    121|Astral Orrery|astral|EBE7FF|372357|F1BD79
    122|Dragon Sovereign|dragon|FFF0D3|451C35|ED9855
    """
}

/// Plain color vocabulary shared by every side label, independent of theme names
/// and metallic accents. Pale body finishes read as white; dark chromatic bodies
/// retain their recognizable hue rather than an ornamental paint name.
enum PieceColorNames {
    static func name(rgb:UInt32)->String {
        let r=Double((rgb>>16)&255)/255,g=Double((rgb>>8)&255)/255,b=Double(rgb&255)/255
        let high=max(r,g,b),low=min(r,g,b),delta=high-low
        let saturation=high==0 ? 0:delta/high
        if high<0.19 {return "Black"}
        if high>=0.78 && saturation<=0.28 {return "White"}
        if saturation<0.18 {return "Gray"}
        var hue:Double
        if high==r {hue=(g-b)/delta}
        else if high==g {hue=2+(b-r)/delta}
        else {hue=4+(r-g)/delta}
        hue=(hue/6+1).truncatingRemainder(dividingBy:1)
        if hue<0.045 || hue>=0.93 {return "Red"}
        if hue<0.105 {return high<0.72 ? "Brown":"Orange"}
        if hue<0.18 {return high<0.60 ? "Brown":"Yellow"}
        if hue<0.50 {return "Green"}
        if hue<0.70 {return "Blue"}
        if hue<0.83 || high<0.60 {return "Purple"}
        return "Pink"
    }
    static func side(white:Bool,theme:Int)->String {
        guard let t=CollectionTheme.find(theme) else{return white ? "White":"Black"}
        return name(rgb:white ? t.light:t.dark)
    }
}

enum CollectionRarity:String,Codable,CaseIterable {
    case common,rare,legendary
    var title:String {rawValue.capitalized}
    var color:UInt32 {switch self {case .common:return 0x668098;case .rare:return 0x7960CF;case .legendary:return 0xCB8D24}}
    var symbol:String {switch self {case .common:return "diamond.fill";case .rare:return "sparkle";case .legendary:return "crown.fill"}}

}

enum CollectibleKind:String,Codable,CaseIterable {case board,pieces
    var shardCount:Int {self == .board ? 8:6}
}
struct CollectionShard:Codable,Equatable,Identifiable {
    var id:String
    let kind:CollectibleKind,theme:Int,slot:Int
    var rarity:CollectionRarity {CollectionTheme.find(theme)?.rarity ?? .common}
    var collectionID:String {"\(kind.rawValue)-\(theme)"}
}
/// The contents and two choices are saved together with collection ownership.
struct RewardBoard:Codable,Identifiable {
    var id=UUID().uuidString
    var seed:UInt64
    var shards:[CollectionShard]=[]
    var format:Int?=1
    var opened:[Int]?=[]
    // Decode only for migration from an already-awarded legacy piñata.
    var broken:Bool?
    var choices:[Int] {opened ?? []}
    var complete:Bool {choices.count==2}
}
struct CollectionProgress:Codable {
    var masks:[String:UInt16]=[:]
    var quantities:[String:Int]=[:]
    var selectedBoard:Int=0,selectedPieces:Int=0
    var successes=0,target=4
    var sequence:UInt64=0xCC100200
    var pending:RewardBoard?
    var completed:Set<String>=[]
    var catalogVersion:Int?
    var legacyMasks:[String:UInt16]?
    var legacyQuantities:[String:Int]?
    /// Consolidate without deleting earned slots, quantities or a pending reward.
    /// Keep a lossless archive so a future expanded collection can restore identities.
    mutating func migrateCatalog() {
        guard catalogVersion != 6 else{return}
        // The expanded edition preserves v5 ownership and its earlier lossless archive.
        if legacyMasks==nil {legacyMasks=masks};if legacyQuantities==nil {legacyQuantities=quantities}
        func key(_ value:String)->String {
            let p=value.split(separator:"-");guard p.count==2,let id=Int(p[1]) else{return value}
            return "\(p[0])-\(CollectionTheme.consolidatedID(id))"
        }
        var newMasks:[String:UInt16]=[:],newQuantities:[String:Int]=[:]
        for (k,v) in masks {newMasks[key(k),default:0] |= v}
        for (k,v) in quantities {newQuantities[key(k),default:0] += v}
        masks=newMasks;quantities=newQuantities
        selectedBoard=CollectionTheme.consolidatedID(selectedBoard);selectedPieces=CollectionTheme.consolidatedID(selectedPieces)
        if var reward=pending {
            reward.shards=reward.shards.map{CollectionShard(id:$0.id,kind:$0.kind,theme:CollectionTheme.consolidatedID($0.theme),slot:$0.slot)}
            pending=reward
        }
        catalogVersion=6
    }
    mutating func random(_ bound:Int)->Int {
        sequence=sequence &* 6364136223846793005 &+ 1442695040888963407
        return Int((sequence>>16)%UInt64(max(1,bound)))
    }
    func count(_ kind:CollectibleKind,_ theme:Int)->Int {(masks["\(kind.rawValue)-\(theme)"] ?? 0).nonzeroBitCount}
    func unlocked(_ kind:CollectibleKind,_ theme:Int)->Bool {theme==0 || count(kind,theme)==kind.shardCount}
    func ordered(_ kind:CollectibleKind)->[CollectionTheme] {
        CollectionTheme.all.sorted {a,b in let ac=count(kind,a.id),bc=count(kind,b.id);return ac==bc ? a.id<b.id:ac>bc}
    }
    mutating func solved(sessionID:String) {
        guard completed.insert(sessionID).inserted else{return}
        successes+=1
        if pending==nil,successes>=target {pending=RewardBoard(seed:UInt64(random(Int.max)));successes=0;target=3+random(4);prepareContents()}
    }
    /// Upgrade old unopened rewards once; already-granted legacy loot stays owned.
    /// Use the reward's own seed so restoration never consumes coach randomness.
    mutating func prepareContents() {
        guard var reward=pending else{return}
        if reward.format==nil {
            if reward.broken==true {pending=nil;return}
            reward=RewardBoard(id:reward.id,seed:reward.seed)
        }
        guard reward.shards.isEmpty else{pending=reward;return}
        var rng=reward.seed
        func draw(_ bound:Int)->Int {
            // SplitMix64, including the final avalanche, avoids correlated grid slots.
            rng &+= 0x9E3779B97F4A7C15
            var z=rng;z=(z ^ (z>>30)) &* 0xBF58476D1CE4E5B9
            z=(z ^ (z>>27)) &* 0x94D049BB133111EB
            return Int((z ^ (z>>31)) % UInt64(bound))
        }
        var reserved=masks
        let rarities=Array(repeating:CollectionRarity.common,count:6)+[.rare,.rare,.legendary]
        for rarity in rarities {
            let kind:CollectibleKind=draw(2)==0 ? .board:.pieces
            let pool=CollectionTheme.all.filter{$0.rarity==rarity}
            let active=ordered(kind).filter{$0.rarity==rarity && self.count(kind,$0.id)>0 && !unlocked(kind,$0.id)}
            let theme = !active.isEmpty && draw(100)<70 ? active[draw(min(5,active.count))].id:pool[draw(pool.count)].id
            let key="\(kind.rawValue)-\(theme)",mask=reserved[key] ?? 0
            let missing=(0..<kind.shardCount).filter{mask & (1<<$0)==0}
            let slot=missing.isEmpty ? draw(kind.shardCount):missing[draw(missing.count)]
            reward.shards.append(CollectionShard(id:reward.id+"-\(reward.shards.count)",kind:kind,theme:theme,slot:slot))
            reserved[key]=mask | (1<<slot)
        }
        for i in stride(from:8,through:1,by:-1) {reward.shards.swapAt(i,draw(i+1))}
        pending=reward
    }
    /// A single atomic value mutation: never grant the seven unchosen previews.
    @discardableResult mutating func openDoor(_ index:Int)->Bool {
        guard var reward=pending,reward.format==1,reward.shards.count==9,
              reward.shards.indices.contains(index),reward.choices.count<2,
              !reward.choices.contains(index) else{return false}
        let shard=reward.shards[index]
        masks[shard.collectionID,default:0] |= (1<<shard.slot)
        quantities[shard.collectionID,default:0]+=1
        reward.opened=reward.choices+[index];pending=reward
        return true
    }
    mutating func select(_ kind:CollectibleKind,_ theme:Int) {
        guard (theme==0 || CollectionTheme.find(theme) != nil),unlocked(kind,theme) else{return}
        if kind == .board {selectedBoard=theme}else{selectedPieces=theme}
    }
}

