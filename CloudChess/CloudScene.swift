import SwiftUI
import SceneKit

final class CloudScene: ObservableObject {
    let scene=SCNScene(), camera=SCNNode(), boardAnchor=SCNNode(), island=SCNNode(), pieces=SCNNode(), marks=SCNNode()
    var nodes=[String:SCNNode](), symbols=[String:Character]()
    var prepareForDisplay:(() async->Void)?
    var onSquare: ((String)->Void)?
    var canDrag:((String)->Bool)?
    var onDragBegin:((String)->Bool)?
    var canDrop:((String,String)->Bool)?
    var onDrop:((String,String)->Bool)?
    var onCancelDrag:(()->Void)?
    var reducedMotion=false
    var additionalBottomClearance:Float=0
    var moveAnimationDuration:TimeInterval {reducedMotion ? 0.01:0.6}
    @Published private(set) var selectedSquare:String?
    private(set) var whiteAtBottom=true
    private(set) var dimensions=BoardDimensions.standard
    private(set) var boardStyle=BoardStyle.ocean
    private(set) var boardTheme=0,pieceTheme=0
    private var boardMaterials:[SCNMaterial]=[]
    private var hasDisplayedPosition=false
    let cloudField=CloudAtmosphereDynamics()
    let pieceEffects=PieceCloudEffects()
    let moveQuality=MoveQualityEffects()
    let celebration=PuzzleCelebration()
    init() {
        scene.background.contents=UIColor.clear
        scene.rootNode.addChildNode(boardAnchor);boardAnchor.addChildNode(island);island.addChildNode(pieces);island.addChildNode(marks);island.addChildNode(pieceEffects.root);island.addChildNode(moveQuality.root)
        buildBoard();lightScene()
        camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=false
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear=0.1;camera.camera?.zFar=100
        camera.camera?.wantsHDR=true;camera.camera?.wantsExposureAdaptation=false
        camera.camera?.exposureOffset=0.1;camera.camera?.whitePoint=2.4
        camera.camera?.screenSpaceAmbientOcclusionIntensity=0
        camera.camera?.screenSpaceAmbientOcclusionRadius=0.18
        camera.camera?.screenSpaceAmbientOcclusionDepthThreshold=0.12
        let eye=SceneComposition.eye
        camera.position=SCNVector3(eye.x,eye.y,eye.z);camera.look(at:SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        setMotion(false)
    }
    func position(_ square:String)->SCNVector3 {
        let p=dimensions.position(square,whiteAtBottom:whiteAtBottom) ?? .zero;return SCNVector3(p.x,p.y,p.z)
    }
    func square(x:Float,z:Float)->String? {
        dimensions.square(x:x,z:z,whiteAtBottom:whiteAtBottom)
    }
    // Change coordinates, not the camera or sculpture tilt. The solver's side
    // stays near throughout the opponent's reply and after restoring a session.
    func orient(whiteAtBottom:Bool) {
        guard self.whiteAtBottom != whiteAtBottom else{return}
        onCancelDrag?();self.whiteAtBottom=whiteAtBottom
        pieceEffects.clear();moveQuality.clear();marks.childNodes.forEach{$0.removeFromParentNode()}
        for (square,node) in nodes {node.removeAllActions();node.position=position(square)}
        island.childNode(withName:"board-surface",recursively:false)?.eulerAngles.y=whiteAtBottom ? 0:.pi
    }
    func fitBoard(width:Float,height:Float,top:Float,bottom:Float,left:Float=0,right:Float=0) {
        let placement=dimensions.fittedPlacement(width:width,height:height,topInset:top,bottomInset:bottom+additionalBottomClearance,leftInset:left,rightInset:right)
        let scale=placement.scale
        boardAnchor.simdPosition=placement.origin
        island.scale=SCNVector3(scale,scale,scale)
        cloudField.setBoardFootprint(SIMD2((Float(dimensions.columns)/2+0.24)*scale,(Float(dimensions.rows)/2+0.24)*scale),origin:placement.origin)
        scene.rootNode.childNode(withName:"sun",recursively:false)?.light?.orthographicScale=Double(max(11,Float(max(dimensions.columns,dimensions.rows))*scale*0.85+2))
    }
    func configureBoard(_ size:BoardDimensions) {
        guard size != dimensions else{return}
        dimensions=size;pieceEffects.clear();moveQuality.clear()
        for node in island.childNodes where node !== pieces && node !== marks && node !== pieceEffects.root && node !== moveQuality.root {node.removeFromParentNode()}
        pieces.childNodes.forEach{$0.removeFromParentNode()};marks.childNodes.forEach{$0.removeFromParentNode()}
        nodes.removeAll();symbols.removeAll();buildBoard()
    }
    func settleForInstructions() {
        island.removeAction(forKey:"puzzle-transition");island.position=SCNVector3Zero;island.opacity=1
        for (square,node) in nodes {node.removeAction(forKey:"puzzle-arrive");node.position=position(square);node.opacity=1}
    }
    func setBoardStyle(_ style:BoardStyle) {
        boardStyle=style
        // Recolor the existing materials: no board rebuild, piece reset or input change.
        let colors=[style.side,style.rim,style.dark,style.light]
        SCNTransaction.begin();SCNTransaction.disableActions=true
        for (material,color) in zip(boardMaterials,colors) {material.diffuse.contents=color;material.normal.contents=nil;material.roughness.contents=0.43}
        SCNTransaction.commit()
        if boardTheme==0 && hasDisplayedPosition {
            island.childNode(withName:"theme-platform",recursively:false)?.removeFromParentNode()
            if let frame=AtelierAssets.frame(AtelierAssets.originalTheme,columns:dimensions.columns,rows:dimensions.rows) {island.addChildNode(frame)}
        }
    }
    func buildBoard() {
        let side=PieceSculptor.material(boardStyle.side,metal:0.04,roughness:0.43)
        let porcelain=PieceSculptor.material(boardStyle.rim,roughness:0.34)
        let body=PieceSculptor.box(CGFloat(dimensions.columns)+0.36,0.34,CGFloat(dimensions.rows)+0.36,0.10,side,at:SCNVector3(0,-0.135,0))
        body.name="platform";island.addChildNode(body)
        let lip=PieceSculptor.box(CGFloat(dimensions.columns)+0.29,0.12,CGFloat(dimensions.rows)+0.29,0.055,porcelain,at:SCNVector3(0,0.029,0))
        lip.name="platform";island.addChildNode(lip)
        // Shared vertices keep all 64 squares flush. The depth lives at the edge.
        var vertices=[SCNVector3](),dark=[Int32](),light=[Int32]()
        for row in 0...dimensions.rows {for col in 0...dimensions.columns {vertices.append(SCNVector3(Float(col)-Float(dimensions.columns)/2,0.091,Float(row)-Float(dimensions.rows)/2))}}
        for row in 0..<dimensions.rows {for col in 0..<dimensions.columns {
            let a=Int32(row*(dimensions.columns+1)+col),b=a+1,c=a+Int32(dimensions.columns+1),d=c+1
            if (dimensions.rows-1-row+col)%2==1 {light += [a,c,b,b,c,d]} else {dark += [a,c,b,b,c,d]}
        }}
        let blue=PieceSculptor.material(boardStyle.dark,metal:0.02,roughness:0.46)
        let white=PieceSculptor.material(boardStyle.light,roughness:0.43)
        let coordinates=(0...dimensions.rows).flatMap {row in (0...dimensions.columns).map {col in CGPoint(x:col,y:row)}}
        let surface=SCNGeometry(sources:[SCNGeometrySource(textureCoordinates:coordinates),SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:Array(repeating:SCNVector3(0,1,0),count:vertices.count))],elements:[SCNGeometryElement(indices:dark,primitiveType:.triangles),SCNGeometryElement(indices:light,primitiveType:.triangles)])
        boardMaterials=[side,porcelain,blue,white]
        surface.materials=[blue,white]
        let node=SCNNode(geometry:surface);node.name="board-surface";node.eulerAngles.y=whiteAtBottom ? 0:.pi;island.addChildNode(node)
        applyBoardTheme()
    }
    func setCollection(board:Int,pieces:Int) {
        cloudField.setTheme(board:board,pieces:pieces)
        let night=[1,2,5,9,101,102,103,104,121,122].contains(pieces==0 ? board:pieces)
        scene.rootNode.childNode(withName:"sun",recursively:false)?.light?.intensity=night ? 980:1150
        if boardTheme != board {boardTheme=board;applyBoardTheme()}
        if pieceTheme != pieces {
            pieceTheme=pieces
            for (square,node) in nodes {
                let replacement=CollectionArt.piece(symbols[square]!,theme:pieces);replacement.position=position(square);replacement.name=node.name
                node.removeFromParentNode();self.pieces.addChildNode(replacement);nodes[square]=replacement
            }
        }
    }
    private func applyBoardTheme() {
        // The initial invisible board is cheap. Its real dimensions and detailed
        // assets arrive after off-thread preparation, before the first reveal.
        guard hasDisplayedPosition,boardMaterials.count==4 else{return}
        island.childNode(withName:"theme-platform",recursively:false)?.removeFromParentNode()
        guard let theme=CollectionTheme.find(boardTheme) else {setBoardStyle(boardStyle);return}
        boardMaterials[0].diffuse.contents=UIColor(rgb:theme.dark)
        boardMaterials[1].diffuse.contents=UIColor(rgb:theme.accent)
        for i in 2...3 {
            let m=boardMaterials[i];m.diffuse.contents=CollectionArt.tile(theme,light:i==3)
            m.normal.contents=AtelierAssets.texture(theme.id,"normal");m.normal.intensity=0.28
            m.normal.wrapS = .repeat;m.normal.wrapT = .repeat
            m.roughness.contents=AtelierAssets.texture(theme.id,"rough") ?? UIColor(white:0.4,alpha:1)
            m.roughness.wrapS = .repeat;m.roughness.wrapT = .repeat
            m.diffuse.wrapS = .repeat;m.diffuse.wrapT = .repeat
            m.metalness.contents=theme.family=="clockwork" ? 0.28:0.04
            
            m.clearCoat.contents=theme.id==1 ? 1:0.12
            m.clearCoatRoughness.contents=0.08
        }
        decoratePlatform(theme)
    }
    private func decoratePlatform(_ theme:CollectionTheme) {
        if let frame=AtelierAssets.frame(theme,columns:dimensions.columns,rows:dimensions.rows) {island.addChildNode(frame);return}
        let root=SCNNode();root.name="theme-platform"
        let accent=ThemeWorkshop.material(theme.accent,metal:0.45,rough:0.25,glow:[1,2,9,102,121].contains(theme.id) ? 0.4:0)
        let dark=ThemeWorkshop.material(theme.dark,rough:0.4)
        let w=Float(dimensions.columns)/2+0.17,d=Float(dimensions.rows)/2+0.17
        // All ornament is below/outside the playable surface and scales with shape.
        for z:Float in [-d,d] {for i in 0..<dimensions.columns {
            let x=Float(i)-Float(dimensions.columns-1)/2
            switch theme.id {
            case 2:
                for j in 0..<3 {ThemeWorkshop.box(root,0.07,0.06,0.025,SCNVector3(x+Float(j-1)*0.23,-0.13,z),accent,0.003)}
            case 4:ThemeWorkshop.box(root,0.72,0.17,0.05,SCNVector3(x,-0.13,z),dark)
            case 6:root.addChildNode(PieceSculptor.sphere(0.075,SCNVector3(x,-0.10,z),accent,scale:SCNVector3(2.1,1,0.55)))
            case 7:let gear=SCNNode();ThemeWorkshop.ring(gear,0.09,0,accent,thickness:0.015);gear.eulerAngles.x = .pi/2;gear.position=SCNVector3(x,-0.14,z);root.addChildNode(gear)
            case 8:let g=SCNPyramid(width:0.55,height:0.12,length:0.08);g.materials=[accent];let n=SCNNode(geometry:g);n.position=SCNVector3(x,-0.16,z);root.addChildNode(n)
            case 101,102:root.addChildNode(PieceSculptor.sphere(0.055,SCNVector3(x,-0.12,z),accent,scale:SCNVector3(2.5,0.6,0.5)))
            case 121:let n=SCNNode();ThemeWorkshop.ring(n,0.13,0,accent,tilt:0.55,thickness:0.013);n.position=SCNVector3(x,-0.19,z);root.addChildNode(n)
            default:ThemeWorkshop.box(root,0.60,0.025,0.026,SCNVector3(x,-0.14,z),accent,0.003)
            }
        }}
        for x:Float in [-w,w] {ThemeWorkshop.box(root,0.025,0.025,CGFloat(dimensions.rows)*0.94,SCNVector3(x,-0.14,0),accent,0.003)}
        island.addChildNode(root.flattenedClone())
    }
    func lightScene() {
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient
        ambient.light?.color=UIColor(red:0.76,green:0.86,blue:1,alpha:1);ambient.light?.intensity=180;ambient.light?.categoryBitMask=5
        scene.rootNode.addChildNode(ambient)
        let sun=SCNNode();sun.name="sun";sun.light=SCNLight();sun.light?.type = .directional
        sun.light?.color=UIColor(red:1,green:0.965,blue:0.90,alpha:1);sun.light?.intensity=1150;sun.light?.categoryBitMask=5
        let direction=SceneComposition.sun
        sun.position=SCNVector3(direction.x*20,direction.y*20,direction.z*20);sun.look(at:SCNVector3Zero)
        sun.light?.castsShadow=true;sun.light?.shadowMode = .forward
        sun.light?.shadowMapSize=CGSize(width:2048,height:2048);sun.light?.shadowSampleCount=8
        sun.light?.shadowRadius=5;sun.light?.shadowBias=0.002
        sun.light?.shadowColor=UIColor(red:0.12,green:0.22,blue:0.32,alpha:0.30)
        sun.light?.orthographicScale=11;sun.light?.zNear=1;sun.light?.zFar=40
        scene.rootNode.addChildNode(sun)
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let sky=UIGraphicsImageRenderer(size:CGSize(width:512,height:256),format:format).image { ctx in
            let colors=[UIColor(red:1,green:0.98,blue:0.93,alpha:1).cgColor,UIColor(red:0.72,green:0.84,blue:0.94,alpha:1).cgColor,UIColor(red:0.40,green:0.57,blue:0.73,alpha:1).cgColor] as CFArray
            let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.55,1])!
            ctx.cgContext.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:256),options:[])
        }
        scene.lightingEnvironment.contents=sky;scene.lightingEnvironment.intensity=0.55
    }
    func setMotion(_ reduced:Bool) {
        onCancelDrag?()
        reducedMotion=reduced
        // The platform stays level and still; motion controls affect clouds and moves.
        island.removeAllActions();island.position=SCNVector3Zero;island.eulerAngles=SCNVector3Zero
        cloudField.setPaused(reduced)
        island.opacity=1
        if reduced {
            pieceEffects.clear();celebration.clear()
            for (square,node) in nodes {
                node.removeAllActions();node.position=position(square);node.eulerAngles=SCNVector3Zero;node.scale=SCNVector3(1,1,1);node.opacity=1
            }
        }
    }
    func display(_ fen:String,move:String?=nil,dimensions:BoardDimensions?=nil) {
        onCancelDrag?()
        if move==nil {pieceEffects.clear();moveQuality.clear()}
        let firstPosition = !hasDisplayedPosition
        hasDisplayedPosition=true
        let willRebuild=dimensions.map{$0 != self.dimensions} ?? false
        if let dimensions=dimensions {configureBoard(dimensions)}
        if firstPosition && !willRebuild {applyBoardTheme()}
        let next=Self.decode(fen).filter{self.dimensions.position($0.key) != nil}
        if let move=move,move.count>=4 {
            let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2))
            if let n=nodes.removeValue(forKey:from) {
                if let captured=nodes.removeValue(forKey:to) { disappear(captured,animated:true) }
                nodes[to]=n;n.name="piece:\(to)"
                let target=position(to),start=n.position
                n.removeAllActions()
                let duration=moveAnimationDuration
                let action=SCNAction.customAction(duration:duration) { node,t in
                    let f=Float(t)/Float(duration),u=min(1,f),ease=u*u*(3-2*u)
                    node.position=SCNVector3(start.x+(target.x-start.x)*ease,start.y+(target.y-start.y)*ease+sin(u * .pi)*0.16,start.z+(target.z-start.z)*ease)
                }
                n.runAction(.group([action,.scale(to:1,duration:reducedMotion ? 0:0.18),.rotateTo(x:0,y:0,z:0,duration:reducedMotion ? 0:0.20)]))
                // Keep the rook's travel continuous during castling.
                if self.dimensions == .standard,symbols[from]?.lowercased()=="k",abs(Int(from.first!.asciiValue!)-Int(to.first!.asciiValue!))==2 {
                    let rank=String(from.suffix(1)),rookFrom=(to.first=="g" ? "h":"a")+rank,rookTo=(to.first=="g" ? "f":"d")+rank
                    if let rook=nodes.removeValue(forKey:rookFrom) { nodes[rookTo]=rook;rook.name="piece:\(rookTo)";rook.runAction(.move(to:position(rookTo),duration:reducedMotion ? 0:0.55)) }
                }
            }
        }
        for (sq,node) in nodes where next[sq]==nil { disappear(node,animated:move != nil);nodes.removeValue(forKey:sq) }
        for (sq,symbol) in next {
            let promoted = move?.count==5 && sq==String(move!.dropFirst(2).prefix(2))
            if nodes[sq]==nil || promoted || (move==nil && symbols[sq] != symbol) {
                nodes[sq]?.removeFromParentNode()
                let n=CollectionArt.piece(symbol,theme:pieceTheme);n.position=position(sq);n.name="piece:\(sq)";pieces.addChildNode(n);nodes[sq]=n
            } else if move==nil { nodes[sq]?.removeAllActions();nodes[sq]?.position=position(sq);nodes[sq]?.eulerAngles=SCNVector3Zero;nodes[sq]?.isHidden=false;nodes[sq]?.opacity=1;nodes[sq]?.scale=SCNVector3(1,1,1) }
        }
        symbols=next;mark(selected:nil,legal:[],last:move)
    }
    func disappear(_ node:SCNNode,animated:Bool) {
        if animated {pieceEffects.vanish(node,delay:reducedMotion ? 0:moveAnimationDuration*0.54,mate:false,reduced:reducedMotion)}
        else {node.removeFromParentNode()}
    }
    func checkmateKing(white:Bool) {
        guard let square=symbols.first(where:{$0.value == (white ? Character("K"):Character("k"))})?.key,let king=nodes[square] else{return}
        pieceEffects.vanish(king,delay:reducedMotion ? 0:moveAnimationDuration,mate:true,reduced:reducedMotion,retainPiece:true)
    }
    var matePresentationDuration:TimeInterval {reducedMotion ? 0.18:moveAnimationDuration+PieceCloudEffects.mateDuration}
    func hintRegion(around square:String) {
        mark(selected:nil,legal:[],last:nil)
        guard let file=square.first?.asciiValue,let rank=Int(square.suffix(1)) else{return}
        let x=Int(file)-97,y=rank-1
        let material=SCNMaterial();material.lightingModel = .constant
        material.diffuse.contents=UIColor(red:0.96,green:0.77,blue:0.35,alpha:0.38)
        for col in (x/2*2)...min(dimensions.columns-1,x/2*2+1) {
            for row in (y/2*2)...min(dimensions.rows-1,y/2*2+1) {
                let key="\(UnicodeScalar(col+97)!)\(row+1)",p=position(key)
                let tile=SCNBox(width:0.94,height:0.012,length:0.94,chamferRadius:0.06);tile.materials=[material]
                let node=SCNNode(geometry:tile);node.position=SCNVector3(p.x,0.11,p.z)
                node.categoryBitMask=2;node.castsShadow=false;marks.addChildNode(node)
                if !reducedMotion {node.runAction(.repeatForever(.sequence([.fadeOpacity(to:0.55,duration:0.9),.fadeOpacity(to:1,duration:0.9)])))}
            }
        }
        UIAccessibility.post(notification:.announcement,argument:"Look near \(square)")
    }
    func mark(selected:String?,legal:[String],last:String?) {
        selectedSquare=selected
        marks.childNodes.forEach{$0.removeFromParentNode()}
        for (sq,n) in nodes { n.removeAction(forKey:"select");if !n.hasActions {n.position=position(sq);n.scale=SCNVector3(1,1,1)} }
        let glow=PieceSculptor.material(UIColor(red:0.42,green:0.77,blue:0.87,alpha:1),metal:0.2,roughness:0.4)
        glow.lightingModel = .constant
        if let last=last,last.count>=4 {
            for s in [String(last.prefix(2)),String(last.dropFirst(2).prefix(2))] {
                let p=position(s);let g=SCNBox(width:0.96,height:0.009,length:0.96,chamferRadius:0.035)
                let m=SCNMaterial();m.diffuse.contents=UIColor(red:0.64,green:0.78,blue:0.86,alpha:0.35);m.lightingModel = .constant;g.materials=[m]
                let n=SCNNode(geometry:g);n.position=SCNVector3(p.x,0.097,p.z);marks.addChildNode(n)
            }
        }
        if let s=selected {
            let p=position(s),g=SCNTorus(ringRadius:0.37,pipeRadius:0.025);let selection=SCNMaterial();selection.lightingModel = .constant;selection.diffuse.contents=UIColor(red:0.30,green:0.52,blue:0.66,alpha:1);g.materials=[selection]
            let n=SCNNode(geometry:g);n.position=SCNVector3(p.x,0.115,p.z);marks.addChildNode(n)
            if let piece=nodes[s] { piece.runAction(.scale(to:1.06,duration:reducedMotion ? 0:0.18),forKey:"select") }
        }
        for sq in Set(legal.map{String($0.dropFirst(2).prefix(2))}) {
            let p=position(sq),n:SCNNode
            if symbols[sq] != nil {let g=SCNTorus(ringRadius:0.39,pipeRadius:0.034);g.materials=[glow];n=SCNNode(geometry:g)}
            else {n=PieceSculptor.sphere(0.105,SCNVector3Zero,glow,scale:SCNVector3(1,0.25,1))}
            n.position=SCNVector3(p.x,0.115,p.z);marks.addChildNode(n)
        }
        marks.enumerateChildNodes{node,_ in node.categoryBitMask=2}
    }
    static func decode(_ fen:String)->[String:Character] {
        var result=[String:Character](),rank=7,file=0
        for c in fen.split(separator:" ")[0] {
            if c=="/" {rank-=1;file=0} else if let n=c.wholeNumberValue {file+=n} else {result["\(UnicodeScalar(file+97)!)\(rank+1)"]=c;file+=1}
        }
        return result
    }
}

