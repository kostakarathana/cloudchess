import Foundation
@main struct Tests {
 static func main()throws {
  var checks=0
  func check(_ b:Bool,_ s:String){precondition(b,s);checks+=1}
  check(CollectionTheme.all.count==17,"Exactly 17 themes for each catalogue")
  check(Set(CollectionTheme.all.map(\.name)).count==17,"Unique original names")
  check(Set(CollectionTheme.all.map{"\($0.light)-\($0.dark)-\($0.accent)-\($0.pattern)-\($0.family)"}).count==17,"Unique authored recipes")
  for theme in CollectionTheme.all {check(theme.light != theme.dark,"Board contrast");check(theme.pattern==theme.id,"Supported art composition")}
  check(CollectionTheme.all.filter{$0.rarity == .common}.count==10,"10 Common per kind")
  check(CollectionTheme.all.filter{$0.rarity == .rare}.count==5,"5 Rare per kind")
  check(CollectionTheme.all.filter{$0.rarity == .legendary}.count==2,"2 Legendary per kind")
  for retired in 1...125 {
   for kind in CollectibleKind.allCases {
    var old=CollectionProgress();let key="\(kind.rawValue)-\(retired)"
    old.masks[key]=UInt16((1<<kind.shardCount)-1);old.quantities[key]=17;old.selectedBoard=retired;old.selectedPieces=retired
    old.pending=RewardBoard(seed:42);old.pending!.shards=[CollectionShard(id:"stable",kind:kind,theme:retired,slot:2)];old.pending!.opened=[0]
    old.migrateCatalog();let mapped=CollectionTheme.consolidatedID(retired)
    check(old.unlocked(kind,mapped),"Migrate earned unlock")
    check(old.quantities["\(kind.rawValue)-\(mapped)"]==17,"Preserve quantity")
    check(old.legacyMasks?[key] == UInt16((1<<kind.shardCount)-1),"Lossless original archive")
    check(old.pending!.shards[0].id=="stable" && old.pending!.shards[0].theme==mapped && old.pending!.choices==[0],"Pending reward identity and state preserved")
    let before=old.masks;old.migrateCatalog();check(old.masks==before,"Idempotent migration")
    let encoded=try JSONEncoder().encode(old),restored=try JSONDecoder().decode(CollectionProgress.self,from:encoded)
    check(restored.catalogVersion==6 && restored.selectedBoard==mapped,"Persisted migration")
   }
  }
  // Expansion must not reconsolidate identities or overwrite the earlier archive.
  for id in CollectionTheme.all.map(\.id) {
   var saved=CollectionProgress();saved.catalogVersion=5;saved.masks=["pieces-\(id)":63];saved.quantities=["pieces-\(id)":29];saved.selectedPieces=id
   saved.legacyMasks=["pieces-119":13];saved.legacyQuantities=["pieces-119":91]
   saved.migrateCatalog()
   check(saved.selectedPieces==id && saved.masks["pieces-\(id)"]==63 && saved.quantities["pieces-\(id)"]==29,"Expansion preserves existing IDs and ownership")
   check(saved.legacyMasks==["pieces-119":13] && saved.legacyQuantities==["pieces-119":91],"Expansion retains original archive")
   let before=try JSONEncoder().encode(saved);saved.migrateCatalog()
   check(try JSONDecoder().decode(CollectionProgress.self,from:before).masks==saved.masks,"v6 migration remains idempotent")
  }
  var legendaryPositions=Array(repeating:0,count:9)
  for seed in 0..<10000 {
   var roll=CollectionProgress();roll.pending=RewardBoard(id:"seed-\(seed)",seed:UInt64(seed));roll.prepareContents()
   let reward=roll.pending!
   check(reward.shards.count==9,"Nine doors")
   check(reward.shards.filter{$0.rarity == .common}.count==6,"Exactly six common")
   check(reward.shards.filter{$0.rarity == .rare}.count==2,"Exactly two rare")
   check(reward.shards.filter{$0.rarity == .legendary}.count==1,"Exactly one legendary")
   legendaryPositions[reward.shards.firstIndex{$0.rarity == .legendary}!]+=1
   check(roll.masks.isEmpty && roll.quantities.isEmpty,"Preparation grants nothing")
   var twin=CollectionProgress();twin.pending=RewardBoard(id:reward.id,seed:UInt64(seed));twin.prepareContents()
   check(twin.pending!.shards==reward.shards,"Deterministic contents and shuffle")
   for shard in reward.shards {check((0..<shard.kind.shardCount).contains(shard.slot),"Valid slot")}
   check(!roll.openDoor(-1) && !roll.openDoor(9),"Bounds safe choices")
   let first=seed%9,second=(first+1)%9
   check(roll.openDoor(first),"First choice")
   check(!roll.openDoor(first),"No duplicate choice")
   roll=try JSONDecoder().decode(CollectionProgress.self,from:JSONEncoder().encode(roll));roll.prepareContents()
   check(roll.pending!.shards==reward.shards && roll.pending!.choices==[first],"Resume same contents and first choice")
   check(roll.quantities.values.reduce(0,+)==1,"Only selected shard awarded")
   check(roll.openDoor(second) && roll.pending!.complete,"Second choice completes board")
   let owned=roll.quantities,masks=roll.masks
   for index in 0..<9 {check(!roll.openDoor(index),"No third choice or repeated grants")}
   roll=try JSONDecoder().decode(CollectionProgress.self,from:JSONEncoder().encode(roll));roll.prepareContents()
   check(roll.quantities==owned && roll.masks==masks && owned.values.reduce(0,+)==2,"Restoring complete board never grants again")
   check(roll.pending!.shards==reward.shards,"Unchosen doors remain unchanged")
  }
  check(legendaryPositions.allSatisfy{(950...1250).contains($0)},"Legendary spread is uniform across positions")
  for granted in [false,true] {
   let legacy=Data("{\"id\":\"old\",\"seed\":42,\"damage\":[],\"broken\":\(granted),\"shards\":[]}".utf8)
   var old=CollectionProgress();old.catalogVersion=6;old.masks=["pieces-1":3];old.quantities=["pieces-1":7]
   old.pending=try JSONDecoder().decode(RewardBoard.self,from:legacy)
   old.prepareContents()
   check(old.masks==["pieces-1":3] && old.quantities==["pieces-1":7],"Legacy ownership never changed")
   check(granted ? old.pending==nil:old.pending?.shards.count==9,"Old claimed reward dismissed; unopened replaced")
   let id=old.pending?.id,shards=old.pending?.shards
   old=try JSONDecoder().decode(CollectionProgress.self,from:JSONEncoder().encode(old));old.prepareContents()
   check(old.pending?.id==id && old.pending?.shards==shards,"Legacy upgrade is idempotent")
  }
  var c=CollectionProgress(),last=0,events=0
  for i in 0..<20000 {
   c.solved(sessionID:"session-\(i)")
   if let pending=c.pending {
    let gap=i+1-last;check((3...6).contains(gap),"Rewards occur every three through six solves");last=i+1;events+=1
    let before=c.successes;c.solved(sessionID:"session-\(i)");check(c.successes==before,"No double milestone")
    let contents=pending.shards,masks=c.masks,quantities=c.quantities
    c.prepareContents();check(c.pending!.shards==contents && c.masks==masks && c.quantities==quantities,"Preparation cannot reroll")
    check(c.openDoor(i%9) && c.openDoor((i+4)%9),"Two earned choices")
    c.pending=nil
   }
  }
  check(events>3000,"Large deterministic milestone regression")
  for kind in CollectibleKind.allCases {
   let ordered=c.ordered(kind);check(ordered.count==17,"Complete catalogue")
   for pair in zip(ordered,ordered.dropFirst()) {check(c.count(kind,pair.0.id)>=c.count(kind,pair.1.id),"Most collected first")}
   for theme in CollectionTheme.all {check(c.count(kind,theme.id)<=kind.shardCount,"Bounded shards");check(c.unlocked(kind,theme.id),"All 34 collections obtainable")}
  }
  var locked=CollectionProgress();locked.select(.board,1);check(locked.selectedBoard==0,"Locked item cannot equip")
  locked.masks["board-1"]=255;locked.select(.board,1);check(locked.selectedBoard==1,"Full set equips")
  for ability in [500.0,1100,1800,2500] {
   var coach=AdaptivePuzzleCoach();coach.ability.mean=ability
   var counts:[ChallengeKind:Int]=[:],history:[ChallengeKind]=[]
   for _ in 0..<10000 {
    let kind=coach.selectChallengeKind(personalAvailable:false);counts[kind,default:0]+=1;history.append(kind);coach.recentChallengeKinds=[kind]
    check(kind != .personal,"No unavailable personal mode")

   }
   check(counts.count==6 && counts.values.allSatisfy{(1450...1900).contains($0)},"Every available mode receives an equal share")
  }
  check(ChallengeScore.value(rating:1500,kind:.finish)==ChallengeScore.value(rating:1500)*3,"Conversion bonus")
  check(ChallengeScore.value(rating:1500,kind:.tenMoves)==ChallengeScore.value(rating:1500)*2.5,"Ten-move bonus")
  print("{\"status\":\"passed\",\"checks\":\(checks),\"rewardEvents\":\(events)}")
 }
}
