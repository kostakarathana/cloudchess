import SceneKit
import UIKit

/// Short, bounded effects in board-square coordinates, under the same camera and
/// lights as the pieces. One action animates each burst; no timers or idle emitters.
final class PieceCloudEffects {
    let root=SCNNode()
    private(set) var captureCount=0
    private(set) var mateCount=0
    var activeCount:Int {root.childNodes.count}
    var particleNodeCount:Int {
        var count=0;root.enumerateChildNodes{node,_ in if node.name=="cloud-particle" {count += 1}};return count
    }
    static let captureDuration:TimeInterval=2.15
    static let mateDuration:TimeInterval=3.15
    private static let puffMesh:SCNSphere = {let g=SCNSphere(radius:1);g.segmentCount=16;return g}()
    private static let moteMesh:SCNSphere = {let g=SCNSphere(radius:1);g.segmentCount=8;return g}()
    fileprivate static let mistImage:UIImage = {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:96,height:96),format:format).image {ctx in
            let colors=[UIColor.white.withAlphaComponent(0.8).cgColor,UIColor.white.withAlphaComponent(0.38).cgColor,UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.38,1])!
            ctx.cgContext.drawRadialGradient(gradient,startCenter:CGPoint(x:48,y:48),startRadius:0,endCenter:CGPoint(x:48,y:48),endRadius:48,options:[])
        }
    }()
    fileprivate struct Plume {
        let node:SCNNode
        let angle:Float,radius:Float,height:Float,size:Float,delay:Float,life:Float,twist:Float
        let kind:Int // lit billow, soft mist, pearl
    }
    /// Shared plume builder: a capture/mate burst spreads around one square
    /// (stretch 1,1); the side announcement stretches the same choreography
    /// along the text. `depthless` plumes veil geometry that does not read depth.
    fileprivate static func makePlumes(in parent:SCNNode,counts:[Int],radius:Float,mate:Bool,depthless:Bool=false,renderingOrder:Int=0)->[Plume] {
        let ivory=SCNMaterial();ivory.lightingModel = .lambert
        ivory.diffuse.contents=UIColor(red:0.94,green:0.97,blue:1,alpha:1)
        ivory.roughness.contents=1;ivory.metalness.contents=0
        ivory.writesToDepthBuffer=false;ivory.transparencyMode = .singleLayer
        ivory.shaderModifiers=[.fragment:"""
        #pragma transparent
        #pragma body
        float facing = max(0.0, dot(normalize(_surface.normal), normalize(_surface.view)));
        float softness = smoothstep(0.0, 0.72, facing);
        _output.color.rgb *= softness;
        _output.color.a *= softness;
        """]
        let pearl=SCNMaterial();pearl.lightingModel = .physicallyBased
        pearl.diffuse.contents=UIColor(red:0.86,green:0.94,blue:1,alpha:1)
        pearl.emission.contents=UIColor(red:0.12,green:0.18,blue:0.22,alpha:1)
        pearl.roughness.contents=0.8;pearl.writesToDepthBuffer=false;pearl.transparencyMode = .singleLayer
        let haze=SCNMaterial();haze.lightingModel = .constant
        haze.diffuse.contents=Self.mistImage;haze.isDoubleSided=true;haze.writesToDepthBuffer=false;haze.transparencyMode = .singleLayer
        if depthless {for m in [ivory,pearl,haze] {m.readsFromDepthBuffer=false}}
        let puff=Self.puffMesh.copy() as! SCNGeometry;puff.materials=[ivory]
        let mote=Self.moteMesh.copy() as! SCNGeometry;mote.materials=[pearl]
        let plane=SCNPlane(width:1,height:1);plane.materials=[haze]
        var plumes=[Plume]()
        for kind in 0..<3 {
            for i in 0..<counts[kind] {
                // Golden-angle phyllotaxis prevents artificial spokes and keeps
                // the choreography reproducible, without a random emitter spike.
                let f=Float(i),seed=Float((i*37+kind*13)%101)/100
                let node=SCNNode(geometry:kind==0 ? puff:kind==1 ? plane:mote)
                node.name="cloud-particle";node.categoryBitMask=4;node.castsShadow=false;node.opacity=0;node.renderingOrder=renderingOrder
                if kind==1 {node.constraints=[SCNBillboardConstraint()]}
                parent.addChildNode(node)
                plumes.append(Plume(node:node,angle:f*2.39996+Float(kind)*0.8,
                    radius:0.12+seed*radius,height:0.18+Float((i*17)%23)/23*0.56,
                    size:kind==0 ? 0.16+seed*0.14:kind==1 ? 0.42+seed*0.40:0.012+seed*0.025,
                    delay:kind==2 ? 0.20+seed*0.38:seed*(mate ? 0.30:0.14),
                    life:kind==0 ? 1.05+seed*0.55:kind==1 ? 1.35+seed*0.50:1.20+seed*(mate ? 1.45:0.65),
                    twist:(i%2==0 ? 1:-1)*(0.35+seed*0.6),kind:kind))
            }
        }
        return plumes
    }
    fileprivate static func advance(_ plumes:[Plume],t:Float,mate:Bool,stretch:SIMD2<Float> = SIMD2(1,1),lifeScale:Float=1) {
        for p in plumes {
            let age=t-p.delay,life=p.life*lifeScale
            guard age>0 && age<life else {p.node.opacity=0;continue}
            let u=age/life
            let expansion=1-exp(-age*6)
            let a=p.angle+p.twist*age
            let spread=p.radius*expansion+(p.kind==2 ? age*0.18:age*0.055)
            let lift=p.kind==2 ? age*(mate ? 0.72:0.52):age*0.27
            p.node.position=SCNVector3((cos(a)*spread+0.12*age)*stretch.x,p.height+lift,(sin(a)*spread-0.08*age)*stretch.y)
            let bloom=p.kind==2 ? 1-u*0.8:(0.35+0.85*expansion)*(1+u*0.32)
            let s=p.size*bloom*(mate && p.kind != 2 ? 1.16:1)
            p.node.scale=SCNVector3(s,p.kind==0 ? s*(0.82+u*0.18):s,s)
            let rise=min(1,age/(p.kind==2 ? 0.10:0.13))
            let fade=p.kind==0 ? pow(max(0,1-max(0,u-0.28)/0.72),1.4):pow(max(0,1-u),1.7)
            p.node.opacity=CGFloat(rise*fade*(p.kind==1 ? 0.28:1))
        }
    }
    func clear() {
        for node in root.childNodes {node.removeAllActions();node.removeFromParentNode()}
    }
    func vanish(_ piece:SCNNode,delay:TimeInterval,mate:Bool,reduced:Bool,retainPiece:Bool=false) {
        if mate {mateCount += 1} else {captureCount += 1}
        if root.childNodes.count>=4,let oldest=root.childNodes.first {oldest.removeAllActions();oldest.removeFromParentNode()}
        let burst=SCNNode();burst.name=mate ? "mate-cloud":"capture-cloud"
        burst.position=piece.position;root.addChildNode(burst)
        let shell=piece.clone();shell.name=nil;shell.position=SCNVector3Zero;shell.removeAllActions()
        shell.enumerateChildNodes{node,_ in node.removeAllActions();node.categoryBitMask=4;node.castsShadow=false}
        shell.categoryBitMask=4;shell.castsShadow=false;burst.addChildNode(shell)
        if retainPiece {piece.isHidden=true} else {piece.removeFromParentNode()}
        if reduced {
            shell.runAction(.fadeOut(duration:0.16))
            burst.runAction(.sequence([.wait(duration:0.18),.removeFromParentNode()]))
            return
        }
        let duration=mate ? Self.mateDuration:Self.captureDuration
        let cloud=SCNNode();burst.addChildNode(cloud)
        let plumes=Self.makePlumes(in:cloud,counts:mate ? [26,18,58]:[18,12,34],radius:mate ? 0.75:0.50,mate:mate)
        // Keep the captured silhouette until the attacking piece approaches.
        burst.runAction(.sequence([.wait(duration:delay),.customAction(duration:duration){_,elapsed in
            let t=Float(elapsed)
            let dissolve=min(1,max(0,(t-0.06)/0.24))
            shell.opacity=CGFloat(1-dissolve)
            let squash=1-0.70*dissolve
            shell.scale=SCNVector3(1+0.10*sin(dissolve * .pi),squash,1+0.10*sin(dissolve * .pi))
            shell.position.y=0.16*dissolve
            Self.advance(plumes,t:t,mate:mate)
        },.removeFromParentNode()]))
    }
}