final class BoardAccessibilityElement:UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate()->Bool {activate?();return true}
}
#if DEBUG
private final class DragAccessibilityElement:UIAccessibilityElement {
    weak var controller:PieceDragController?
    override var accessibilityValue:String? {
        get {
            guard let c=controller else{return nil}
            return "begins:\(c.beganCount),active:\(c.isActive),lift:\(c.maximumLift),tilt:\(c.maximumTilt)"
        }
        set {}
    }
}
private final class EffectAccessibilityElement:UIAccessibilityElement {
    weak var world:CloudScene?
    override var accessibilityValue:String? {
        get {
            guard let world=world else{return nil}
            let visibleKings=world.nodes.filter{world.symbols[$0.key]?.lowercased()=="k" && !$0.value.isHidden}.count
            return "captures:\(world.pieceEffects.captureCount),mates:\(world.pieceEffects.mateCount),active:\(world.pieceEffects.activeCount),particles:\(world.pieceEffects.particleNodeCount),kings:\(visibleKings)"
        }
        set {}
    }
}
#endif
private final class MoveQualityAccessibilityElement:UIAccessibilityElement {
    weak var world:CloudScene?
    override var accessibilityValue:String? {
        get {guard let effect=world?.moveQuality else{return nil};return "quality:\(effect.lastQuality),visible:\(effect.visible ? 1:0),square:\(effect.square),events:\(effect.events),pending:\(effect.pending ? 1:0)"}
        set {}
    }
}
final class AccessibleBoardView:SCNView {
    #if DEBUG
    fileprivate var atelierFrameAudit:AnyObject?
    #endif
    var concealed=false
    weak var world:CloudScene?
    var pieceDrag:PieceDragController?
    private var lastRevision:Int?
    private var lastSelection:String?
    private var refreshPending=false
    private var fittedDimensions:BoardDimensions?
    private var fittedViewport=CGRect.null
    private var fittedInsets=UIEdgeInsets.zero
    private var fittedClearance:Float=0
    func boardPoint(at point:CGPoint)->SIMD3<Float>? {
        guard let world=world,bounds.width>0,bounds.height>0 else{return nil}
        return SceneComposition.boardPoint(unit:SIMD2(Float(point.x/bounds.width),Float(point.y/bounds.height)),aspect:Float(bounds.width/bounds.height),scale:world.island.simdScale.x,origin:world.boardAnchor.simdPosition)
    }
    func square(at point:CGPoint)->String? {
        guard let hit=firstInputHit(at:point),let world=world else{return nil}
        var node:SCNNode?=hit.node
        while let n=node {
            if let name=n.name,name.hasPrefix("piece:") {
                let square=String(name.dropFirst(6))
                // An enemy crown can project over the centre of the rank behind
                // it. Preserve real capture/selection hits, but let a selected
                // piece reach a legal empty tile hidden by an unplayable enemy.
                if let source=world.selectedSquare,world.canDrag?(square) != true,
                   world.canDrop?(source,square) != true,let ground=boardPoint(at:point),
                   let target=world.square(x:ground.x,z:ground.z),world.symbols[target]==nil,
                   world.canDrop?(source,target)==true {return target}
                return square
            }
            if n.name=="board-surface" {
                let p=world.island.convertPosition(hit.worldCoordinates,from:nil)
                return world.square(x:p.x,z:p.z)
            }
            node=n.parent
        }
        return nil
    }
    override func didMoveToWindow() {super.didMoveToWindow();if window==nil {pieceDrag?.cancel()}}
    func firstInputHit(at point:CGPoint)->SCNHitTestResult? {
        hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1,.ignoreHiddenNodes:true]).first
    }
    func refresh(revision:Int) {
        guard lastRevision != revision || lastSelection != world?.selectedSquare else{return}
        lastRevision=revision;lastSelection=world?.selectedSquare
        guard !refreshPending else{return};refreshPending=true
        DispatchQueue.main.async{[weak self] in
            guard let self=self else{return};self.refreshPending=false;self.layoutBoard()
        }
    }
    func normalizedCloudPoint(_ point:CGPoint)->SIMD2<Float> {
        guard let window=window else{return SIMD2(0.5,0.75)}
        let p=convert(point,to:window)
        return SIMD2(Float(p.x/window.bounds.width),Float(p.y/window.bounds.height))
    }
    private func projectBoardPoint(_ point:SCNVector3)->CGPoint {
        guard let world=world,bounds.width>0,bounds.height>0 else{return .zero}
        // SceneKit's projectPoint can use the previous render's projection just
        // after layout. Input targets use the shared camera immediately instead.
        let p=SIMD3<Float>(point.x,point.y,point.z)*world.island.simdScale+world.boardAnchor.simdPosition-SceneComposition.eye
        let aspect=Float(bounds.width/bounds.height)
        let tangent=SceneComposition.tangentHalfFOV(aspect:aspect)
        let depth=simd_dot(p,SceneComposition.forward)
        return CGPoint(x:CGFloat(0.5+p.x/(2*depth*tangent*aspect))*bounds.width,
                       y:CGFloat(0.5-simd_dot(p,SceneComposition.up)/(2*depth*tangent))*bounds.height)
    }
    func updateAccessibility() {
        guard !concealed else {accessibilityElements=[];return}
        guard let world=world else{return}
        var elements=[UIAccessibilityElement]()
        for rank in 1...world.dimensions.rows { for file in 0..<world.dimensions.columns {
            let sq="\(UnicodeScalar(file+97)!)\(rank)",p=world.position(sq)
            let symbol=world.symbols[sq]
            let touchPoint=SCNVector3(p.x,p.y+(symbol == nil ? 0:(symbol?.lowercased()=="p" ? 0.32:0.40)),p.z)
            let point=projectBoardPoint(touchPoint)
            let e=BoardAccessibilityElement(accessibilityContainer:self)
            let names:[String:String]=["p":"pawn","r":"rook","n":"knight","b":"bishop","q":"queen","k":"king"]
            e.accessibilityLabel="\(sq), \(symbol.map{($0.isUppercase ? "white ":"black ")+(names[$0.lowercased()] ?? "piece")} ?? "empty")"
            e.accessibilityIdentifier="square-\(sq)";e.accessibilityTraits = world.selectedSquare == sq ? [.button,.selected]:.button
            e.accessibilityFrameInContainerSpace=CGRect(x:CGFloat(point.x)-16,y:CGFloat(point.y)-16,width:32,height:32)
            e.activate={world.onSquare?(sq)};elements.append(e)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cloud-validation") {
                let plane=UIAccessibilityElement(accessibilityContainer:self),centre=projectBoardPoint(p)
                plane.accessibilityIdentifier="board-plane-\(sq)";plane.accessibilityLabel="Board plane \(sq)"
                plane.accessibilityFrameInContainerSpace=CGRect(x:centre.x-4,y:centre.y-4,width:8,height:8)
                elements.append(plane)
            }
            #endif
        }}
        let cloud=BoardAccessibilityElement(accessibilityContainer:self)
        let frontEdge=projectBoardPoint(SCNVector3(0,-0.31,Float(world.dimensions.rows)/2+0.18))
        let cloudY=min(Float(bounds.height)*0.84,max(Float(bounds.height)*0.77,Float(frontEdge.y)+24))
        let centre=SCNVector3(Float(bounds.width)*0.18,cloudY,0)
        cloud.accessibilityLabel="Cloud";cloud.accessibilityIdentifier="cloud-front";cloud.accessibilityTraits = .button
        cloud.accessibilityValue=world.cloudField.interactionCount>0 ? "Stirred":"Calm"
        cloud.accessibilityFrameInContainerSpace=CGRect(x:CGFloat(centre.x)-28,y:CGFloat(centre.y)-18,width:56,height:36)
        cloud.activate={ [weak self,weak world] in
            guard let self=self,let world=world else{return}
            if world.cloudField.begin(at:self.normalizedCloudPoint(CGPoint(x:CGFloat(centre.x),y:CGFloat(centre.y)))) {
                world.cloudField.drag(SIMD2(0.08,0))
                let interaction=world.cloudField.interactionCount
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4){world.cloudField.end(interaction:interaction)}
            }
        }
        elements.append(cloud)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            let drag=DragAccessibilityElement(accessibilityContainer:self);drag.controller=pieceDrag
            drag.accessibilityIdentifier="piece-drag";drag.accessibilityLabel="Piece drag"
            drag.accessibilityFrameInContainerSpace=CGRect(x:2,y:1,width:1,height:1);elements.append(drag)
            let effects=EffectAccessibilityElement(accessibilityContainer:self);effects.world=world
            effects.accessibilityIdentifier="piece-effects";effects.accessibilityLabel="Piece effects"
            effects.accessibilityFrameInContainerSpace=CGRect(x:1,y:1,width:1,height:1);elements.append(effects)
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            let quality=MoveQualityAccessibilityElement(accessibilityContainer:self);quality.world=world
            quality.accessibilityIdentifier="move-quality";quality.accessibilityLabel="Move quality"
            let anchor=world.position(world.moveQuality.square)
            let point=projectBoardPoint(SCNVector3(anchor.x+0.24,1.52,anchor.z))
            quality.accessibilityFrameInContainerSpace=CGRect(x:point.x-16,y:point.y-16,width:32,height:32)
            elements.append(quality)
        }
        #endif
        accessibilityElements=elements
    }
    override func layoutSubviews() {
        super.layoutSubviews();layoutBoard()
    }
    func layoutBoard() {
        let insets=window?.safeAreaInsets ?? .zero
        if bounds.width>0 && bounds.height>0 && (fittedDimensions != world?.dimensions || fittedViewport != bounds || fittedInsets != insets || fittedClearance != world?.additionalBottomClearance) {
            pieceDrag?.cancel()
            fittedDimensions=world?.dimensions;fittedViewport=bounds;fittedInsets=insets;fittedClearance=world?.additionalBottomClearance ?? 0
            let tangent=SceneComposition.tangentHalfFOV(aspect:Float(bounds.width/bounds.height))
            world?.fitBoard(width:Float(bounds.width),height:Float(bounds.height),top:Float(window?.safeAreaInsets.top ?? 0),bottom:Float(insets.bottom),left:Float(insets.left),right:Float(insets.right))
            world?.camera.camera?.fieldOfView=CGFloat(2*atan(tangent)*180/Float.pi)
        }
        updateAccessibility()
    }
}
struct ChessSceneView:UIViewRepresentable {
    @ObservedObject var world:CloudScene
    var revision:Int
    var concealed:Bool=false
    var paused:Bool=false
    var inputBlocked:Bool=false
    func makeUIView(context:Context)->AccessibleBoardView {
        let view=AccessibleBoardView();view.world=world;view.scene=world.scene;view.pointOfView=world.camera
        view.backgroundColor = .clear;view.isOpaque=false;view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond=30;view.isPlaying=true;view.autoenablesDefaultLighting=false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--atelier-frame-audit") {
            let audit=AtelierFrameAudit();view.atelierFrameAudit=audit;view.delegate=audit
        }
        #endif
        world.prepareForDisplay={ [weak view] in
            guard let view,let scene=view.scene else{return}
            await withCheckedContinuation { continuation in
                view.prepare([scene]) { _ in continuation.resume() }
            }
        }
        view.pieceDrag=PieceDragController(view:view,world:world)
        world.onCancelDrag={ [weak view] in view?.pieceDrag?.cancel() }
        let piece=PieceDragGesture(target:context.coordinator,action:#selector(Coordinator.dragPiece(_:)))
        piece.delegate=context.coordinator
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        let pan=UIPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches=1;pan.delegate=context.coordinator
        tap.require(toFail:pan);tap.require(toFail:piece)
        view.addGestureRecognizer(tap);view.addGestureRecognizer(pan);view.addGestureRecognizer(piece)
        return view
    }
    static func dismantleUIView(_ view:AccessibleBoardView,coordinator:Coordinator) {view.world?.prepareForDisplay=nil;view.pieceDrag?.cancel()}
    func updateUIView(_ view:AccessibleBoardView,context:Context) {
        let hidden=concealed || paused || inputBlocked
        let visibilityChanged=view.concealed != hidden
        view.concealed=hidden;view.isPlaying = !concealed && !paused
        view.accessibilityElementsHidden=hidden;view.isUserInteractionEnabled = !hidden
        // Board targets only change with geometry/position/selection. Avoid
        // rebuilding 64 accessibility elements on every unrelated HUD update.
        view.refresh(revision:revision)
        if visibilityChanged {view.updateAccessibility()}
    }
    func makeCoordinator()->Coordinator {Coordinator(world)}
    class Coordinator:NSObject,UIGestureRecognizerDelegate {
        private var start=SIMD2<Float>.zero
        private var dragging=false
        private var beganInCloud=false
        private var interaction:Int?
        private var pieceSource:String?
        let world:CloudScene
        init(_ world:CloudScene){self.world=world}
        func gestureRecognizer(_ gesture:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
            guard let view=gesture.view as? AccessibleBoardView else{return false}
            if gesture is PieceDragGesture {
                if view.pieceDrag?.isActive==true {return true} // A second finger cancels the grab.
                let square=view.square(at:touch.location(in:view))
                pieceSource=square
                return square.map{world.canDrag?($0)==true} ?? false
            }
            guard gesture is UIPanGestureRecognizer else{return true}
            guard view.pieceDrag?.isActive != true else{return false}
            let point=touch.location(in:view)
            start=view.normalizedCloudPoint(point)
            beganInCloud = !world.reducedMotion && view.firstInputHit(at:point)==nil
            return beganInCloud
        }
        func gestureRecognizerShouldBegin(_ gesture:UIGestureRecognizer)->Bool {
            if gesture is PieceDragGesture {return pieceSource.map{world.canDrag?($0)==true} ?? false}
            return gesture is UIPanGestureRecognizer && beganInCloud && !world.reducedMotion
        }
        @objc func dragPiece(_ gesture:PieceDragGesture) {
            guard let view=gesture.view as? AccessibleBoardView else{return}
            switch gesture.state {
            case .began:
                if let source=pieceSource,view.pieceDrag?.begin(square:source,point:gesture.origin)==true {view.pieceDrag?.update(point:gesture.point)}
            case .changed:view.pieceDrag?.update(point:gesture.point)
            case .ended:view.pieceDrag?.end(point:gesture.point,cancelled:false);view.updateAccessibility()
            case .cancelled,.failed:view.pieceDrag?.cancel(animated:true);view.updateAccessibility()
            default:break
            }
        }
        @objc func pan(_ gesture:UIPanGestureRecognizer) {
            guard let view=gesture.view as? AccessibleBoardView else{return}
            let point=gesture.location(in:view),unit=view.normalizedCloudPoint(point)
            switch gesture.state {
            case .began:
                guard beganInCloud else{return}
                dragging=world.cloudField.begin(at:start)
                if dragging {interaction=world.cloudField.interactionCount;world.cloudField.drag(unit-start)}
            case .changed:
                if dragging {world.cloudField.drag(unit-start)}
            case .ended,.cancelled,.failed:
                if dragging {world.cloudField.end(interaction:interaction);dragging=false;interaction=nil;view.updateAccessibility()}
            default:break
            }
        }
        @objc func tap(_ gesture:UITapGestureRecognizer) {
            guard let view=gesture.view as? AccessibleBoardView else{return}
            let point=gesture.location(in:view)
            guard view.firstInputHit(at:point) != nil else {
                if world.cloudField.begin(at:view.normalizedCloudPoint(point)) {
                    let interaction=world.cloudField.interactionCount
                    world.cloudField.drag(SIMD2(0.015,0.01));view.updateAccessibility()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.35){[weak self] in self?.world.cloudField.end(interaction:interaction)}
                }
                return
            }
            if let square=view.square(at:point) {world.onSquare?(square)}
        }
    }
}

