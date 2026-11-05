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
    /// Raises the SCNView cadence while something visibly moves; the view decays
    /// back to its idle rate 0.8 s after the last request.
    var setInteractive:((Bool)->Void)?
    private var interactionGeneration=0
    func boostRendering(for duration:TimeInterval) {
        interactionGeneration+=1;let generation=interactionGeneration
        setInteractive?(true)
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0,duration)) { [weak self] in
            guard let self,self.interactionGeneration==generation else{return}
            self.setInteractive?(false)
        }
    }
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
    private var nightAmount:Float=0
    private var daySunIntensity:CGFloat=1150
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
    /// Measured HUD edges in view points from the top: the bottom of the header
    /// (score, hearts and challenge cloud) and the top of the bottom controls.
    /// The board, including the crowns, fits between them with a small gap, so
    /// a taller title or bar never overlaps it. Zero means not yet measured.
    private(set) var hudTopEdge:Float=0,hudBottomEdge:Float=0
    var requestLayout:(()->Void)?
    func setHUDEdges(top:Float,bottom:Float) {
        guard top.isFinite,bottom.isFinite,abs(top-hudTopEdge)>0.5 || abs(bottom-hudBottomEdge)>0.5 else{return}
        hudTopEdge=max(0,top);hudBottomEdge=max(0,bottom);requestLayout?()
    }
    func fitBoard(width:Float,height:Float,top:Float,bottom:Float,left:Float=0,right:Float=0) {
        // fittedPlacement reserves 182 pt above and 106 pt below its insets.
        let gap:Float=10
        let measuredTop=hudTopEdge>0 ? hudTopEdge+gap-182:0
        let measuredBottom=hudBottomEdge>0 && hudBottomEdge<height ? height-hudBottomEdge+gap-106:0
        let placement=dimensions.fittedPlacement(width:width,height:height,topInset:max(top,measuredTop),bottomInset:max(bottom+additionalBottomClearance,measuredBottom),leftInset:left,rightInset:right)
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
        cancelSidePulse()
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
        // The original board is a plain porcelain platform: no carved gold frieze.
        if boardTheme==0 {island.childNode(withName:"theme-platform",recursively:false)?.removeFromParentNode()}
    }
    func buildBoard() {
        let side=PieceSculptor.material(boardStyle.side,metal:0.04,roughness:0.43)
        let porcelain=PieceSculptor.material(boardStyle.rim,roughness:0.34)
        // Twice the original depth below the playing surface (0.396 → 0.792).
        let body=PieceSculptor.box(CGFloat(dimensions.columns)+0.36,0.736,CGFloat(dimensions.rows)+0.36,0.10,side,at:SCNVector3(0,-0.333,0))
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
        let nightTheme=[1,2,5,9,101,102,103,104,121,122].contains(pieces==0 ? board:pieces)
        daySunIntensity=nightTheme ? 980:1150;applyNightLighting(animated:false)
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
        let ambient=SCNNode();ambient.name="ambient";ambient.light=SCNLight();ambient.light?.type = .ambient
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
    /// Night touches only the two lights and the environment intensity: camera,
    /// sun direction, shadow, materials and the fit stay exactly as in daylight.
    func setNight(_ amount:Float,animated:Bool) {nightAmount=max(0,min(1,amount.isFinite ? amount:0));applyNightLighting(animated:animated)}
    var night:Float {nightAmount}
    private func applyNightLighting(animated:Bool) {
        guard let sun=scene.rootNode.childNode(withName:"sun",recursively:false)?.light,
              let ambient=scene.rootNode.childNode(withName:"ambient",recursively:false)?.light else{return}
        let n=CGFloat(nightAmount)
        func blend(_ a:(CGFloat,CGFloat,CGFloat),_ b:(CGFloat,CGFloat,CGFloat))->UIColor {UIColor(red:a.0+(b.0-a.0)*n,green:a.1+(b.1-a.1)*n,blue:a.2+(b.2-a.2)*n,alpha:1)}
        SCNTransaction.begin()
        SCNTransaction.animationDuration=animated && !reducedMotion ? 0.5:0
        SCNTransaction.animationTimingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        sun.intensity=daySunIntensity*(1-0.26*n)
        sun.color=blend((1,0.965,0.90),(0.86,0.90,1.0))
        ambient.intensity=180-30*n
        ambient.color=blend((0.76,0.86,1),(0.50,0.62,0.95))
        scene.lightingEnvironment.intensity=0.55-0.25*n
        SCNTransaction.commit()
    }
    func setMotion(_ reduced:Bool) {
        onCancelDrag?()
        reducedMotion=reduced
        // The platform stays level and still; motion controls affect clouds and moves.
        island.removeAllActions();island.position=SCNVector3Zero;island.eulerAngles=SCNVector3Zero
        cloudField.setPaused(reduced)
        island.opacity=1
        cancelSidePulse()
        if reduced {
            pieceEffects.clear();celebration.clear()
            for (square,node) in nodes {
                node.removeAllActions();node.position=position(square);node.eulerAngles=SCNVector3Zero;node.scale=SCNVector3(1,1,1);node.opacity=1
            }
        }
    }
    func display(_ fen:String,move:String?=nil,dimensions:BoardDimensions?=nil,landing:TimeInterval?=nil) {
        onCancelDrag?()
        if move==nil {pieceEffects.clear();moveQuality.clear();cancelSidePulse()}
        let firstPosition = !hasDisplayedPosition
        hasDisplayedPosition=true
        let willRebuild=dimensions.map{$0 != self.dimensions} ?? false
        if let dimensions=dimensions {configureBoard(dimensions)}
        if firstPosition && !willRebuild {applyBoardTheme()}
        let next=Self.decode(fen).filter{self.dimensions.position($0.key) != nil}
        if let move=move,move.count>=4 {
            let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2))
            if let n=nodes.removeValue(forKey:from) {
                let duration=landing ?? moveAnimationDuration
                if let captured=nodes.removeValue(forKey:to) { disappear(captured,animated:true,landing:duration) }
                nodes[to]=n;n.name="piece:\(to)"
                let target=position(to),start=n.position
                n.removeAllActions()
                if !reducedMotion {boostRendering(for:duration+0.3)}
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
    func disappear(_ node:SCNNode,animated:Bool,landing:TimeInterval?=nil) {
        if animated {
            if !reducedMotion {boostRendering(for:(landing ?? moveAnimationDuration)*0.54+PieceCloudEffects.captureDuration)}
            pieceEffects.vanish(node,delay:reducedMotion ? 0:(landing ?? moveAnimationDuration)*0.54,mate:false,reduced:reducedMotion)
        }
        else {node.removeFromParentNode()}
    }
    /// `delay` is the unelapsed landing of the mating move; the dissolve starts
    /// on that beat instead of a second full arc after a move already landed.
    func checkmateKing(white:Bool,delay:TimeInterval?=nil) {
        guard let square=symbols.first(where:{$0.value == (white ? Character("K"):Character("k"))})?.key,let king=nodes[square] else{return}
        let wait=reducedMotion ? 0:(delay ?? moveAnimationDuration)
        if !reducedMotion {boostRendering(for:wait+PieceCloudEffects.mateDuration)}
        pieceEffects.vanish(king,delay:wait,mate:true,reduced:reducedMotion,retainPiece:true)
    }
    /// Eases a rejected preview back toward its origin square over `duration`.
    /// The caller restores the exact position afterwards with `display`.
    func returnPreview(_ move:String,duration:TimeInterval) {
        guard !reducedMotion,move.count>=4 else{return}
        let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2))
        guard let n=nodes[to],nodes[from]==nil else{return}
        onCancelDrag?();marks.childNodes.forEach{$0.removeFromParentNode()}
        n.removeAllActions()
        let back=SCNAction.group([.move(to:position(from),duration:duration),.rotateTo(x:0,y:0,z:0,duration:duration),.scale(to:1,duration:duration)])
        back.timingMode = .easeOut;n.runAction(back,forKey:"preview-return")
        boostRendering(for:duration)
    }
    var matePresentationDuration:TimeInterval {reducedMotion ? 0.18:moveAnimationDuration+PieceCloudEffects.mateDuration}
    /// The hint: the key piece pulses (gently scaling, with a glowing ring) for
    /// `duration`. Reduce Motion keeps only a steady ring for the same time.
    func pulsePiece(at square:String,duration:TimeInterval) {
        guard let node=nodes[square] else{return}
        let material=SCNMaterial();material.lightingModel = .constant
        material.diffuse.contents=UIColor(red:1.0,green:0.80,blue:0.30,alpha:0.85)
        let ring=SCNNode(geometry:SCNTube(innerRadius:0.36,outerRadius:0.46,height:0.012));ring.geometry?.materials=[material]
        let p=position(square);ring.position=SCNVector3(p.x,0.115,p.z);ring.categoryBitMask=2;ring.castsShadow=false;ring.name="hint-pulse"
        marks.addChildNode(ring)
        let beats=max(1,Int(duration.rounded()))
        // SceneKit only advances actions while it renders, so the end of the
        // hint is timed on the main queue (the static Reduce Motion ring has
        // nothing animating to keep the view drawing).
        DispatchQueue.main.asyncAfter(deadline:.now()+duration+0.25) { [weak self, weak ring,weak node] in
            ring?.removeFromParentNode()
            if let node,node.action(forKey:"hint-pulse") != nil {node.removeAction(forKey:"hint-pulse");node.scale=SCNVector3(1,1,1)}
            self?.boostRendering(for:0.1)
        }
        if !reducedMotion {
            boostRendering(for:duration+0.3)
            let beat=SCNAction.sequence([.scale(to:1.16,duration:0.35),.scale(to:1,duration:0.65)]);beat.timingMode = .easeInEaseOut
            node.runAction(.repeat(beat,count:beats),forKey:"hint-pulse")
            let glow=SCNAction.sequence([.group([.scale(to:1.25,duration:0.35),.fadeOpacity(to:1,duration:0.35)]),.group([.scale(to:1,duration:0.65),.fadeOpacity(to:0.45,duration:0.65)])])
            ring.runAction(.sequence([.repeat(glow,count:beats),.fadeOut(duration:0.2),.removeFromParentNode()]))
        }
        let names:[Character:String]=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
        let piece=symbols[square].flatMap{names[Character($0.lowercased())]} ?? "piece"
        UIAccessibility.post(notification:.announcement,argument:"Key piece: \(piece) on \(square)")
    }
    var pulsingPiece:Bool {marks.childNode(withName:"hint-pulse",recursively:false) != nil}
    /// At each reveal the solver's pieces briefly pulse (two gentle beats over a
    /// soft ring) instead of any text. Reduce Motion keeps only the rings, still.
    private(set) var sidePulses=0
    var sidePulsing:Bool {marks.childNode(withName:"side-pulse",recursively:false) != nil}
    private static let sideRingGeometry:SCNGeometry={
        let g=SCNTube(innerRadius:0.33,outerRadius:0.43,height:0.012);let m=SCNMaterial();m.lightingModel = .constant
        m.diffuse.contents=UIColor(red:1.0,green:0.92,blue:0.62,alpha:0.85);m.writesToDepthBuffer=false;g.materials=[m];return g
    }()
    func pulseSide(white:Bool,delay:TimeInterval=0) {
        cancelSidePulse();sidePulses+=1
        let group=SCNNode();group.name="side-pulse";marks.addChildNode(group)
        let duration=1.1
        for (square,node) in nodes where symbols[square]?.isUppercase==white {
            let ring=SCNNode(geometry:Self.sideRingGeometry);let p=position(square)
            ring.position=SCNVector3(p.x,0.112,p.z);ring.categoryBitMask=2;ring.castsShadow=false;ring.opacity=0
            group.addChildNode(ring)
            if reducedMotion {ring.runAction(.sequence([.wait(duration:delay),.fadeOpacity(to:0.8,duration:0),.wait(duration:duration)]))}
            else {
                let beat=SCNAction.sequence([.scale(to:1.13,duration:0.22),.scale(to:1,duration:0.33)]);beat.timingMode = .easeInEaseOut
                node.runAction(.sequence([.wait(duration:delay),.repeat(beat,count:2)]),forKey:"side-pulse")
                let glow=SCNAction.sequence([.fadeOpacity(to:0.9,duration:0.22),.fadeOpacity(to:0.35,duration:0.33)])
                ring.runAction(.sequence([.wait(duration:delay),.repeat(glow,count:2),.fadeOut(duration:0.2)]))
            }
        }
        if !reducedMotion {boostRendering(for:delay+duration+0.3)} else {boostRendering(for:delay+0.1)}
        // Actions only advance while SceneKit renders; time the removal on the main queue.
        DispatchQueue.main.asyncAfter(deadline:.now()+delay+duration+0.25) { [weak self,weak group] in
            guard let group,group.parent != nil else{return}
            self?.cancelSidePulse()
        }
    }
    func cancelSidePulse() {
        for node in nodes.values where node.action(forKey:"side-pulse") != nil {node.removeAction(forKey:"side-pulse");node.scale=SCNVector3(1,1,1)}
        marks.childNodes.filter{$0.name=="side-pulse"}.forEach{$0.removeFromParentNode()}
    }
    /// A flat arrow on the board surface from one square to another, used by
    /// the guided solution. Pieces stand over it; it never takes input.
    private(set) var guideArrow:String?
    func showGuideArrow(_ move:String) {
        clearGuideArrow()
        guard move.count>=4 else{return}
        let from=position(String(move.prefix(2))),to=position(String(move.dropFirst(2).prefix(2)))
        let dx=to.x-from.x,dz=to.z-from.z,length=sqrt(dx*dx+dz*dz)
        guard length>0.1 else{return}
        let shaft:CGFloat=0.15,head:CGFloat=0.36,width:CGFloat=0.44,start:CGFloat=0.18,end=CGFloat(length)-0.12
        let path=UIBezierPath()
        path.move(to:CGPoint(x:start,y:-shaft/2));path.addLine(to:CGPoint(x:end-head,y:-shaft/2));path.addLine(to:CGPoint(x:end-head,y:-width/2))
        path.addLine(to:CGPoint(x:end,y:0));path.addLine(to:CGPoint(x:end-head,y:width/2));path.addLine(to:CGPoint(x:end-head,y:shaft/2))
        path.addLine(to:CGPoint(x:start,y:shaft/2));path.close()
        let shape=SCNShape(path:path,extrusionDepth:0.01);shape.chamferRadius=0
        let m=SCNMaterial();m.lightingModel = .constant;m.diffuse.contents=UIColor(red:1.0,green:0.74,blue:0.26,alpha:0.92);m.isDoubleSided=true
        shape.materials=[m]
        let arrow=SCNNode(geometry:shape)
        // Shape lies in its XY plane: lay it flat, then point +X from source to target.
        arrow.eulerAngles=SCNVector3(-Float.pi/2,0,0)
        let holder=SCNNode();holder.name="guide-arrow";holder.position=SCNVector3(from.x,0.118,from.z)
        holder.eulerAngles.y=atan2(-dz,dx);holder.addChildNode(arrow)
        holder.categoryBitMask=2;arrow.categoryBitMask=2;arrow.castsShadow=false
        marks.addChildNode(holder);guideArrow=move
        if !reducedMotion {
            holder.opacity=0.55
            holder.runAction(.repeatForever(.sequence([.fadeOpacity(to:1,duration:0.6),.fadeOpacity(to:0.55,duration:0.6)])),forKey:"guide-pulse")
            boostRendering(for:1.3)
        }
        UIAccessibility.post(notification:.announcement,argument:"Move from \(move.prefix(2)) to \(move.dropFirst(2).prefix(2))")
    }
    func clearGuideArrow() {
        marks.childNodes.filter{$0.name=="guide-arrow"}.forEach{$0.removeFromParentNode()};guideArrow=nil
    }
    /// Picking up or selecting a piece ends the hint pulse at once.
    func cancelHintPulse() {
        for node in nodes.values where node.action(forKey:"hint-pulse") != nil {node.removeAction(forKey:"hint-pulse");node.scale=SCNVector3(1,1,1)}
        marks.childNode(withName:"hint-pulse",recursively:false)?.removeFromParentNode()
    }
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
    // Marker resources are immutable and shared by every pickup; only the
    // small nodes are created per selection.
    private static let markerGlow:SCNMaterial={let m=PieceSculptor.material(UIColor(red:0.42,green:0.77,blue:0.87,alpha:1),metal:0.2,roughness:0.4);m.lightingModel = .constant;return m}()
    private static let captureRing:SCNGeometry={let g=SCNTorus(ringRadius:0.39,pipeRadius:0.034);g.materials=[markerGlow];return g}()
    private static let destinationDisc:SCNGeometry={let g=SCNSphere(radius:0.105);g.segmentCount=24;g.materials=[markerGlow];return g}()
    private static let selectionRing:SCNGeometry={let g=SCNTorus(ringRadius:0.37,pipeRadius:0.025);let m=SCNMaterial();m.lightingModel = .constant;m.diffuse.contents=UIColor(red:0.30,green:0.52,blue:0.66,alpha:1);g.materials=[m];return g}()
    private static let lastMoveTile:SCNGeometry={let g=SCNBox(width:0.96,height:0.009,length:0.96,chamferRadius:0.035);let m=SCNMaterial();m.diffuse.contents=UIColor(red:0.64,green:0.78,blue:0.86,alpha:0.35);m.lightingModel = .constant;g.materials=[m];return g}()
    func mark(selected:String?,legal:[String],last:String?) {
        selectedSquare=selected
        // The guide arrow and the side pulse outlive selection marks.
        marks.childNodes.filter{$0.name != "guide-arrow" && $0.name != "side-pulse"}.forEach{$0.removeFromParentNode()}
        for (sq,n) in nodes { n.removeAction(forKey:"select");if !n.hasActions {n.position=position(sq);n.scale=SCNVector3(1,1,1)} }
        if let last=last,last.count>=4 {
            for s in [String(last.prefix(2)),String(last.dropFirst(2).prefix(2))] {
                let p=position(s)
                let n=SCNNode(geometry:Self.lastMoveTile);n.position=SCNVector3(p.x,0.097,p.z);marks.addChildNode(n)
            }
        }
        if let s=selected {
            let p=position(s)
            let n=SCNNode(geometry:Self.selectionRing);n.position=SCNVector3(p.x,0.115,p.z);marks.addChildNode(n)
            if let piece=nodes[s] { piece.runAction(.scale(to:1.06,duration:reducedMotion ? 0:0.18),forKey:"select") }
        }
        for sq in Set(legal.map{String($0.dropFirst(2).prefix(2))}) {
            let p=position(sq),n:SCNNode
            if symbols[sq] != nil {n=SCNNode(geometry:Self.captureRing)}
            else {n=SCNNode(geometry:Self.destinationDisc);n.scale=SCNVector3(1,0.25,1)}
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
    static let idleFramesPerSecond=30,interactiveFramesPerSecond=60
    private var interactiveDecay:DispatchWorkItem?
    /// 60 fps while a drag or scene animation is active; 30 fps once nothing has
    /// requested it for 0.8 s. Idle cost and the stationary camera are unchanged.
    func setInteractive(_ on:Bool) {
        interactiveDecay?.cancel();interactiveDecay=nil
        if on {if preferredFramesPerSecond != Self.interactiveFramesPerSecond {preferredFramesPerSecond=Self.interactiveFramesPerSecond};return}
        let work=DispatchWorkItem { [weak self] in
            guard let self else{return}
            self.interactiveDecay=nil;self.preferredFramesPerSecond=Self.idleFramesPerSecond
        }
        interactiveDecay=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:work)
    }
    private var lastRevision:Int?
    private var lastSelection:String?
    private var refreshPending=false
    private var fittedDimensions:BoardDimensions?
    private var fittedViewport=CGRect.null
    private var fittedInsets=UIEdgeInsets.zero
    private var fittedClearance:Float=0
    private var fittedHUD:[Float]=[0,0]
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
        if bounds.width>0 && bounds.height>0 && (fittedDimensions != world?.dimensions || fittedViewport != bounds || fittedInsets != insets || fittedClearance != world?.additionalBottomClearance || fittedHUD != [world?.hudTopEdge ?? 0,world?.hudBottomEdge ?? 0]) {
            pieceDrag?.cancel()
            fittedDimensions=world?.dimensions;fittedViewport=bounds;fittedInsets=insets;fittedClearance=world?.additionalBottomClearance ?? 0;fittedHUD=[world?.hudTopEdge ?? 0,world?.hudBottomEdge ?? 0]
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
        view.preferredFramesPerSecond=AccessibleBoardView.idleFramesPerSecond;view.isPlaying=true;view.autoenablesDefaultLighting=false
        world.setInteractive={ [weak view] on in view?.setInteractive(on) }
        world.requestLayout={ [weak view] in view?.layoutBoard() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--atelier-frame-audit") {
            let audit=AtelierFrameAudit();view.atelierFrameAudit=audit;view.delegate=audit
        }
        #endif
        world.prepareForDisplay={ [weak view] in
            guard let view,let scene=view.scene else{return}
            await withCheckedContinuation { continuation in
                view.prepare([scene as Any]) { _ in continuation.resume() }
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
    static func dismantleUIView(_ view:AccessibleBoardView,coordinator:Coordinator) {view.world?.prepareForDisplay=nil;view.world?.setInteractive=nil;view.pieceDrag?.cancel()}
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
