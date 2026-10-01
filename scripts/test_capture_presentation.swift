import Foundation
@main struct CapturePresentationChecks {
    static func main() async throws {
        var checks=0
        func check(_ b:Bool,_ message:String) {precondition(b,message);checks+=1}
        let vocabulary:Set<String>=["White","Black","Gray","Red","Orange","Yellow","Brown","Green","Blue","Purple","Pink"]
        let expected:[UInt32:String]=[0xFFFFFF:"White",0x000000:"Black",0x808080:"Gray",0xFF0000:"Red",0xFF8000:"Orange",0xFFFF00:"Yellow",0x804000:"Brown",0x00FF00:"Green",0x0000FF:"Blue",0x8000FF:"Purple",0xFF80C0:"Pink",0xF4ECD8:"White",0x144A63:"Blue",0x164F46:"Green"]
        for (rgb,name) in expected {check(PieceColorNames.name(rgb:rgb)==name,"Recognizable basic color \(rgb)")}
        for id in [0]+CollectionTheme.all.map(\.id) {
            let light=PieceColorNames.side(white:true,theme:id),dark=PieceColorNames.side(white:false,theme:id)
            check(vocabulary.contains(light) && vocabulary.contains(dark),"Plain vocabulary in every skin")
            check(light != dark,"Both answer buttons remain distinguishable")
        }
        for white in [true,false] {
            for q in 0...9 {for p in 0...8 {
                let pieces=Array(repeating:"Q",count:q)+Array(repeating:"p",count:p)+["n","B","R"]
                let groups=CapturedMaterial.groups(pieces,capturedByWhite:white)
                check(groups.allSatisfy{$0.white == !white},"Captured trophies use opponent colors, never capturer colors")
                check(groups.reduce(0){$0+$1.count}==pieces.count,"Every trophy counted once")
                check(CapturedMaterial.value(pieces)==q*9+p+11,"Promoted queens and material totals")
                check(groups.map(\.kind)==["Q","R","B","N","P"].filter{kind in pieces.contains{$0.uppercased()==kind}},"Stable piece order")
            }}
            check(CapturedMaterial.groups([],capturedByWhite:white).isEmpty,"No fabricated missing pieces")
        }
        let initial="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        for (moves,expectedWhite,expectedBlack,turn) in [
            (["e2e4","d7d5","e4d5"],["P"],[],"black"),
            (["e2e4","d7d5","e4d5","d8d5"],["P"],["P"],"white"),
            (["e2e4","a7a6","e4e5","d7d5","e5d6"],["P"],[],"black")
        ] {
            let state=try await NativeChess.call(["action":"state","initial":initial,"moves":moves])
            check(state["capturedWhite"] as? [String]==expectedWhite,"White capture ownership from actual moves")
            check(state["capturedBlack"] as? [String]==expectedBlack,"Black capture ownership from actual moves")
            check(state["turn"] as? String==turn,"Side to move from position, not board orientation or winner")
        }
        let bank=try await JudgmentLibrary.shared.load()
        for row in bank {
            for (white,pieces) in [(true,row.capturedWhite),(false,row.capturedBlack)] {
                let groups=CapturedMaterial.groups(pieces,capturedByWhite:white)
                check(groups.allSatisfy{$0.white == !white},"Entire judgment bank uses opponent-colored trophies")
                check(groups.reduce(0){$0+$1.count}==pieces.count,"Bank capture multiplicities preserved")
            }
        }
        print("Passed \(checks) capture ownership, multiplicity, points, turn and simple-color checks across \(bank.count) judgment positions")
        for t in CollectionTheme.all {print("\(t.name): \(PieceColorNames.side(white:true,theme:t.id)) / \(PieceColorNames.side(white:false,theme:t.id))")}
    }
}