#if DEBUG
/// Measures SceneKit delivery cadence on the actual device. Enabled only by a
/// developer launch argument, and reports separately from the cloud GPU pass.
private final class AtelierFrameAudit:NSObject,SCNSceneRendererDelegate {
    private var last:Double?,warmup=0,intervals:[Double]=[],idleGaps=0
    override init() {
        super.init()
        if let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {try? FileManager.default.removeItem(at:root.appendingPathComponent("atelier-frame-audit.json"))}
    }
    func renderer(_ renderer:SCNSceneRenderer,didRenderScene scene:SCNScene,atTime time:TimeInterval) {
        guard intervals.count<240 else{return}
        let now=CACurrentMediaTime();defer{last=now}
        guard let previous=last else{return}
        let dt=now-previous
        // SCNView is paused while covered by instructions/background. Track and
        // disclose these gaps rather than treating deliberate suspension as FPS.
        if dt>1 {idleGaps+=1;warmup=0;return}
        warmup+=1;guard warmup>15 else{return}
        intervals.append(dt)
        guard intervals.count==120 || intervals.count==240 else{return}
        let samples=intervals.sorted(),n=samples.count
        let report:[String:Any]=["recordedAt":ISO8601DateFormatter().string(from:Date()),"fixtureArguments":ProcessInfo.processInfo.arguments.filter{$0.hasPrefix("--board=") || $0.hasPrefix("--collection-audit=")},"scope":"SceneKit render-callback cadence; not a GPU duration or input-latency measurement","frames":n,"fps":Double(n)/samples.reduce(0,+),"frameMsMedian":samples[n/2]*1000,"frameMsP95":samples[Int(Double(n)*0.95)]*1000,"intervalsOver50ms":samples.filter{$0>0.05}.count,"excludedIdleGaps":idleGaps,"targetFPS":30]
        guard let data=try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted),let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        // The small audit file is written off the render thread.
        DispatchQueue.global(qos:.utility).async {try? data.write(to:root.appendingPathComponent("atelier-frame-audit.json"),options:.atomic)}
    }
}
#endif