/// One camera-facing badge, cached artwork and bounded actions. No per-frame
/// SwiftUI publication, particle emitter, extra engine request or hit target.
final class MoveQualityEffects {
    let root=SCNNode()
    private(set) var lastQuality="",square="",events=0
    var visible:Bool {!root.childNodes.isEmpty}
    var pending:Bool {visible && lastQuality=="pending"}
    private static var artwork:[String:UIImage]=[:]
    func clear() {root.childNodes.forEach{$0.removeAllActions();$0.removeFromParentNode()}}
    func show(_ quality:MoveQuality?,at position:SCNVector3,square:String,reduced:Bool) {
        clear();self.square=square;lastQuality=quality?.rawValue ?? "pending";events+=1
        let face=SCNPlane(width:0.65,height:0.65),material=SCNMaterial()
        material.lightingModel = .constant;material.diffuse.contents=Self.image(quality)
        material.isDoubleSided=true;material.writesToDepthBuffer=false;material.readsFromDepthBuffer=false
        face.materials=[material]
        let badge=SCNNode(geometry:face);badge.name="move-quality-badge";badge.categoryBitMask=4;badge.castsShadow=false;badge.renderingOrder=900
        badge.constraints=[SCNBillboardConstraint()]
        badge.position=SCNVector3(position.x+0.24,1.52,position.z)
        root.addChildNode(badge)
        if quality==nil {
            if !reduced {badge.runAction(.repeatForever(.sequence([.scale(to:1.07,duration:0.45),.scale(to:0.96,duration:0.45)])))}
            return
        }
        if reduced {badge.runAction(.sequence([.wait(duration:0.85),.fadeOut(duration:0.18),.removeFromParentNode()]))}
        else {
            badge.scale=SCNVector3(0.72,0.72,0.72);badge.opacity=0
            let grow=SCNAction.scale(to:1.08,duration:0.14);grow.timingMode = .easeOut
            let lift=SCNAction.moveBy(x:0,y:0.17,z:0,duration:1.10);lift.timingMode = .easeOut
            badge.runAction(.sequence([.group([.sequence([grow,.scale(to:1,duration:0.12)]),.fadeIn(duration:0.1)]),.group([lift,.sequence([.wait(duration:0.58),.fadeOut(duration:0.32)])]),.removeFromParentNode()]))
        }
        if UIAccessibility.isVoiceOverRunning,let quality {UIAccessibility.post(notification:.announcement,argument:quality.label)}
    }
    private static func image(_ quality:MoveQuality?)->UIImage {
        let key=quality?.rawValue ?? "pending"
        if let image=artwork[key] {return image}
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:128,height:128),format:format).image {context in
            let cg=context.cgContext
            cg.setShadow(offset:CGSize(width:0,height:3),blur:5,color:UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill();UIBezierPath(ovalIn:CGRect(x:7,y:7,width:114,height:114)).fill();cg.setShadow(offset:.zero,blur:0)
            UIColor(rgb:quality?.rgb ?? 0x526D83).setFill();UIBezierPath(ovalIn:CGRect(x:11,y:11,width:106,height:106)).fill()
            if let quality,let text=quality.annotation {
                let attributes:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:57,weight:.heavy),.foregroundColor:UIColor.white]
                let size=(text as NSString).size(withAttributes:attributes)
                (text as NSString).draw(at:CGPoint(x:(128-size.width)/2,y:(128-size.height)/2-1),withAttributes:attributes)
            } else if let quality {
                let icon=UIImage(systemName:quality.symbol,withConfiguration:UIImage.SymbolConfiguration(pointSize:51,weight:.bold))?.withTintColor(.white,renderingMode:.alwaysOriginal)
                icon?.draw(in:CGRect(x:35,y:35,width:58,height:58))
            } else {
                UIColor.white.setFill();for x in [40,64,88] {UIBezierPath(ovalIn:CGRect(x:x-6,y:58,width:12,height:12)).fill()}
            }
        }
        artwork[key]=image;return image
    }
}

/// Sculpted "Playing as White" / "Playing as Black" that rises from the platform
/// at every reveal, holds, and evaporates into a cloud. The two SCNText meshes
/// are cached and prepared before reveal; the node is never pickable (mask 4),
/// casts no shadow and never bumps the board accessibility revision.
final class SideAnnouncement {
    let root=SCNNode()
    private(set) var events=0
    var visible:Bool {!root.childNodes.isEmpty}
    /// Render-cadence hook (seconds of visible animation), set by the scene.
    var interactive:((TimeInterval)->Void)?
    static let labels=["Playing as White","Playing as Black"]
    static let riseDuration=0.45,holdDuration=0.70,evaporateDuration=0.60
    static var duration:TimeInterval {riseDuration+holdDuration+evaporateDuration}
    /// The clip plane hides the part still inside the platform. If it ever
    /// misbehaves on a device, set this false for the scale-from-flat fallback.
    static let usesClipPlane=true
    private static let fontSize:CGFloat=10
    private static var cache:[String:SCNText]=[:]
    private static let cacheLock=NSLock()
    private var materials:[SCNMaterial]=[]
    static func geometry(_ label:String,outline:Bool=false)->SCNText {
        cacheLock.lock();defer{cacheLock.unlock()}
        let key=outline ? label+"|outline":label
        if let g=cache[key] {return g}
        let g=SCNText(string:label as NSString,extrusionDepth:1.2)
        let base=UIFont.systemFont(ofSize:fontSize,weight:.heavy)
        g.font=base.fontDescriptor.withDesign(.rounded).map{UIFont(descriptor:$0,size:fontSize)} ?? base
        g.flatness=0.1;g.chamferRadius=0
        cache[key]=g;return g
    }
    var geometries:[SCNGeometry] {Self.labels.flatMap{[Self.geometry($0),Self.geometry($0,outline:true)]}}
    func clear() {root.childNodes.forEach{$0.removeAllActions();$0.removeFromParentNode()};materials=[]}
    func updateClipPlane(_ plane:SCNVector4) {for m in materials {m.setValue(NSValue(scnVector4:plane),forKey:"clipPlane")}}
    func present(white:Bool,label:String,columns:Int,clipPlane:SCNVector4,delay:TimeInterval,reduced:Bool) {
        if !reduced {interactive?(delay+Self.duration)}
        clear();events+=1
        let body=PieceSculptor.material(PieceSculptor.bodyColor(white:white),roughness:0.42)
        body.clearCoat.contents=0.10;body.clearCoatRoughness.contents=0.42
        let edge=PieceSculptor.material(white ? UIColor(red:0.28,green:0.36,blue:0.43,alpha:1):UIColor(red:0.62,green:0.71,blue:0.77,alpha:1),roughness:0.48)
        // Bold constant-lit outline (dark around ivory, pale around ink) so the
        // letters read over light and dark squares and at night.
        let outline=SCNMaterial();outline.lightingModel = .constant
        outline.diffuse.contents=white ? UIColor(red:0.10,green:0.14,blue:0.20,alpha:1):UIColor(red:0.94,green:0.97,blue:1,alpha:1)
        let clipped=Self.usesClipPlane && !reduced
        for m in [body,edge,outline] {
            m.readsFromDepthBuffer=false;m.writesToDepthBuffer=false
            if clipped {
                m.shaderModifiers=[.fragment:"""
                #pragma arguments
                float4 clipPlane;
                #pragma body
                if (dot(_surface.position, clipPlane.xyz) + clipPlane.w < 0.0) { discard_fragment(); }
                """]
                m.setValue(NSValue(scnVector4:clipPlane),forKey:"clipPlane")
            }
        }
        materials=clipped ? [body,edge,outline]:[]
        let text=Self.geometry(label);text.materials=[body,body,edge]
        // The glyph mesh is centred by an inner child (bottom-centre origin); the
        // outer node carries scale, lean, position and the timeline.
        let glyphs=SCNNode(geometry:text);glyphs.name="side-announcement-glyphs"
        glyphs.categoryBitMask=4;glyphs.castsShadow=false;glyphs.renderingOrder=950
        let (mn,mx)=text.boundingBox
        let width=max(0.001,mx.x-mn.x),height=mx.y-mn.y
        glyphs.position=SCNVector3(-(mn.x+mx.x)/2,-mn.y,-(mn.z+mx.z)/2)
        let node=SCNNode();node.name="side-announcement"
        let stroke=Self.geometry(label,outline:true);stroke.materials=[outline,outline,outline]
        let thickness=0.10*height*0.77   // about 10% of the cap height (bbox includes descenders)
        for i in 0..<8 {
            let a=Float(i)*Float.pi/4
            let rim=SCNNode(geometry:stroke);rim.name="side-announcement-outline"
            rim.categoryBitMask=4;rim.castsShadow=false;rim.renderingOrder=949
            rim.position=SCNVector3(glyphs.position.x+cos(a)*thickness,glyphs.position.y+sin(a)*thickness,glyphs.position.z-0.02)
            node.addChildNode(rim)
        }
        node.addChildNode(glyphs)
        node.categoryBitMask=4;node.castsShadow=false
        let s=0.8*(Float(columns)+0.36)/width
        node.scale=SCNVector3(s,s,s)
        // Faces the stationary camera, leaning about 12.6° back so the extrusion reads as 3D.
        node.eulerAngles.x = -atan2(SceneComposition.eye.y,SceneComposition.eye.z)+0.22
        let rest=SCNVector3(0,0.091+0.28,0.30)
        let start=SCNVector3(0,0.091-height*s,0.30)
        root.addChildNode(node)
        if reduced {
            node.position=rest;node.opacity=0
            node.runAction(.sequence([.wait(duration:delay),.fadeIn(duration:0.15),.wait(duration:0.9),.fadeOut(duration:0.2),.removeFromParentNode()]))
            return
        }
        node.position=clipped ? start:rest
        if !clipped {node.scale=SCNVector3(s,s*0.02,s)}
        node.opacity=clipped ? 1:0
        #if DEBUG
        let tempo=ProcessInfo.processInfo.arguments.contains("--side-slow") ? 6.0:1.0   // screenshot fixture only
        #else
        let tempo=1.0
        #endif
        let rise=Self.riseDuration*tempo,hold=Self.holdDuration*tempo,evaporate=Self.evaporateDuration*tempo
        let halfWidth=0.4*(Float(columns)+0.36)
        var bloomed=false
        let timeline=SCNAction.customAction(duration:Self.duration*tempo) {[weak self] node,elapsed in
            let t=Double(elapsed)
            if t<rise {
                let u=Float(t/rise),e=1-pow(1-u,3)
                if clipped {
                    node.position.y=start.y+(rest.y-start.y)*e
                    let k=s*(0.92+0.08*e);node.scale=SCNVector3(k,k,k)
                } else {
                    node.opacity=CGFloat(min(1,u*4))
                    node.scale=SCNVector3(s,s*(0.02+0.98*e),s)
                }
            } else if t<rise+hold {
                node.position=rest;node.scale=SCNVector3(s,s,s);node.opacity=1
            } else {
                let v=Float(min(1,(t-rise-hold)/evaporate))
                node.opacity=CGFloat(1-v*v*(3-2*v))
                node.position.y=rest.y+0.18*v
                let k=s*(1+0.05*v);node.scale=SCNVector3(k,k,k)
                if !bloomed,let self {bloomed=true;self.bloom(at:rest,halfWidth:halfWidth)}
            }
        }
        node.runAction(.sequence([.wait(duration:delay),timeline,.removeFromParentNode()]))
    }
    private func bloom(at position:SCNVector3,halfWidth:Float) {
        let burst=SCNNode();burst.name="side-cloud";burst.position=position;root.addChildNode(burst)
        let plumes=PieceCloudEffects.makePlumes(in:burst,counts:[30,20,48],radius:0.35,mate:false,depthless:true,renderingOrder:960)
        let stretch=SIMD2<Float>(halfWidth/0.47,0.8)
        burst.runAction(.sequence([.customAction(duration:1.4) {_,elapsed in
            PieceCloudEffects.advance(plumes,t:Float(elapsed),mate:false,stretch:stretch,lifeScale:0.8)
        },.removeFromParentNode()]))
    }
}
