import UIKit
import SceneKit
import SwiftUI
import Metal
import CryptoKit

extension UIColor {
    convenience init(rgb:UInt32) {self.init(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)}
}
/// Blender-authored collection meshes, shared physical materials and previews.
/// Legacy builders remain only as a defensive fallback for unavailable resources.
enum CollectionArt {
    private static let textures=NSCache<NSString,UIImage>()
    private static let previews=NSCache<NSString,UIImage>()
    private static let modelLock=NSRecursiveLock()
    private static let previewQueue=DispatchQueue(label:"CloudChess.collectionPreviews",qos:.userInitiated)
    private static var models:[String:SCNNode]=[:]
    private static var order:[String]=[]
    static func tile(_ t:CollectionTheme,light:Bool)->UIImage {
        let key="\(t.id)-\(light)" as NSString
        if let image=textures.object(forKey:key){return image}
        textures.countLimit=32
        let image=AtelierAssets.texture(t.id,light ? "light":"dark") ?? ThemeWorkshop.tile(t,light:light)
        textures.setObject(image,forKey:key,cost:256*256*4);return image
    }
    private static let preparationQueue=DispatchQueue(label:"CloudChess.sceneAssets",qos:.userInitiated)
    /// Populate bounded caches on a worker before attaching nodes to the live
    /// scene. Warm all six types so a later promotion never decodes a mesh on drop.
    static func prepare(board:Int,pieces:Int,dimensions:BoardDimensions) async {
        await withCheckedContinuation { continuation in
            preparationQueue.async {
                autoreleasepool {
                    warmShared(board:board,pieces:pieces)
                    let theme=CollectionTheme.find(board) ?? AtelierAssets.originalTheme
                    _ = AtelierAssets.frame(theme,columns:dimensions.columns,rows:dimensions.rows)
                }
                continuation.resume()
            }
        }
    }
    /// Decode immutable pieces and tile maps while puzzle selection/search runs.
    /// The existing serial asset lane bounds work and owns all cache warming.
    static func prepareShared(board:Int,pieces:Int) async {
        await withCheckedContinuation { continuation in
            preparationQueue.async {
                autoreleasepool {warmShared(board:board,pieces:pieces)}
                continuation.resume()
            }
        }
    }
    private static func warmShared(board:Int,pieces:Int) {
        for symbol in "PNBRQKpnbrqk" {_ = piece(symbol,theme:pieces)}
        let theme=CollectionTheme.find(board) ?? AtelierAssets.originalTheme
        if board != 0 {
            _ = tile(theme,light:true);_ = tile(theme,light:false)
            _ = AtelierAssets.texture(theme.id,"normal");_ = AtelierAssets.texture(theme.id,"rough")
        }
    }
    /// Shared side colors for the sculptures and evaluation display.
    static func pieceColor(white:Bool,theme:Int)->UIColor {
        guard let palette=CollectionTheme.find(theme) else{return PieceSculptor.bodyColor(white:white)}
        return UIColor(rgb:white ? palette.light:palette.dark)
    }
    static func pieceColorName(white:Bool,theme:Int)->String {
        PieceColorNames.side(white:white,theme:theme)
    }
    static func piece(_ symbol:Character,theme:Int)->SCNNode {
        modelLock.lock();defer{modelLock.unlock()}
        let t=CollectionTheme.find(theme) ?? AtelierAssets.originalTheme
        let key="\(theme)-\(symbol)"
        if let model=models[key]{return model.clone()}
        let root=theme==0 ? PieceSculptor.piece(symbol):(AtelierAssets.piece(symbol,theme:t) ?? ThemeWorkshop.piece(symbol,t))
        models[key]=root;order.append(key)
        if order.count>36 {models.removeValue(forKey:order.removeFirst())}
        return root.clone()
    }
    /// Reveal equal amounts of the *visible silhouette*, not empty image margins.
    /// Alpha-area quantiles keep a 2/8 shard reveal at one quarter for every shape.
    static func revealed(_ image:UIImage,count:Int,total:Int,seed:Int)->(UIImage,Double) {
        guard let source=image.cgImage else{return (image,1)}
        let width=source.width,height=source.height
        let info=CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info),let data=context.data else{return (image,1)}
        context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        let bytes=data.bindMemory(to:UInt8.self,capacity:width*height*4)
        var histogram=Array(repeating:0,count:width)
        for y in 0..<height {for x in 0..<width {histogram[x]+=Int(bytes[(y*width+x)*4+3])}}
        let area=histogram.reduce(0,+),owned=min(total,max(0,count))
        var visible=Set<Int>();for i in 0..<owned {visible.insert((i*5+seed)%total)}
        var cumulative=0,revealedArea=0
        for x in 0..<width {
            let bin=min(total-1,(cumulative+histogram[x]/2)*total/max(1,area));cumulative+=histogram[x]
            if visible.contains(bin) {revealedArea+=histogram[x];continue}
            for y in 0..<height {let i=(y*width+x)*4;bytes[i]=0;bytes[i+1]=0;bytes[i+2]=0}
        }
        guard let cg=context.makeImage() else{return (image,1)}
        return (UIImage(cgImage:cg),Double(revealedArea)/Double(max(1,area)))
    }
    static func previewAsync(_ theme:CollectionTheme,kind:CollectibleKind,slot:Int?=nil,count:Int?=nil) async->UIImage {
        await withCheckedContinuation {continuation in
            previewQueue.async {
                let full=preview(theme,kind:kind,slot:slot)
                continuation.resume(returning:count.map{revealed(full,count:$0,total:kind.shardCount,seed:theme.id).0} ?? full)
            }
        }
    }
    #if DEBUG
    @MainActor static func premiumAudit() async {
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("premium-art")
        try? FileManager.default.removeItem(at:directory)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for group in 0..<((CollectionTheme.all.count+4)/5) {
            var images:[(CollectionTheme,UIImage,UIImage)]=[]
            for theme in CollectionTheme.all.dropFirst(group*5).prefix(5) {
                let board=await previewAsync(theme,kind:.board)
                let pieces=await previewAsync(theme,kind:.pieces,slot:-12)
                images.append((theme,board,pieces))
            }
            let f=UIGraphicsImageRendererFormat();f.scale=1
            let sheet=UIGraphicsImageRenderer(size:CGSize(width:1480,height:2000),format:f).image {ctx in
                UIColor(rgb:0xE8EEF4).setFill();ctx.fill(CGRect(x:0,y:0,width:1480,height:2000))
                for (i,item) in images.enumerated() {
                    let y=CGFloat(i)*400
                    item.1.draw(in:CGRect(x:24,y:y+35,width:440,height:357))
                    item.2.draw(in:CGRect(x:474,y:y-4,width:960,height:480))
                    ("\(item.0.rarity.title) · \(item.0.name)" as NSString).draw(at:CGPoint(x:36,y:y+16),withAttributes:[.font:UIFont.systemFont(ofSize:24,weight:.semibold),.foregroundColor:UIColor(rgb:0x243B55)])
                }
            }
            try? sheet.pngData()?.write(to:directory.appendingPathComponent("premium-\(group+1).png"))
        }
        try? Data("complete".utf8).write(to:directory.appendingPathComponent("complete"))
    }
    @MainActor static func audit() async {
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("collection-art-audit")
        try? FileManager.default.removeItem(at:directory)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var rows:[[String:Any]]=[]
        for kind in CollectibleKind.allCases {
            var page:[(CollectionTheme,UIImage)]=[]
            for theme in CollectionTheme.all {
                let start=CFAbsoluteTimeGetCurrent(),image=await previewAsync(theme,kind:kind)
                let data=image.pngData()!,hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                let stages=(0...kind.shardCount).map {count in revealed(image,count:count,total:kind.shardCount,seed:theme.id).1}
                var shardStages:[[Double]]=[]
                for slot in 0..<kind.shardCount {
                    let shard=await previewAsync(theme,kind:kind,slot:slot)
                    shardStages.append((0...kind.shardCount).map {revealed(shard,count:$0,total:kind.shardCount,seed:theme.id).1})
                }
                rows.append(["kind":kind.rawValue,"id":theme.id,"name":theme.name,"hash":hash,"seconds":CFAbsoluteTimeGetCurrent()-start,"revealFractions":stages,"shardRevealFractions":shardStages])
                page.append((theme,image))
                if page.count==25 || theme.id==CollectionTheme.all.last?.id {
                    let format=UIGraphicsImageRendererFormat();format.scale=1
                    let sheet=UIGraphicsImageRenderer(size:CGSize(width:1600,height:1500),format:format).image {context in
                        UIColor(red:0.9,green:0.94,blue:0.96,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1600,height:1500))
                        for (i,item) in page.enumerated() {
                            let x=CGFloat(i%5)*320,y=CGFloat(i/5)*300
                            item.1.draw(in:CGRect(x:x,y:y,width:320,height:260))
                            ("\(item.0.id). \(item.0.name)" as NSString).draw(in:CGRect(x:x+12,y:y+260,width:296,height:32),withAttributes:[.font:UIFont.systemFont(ofSize:17,weight:.medium),.foregroundColor:UIColor.darkGray])
                        }
                    }
                    try? sheet.pngData()?.write(to:directory.appendingPathComponent("\(kind.rawValue)-\(theme.id/25).png"));page=[]
                }
            }
        }
        var proofPage:[(CollectionTheme,UIImage)]=[]
        var modelRows:[[String:Any]]=[]
        for theme in CollectionTheme.all {
            let proof=await previewAsync(theme,kind:.pieces,slot:-12)
            try? proof.pngData()?.write(to:directory.appendingPathComponent("set-full-\(theme.id).png"))
            for symbol in Array("PNBRQKpnbrqk") {
                let model=piece(symbol,theme:theme.id),bounds=model.boundingBox
                modelRows.append(["theme":theme.id,"piece":String(symbol),"asset":model.name ?? "missing","triangles":model.geometry?.elements.reduce(0,{$0+$1.primitiveCount}) ?? 0,"bounds":[bounds.min.x,bounds.min.y,bounds.min.z,bounds.max.x,bounds.max.y,bounds.max.z]])
            }
            proofPage.append((theme,proof))
            if proofPage.count==10 || theme.id==CollectionTheme.all.last!.id {
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let sheet=UIGraphicsImageRenderer(size:CGSize(width:1920,height:2600),format:format).image {context in
                    UIColor(red:0.90,green:0.94,blue:0.96,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1920,height:2600))
                    for (i,item) in proofPage.enumerated() {
                        let x=CGFloat(i%2)*960,y=CGFloat(i/2)*520
                        item.1.draw(in:CGRect(x:x,y:y,width:960,height:480))
                        ("\(item.0.id). \(item.0.name)" as NSString).draw(in:CGRect(x:x+16,y:y+480,width:920,height:36),withAttributes:[.font:UIFont.systemFont(ofSize:24,weight:.medium),.foregroundColor:UIColor.darkGray])
                    }
                }
                try? sheet.pngData()?.write(to:directory.appendingPathComponent("all-pieces-\((theme.id+9)/10).png"));proofPage=[]
            }
        }
        if let data=try? JSONSerialization.data(withJSONObject:modelRows,options:.prettyPrinted) {try? data.write(to:directory.appendingPathComponent("models.json"))}
        if let data=try? JSONSerialization.data(withJSONObject:rows,options:.prettyPrinted) {try? data.write(to:directory.appendingPathComponent("manifest.json"))}
    }
    #endif
    static func preview(_ theme:CollectionTheme,kind:CollectibleKind,slot:Int?=nil)->UIImage {
        let key="\(theme.id)-\(kind.rawValue)-\(slot ?? -1)" as NSString
        if let image=previews.object(forKey:key){return image}
        previews.totalCostLimit=20*1024*1024
        let scene=SCNScene();scene.background.contents=UIColor.clear
        let proof=kind == .pieces && slot == -12
        if kind == .pieces {
            let symbols=Array("PNBRQK")
            if proof {
                for (i,symbol) in Array("PNBRQKpnbrqk").enumerated() {
                    let p=piece(symbol,theme:theme.id);p.position=SCNVector3(Float(i%6)*0.70-1.75,-0.35,i<6 ? 0.75:-0.75);scene.rootNode.addChildNode(p)
                }
            } else if let slot {
                let p=piece(symbols[slot%6],theme:theme.id);p.position.y = -0.52;scene.rootNode.addChildNode(p)
            } else {
                for (i,c) in [Character("N"),"k","Q"].enumerated() {
                    let p=piece(c,theme:theme.id);p.position=SCNVector3(Float(i-1)*0.64,-0.56,Float(i%2)*0.18);scene.rootNode.addChildNode(p)
                }
            }
        } else {
            let count=slot==nil ? 4:1
            for row in 0..<count {for col in 0..<count {
                let m=PieceSculptor.material(.white,roughness:0.4);m.diffuse.contents=tile(theme,light:(row+col+(slot ?? 0))%2==0)
                m.normal.contents=AtelierAssets.texture(theme.id,"normal");m.normal.intensity=0.28
                m.roughness.contents=AtelierAssets.texture(theme.id,"rough")
                let p=PieceSculptor.box(0.53,0.10,0.53,0.012,m,at:SCNVector3((Float(col)-Float(count-1)/2)*0.53,-0.1,(Float(row)-Float(count-1)/2)*0.53));scene.rootNode.addChildNode(p)
            }}
            if let frame=AtelierAssets.frame(theme,columns:count,rows:count) {
                frame.scale=SCNVector3(0.53,0.53,0.53);frame.position.y = -0.04;scene.rootNode.addChildNode(frame)
                let base=PieceSculptor.box(CGFloat(count)*0.53+0.13,0.11,CGFloat(count)*0.53+0.13,0.035,PieceSculptor.material(UIColor(rgb:theme.dark),metal:0.12,roughness:0.32),at:SCNVector3(0,-0.14,0));scene.rootNode.addChildNode(base)
            }
        }
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=kind == .board ? (slot==nil ? 1.6:0.55):(slot==nil ? 1.35:0.90)
        if proof {camera.camera?.orthographicScale=1.40}
        camera.camera?.wantsHDR=true;camera.camera?.exposureOffset = -0.3
        camera.position=SCNVector3(0,proof ? 3.5:(kind == .board ? 3:1.3),4);camera.look(at:SCNVector3Zero);scene.rootNode.addChildNode(camera)
        let sun=SCNNode();sun.light=SCNLight();sun.light?.type = .directional;sun.light?.intensity=800;sun.position=SCNVector3(-3,6,4);sun.look(at:SCNVector3Zero);scene.rootNode.addChildNode(sun)
        let fill=SCNNode();fill.light=SCNLight();fill.light?.type = .ambient;fill.light?.intensity=220;scene.rootNode.addChildNode(fill)
        let environment=UIGraphicsImageRenderer(size:CGSize(width:128,height:64)).image {ctx in
            let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[UIColor.white.cgColor,UIColor(rgb:0x9AB1C9).cgColor,UIColor(rgb:0x37475A).cgColor] as CFArray,locations:[0,0.52,1])!
            ctx.cgContext.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:64),options:[])
        }
        scene.lightingEnvironment.contents=environment;scene.lightingEnvironment.intensity=0.65
        let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil);renderer.scene=scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:proof ? CGSize(width:960,height:480):CGSize(width:320,height:260),antialiasingMode:.multisampling4X)
        previews.setObject(image,forKey:key,cost:proof ? 960*480*4:320*260*4);return image
    }
}

/// Uniform-area reveal cells are stable across launches and monotonically
/// uncovered. Black preserves the alpha silhouette, never a grey placeholder.
struct CollectionPreview:View {
    let theme:CollectionTheme,kind:CollectibleKind,count:Int
    var slot:Int?=nil
    @State private var image:UIImage?
    var body:some View {
        Group {
            if let image {
                Image(uiImage:image).resizable().scaledToFit()
            } else {
                Image(systemName:kind == .board ? "checkerboard.rectangle":"crown.fill")
                    .font(.system(size:30,weight:.light)).foregroundStyle(Color(rgb:0x192E49).opacity(0.14))
                    .frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityHidden(true)
            }
        }.task(id:"\(theme.id)-\(kind.rawValue)-\(slot ?? -1)-\(count)") {
            await Task.yield();guard !Task.isCancelled else{return};image=await CollectionArt.previewAsync(theme,kind:kind,slot:slot,count:count)
        }.accessibilityLabel(count==0 ? "Undiscovered \(kind.rawValue)":"\(theme.name), \(count) of \(kind.shardCount) shards")
    }
}

/// Thirteen deliberately different constructions. The crown is chess notation in
/// silhouette; everything supporting it belongs to the miniature world below it.
enum ThemeWorkshop {
    static func material(_ color:UInt32,metal:CGFloat=0,rough:CGFloat=0.4,glow:CGFloat=0)->SCNMaterial {
        let m=PieceSculptor.material(UIColor(rgb:color),metal:metal,roughness:rough)
        if glow>0 {m.emission.contents=UIColor(rgb:color);m.emission.intensity=glow}
        return m
    }
    static func box(_ root:SCNNode,_ x:CGFloat,_ y:CGFloat,_ z:CGFloat,_ at:SCNVector3,_ m:SCNMaterial,_ bevel:CGFloat=0.012) {
        root.addChildNode(PieceSculptor.box(x,y,z,bevel,m,at:at))
    }
    static func cylinder(_ root:SCNNode,_ radius:CGFloat,_ height:CGFloat,_ y:Float,_ m:SCNMaterial,sides:Int=32) {
        let g=SCNCylinder(radius:radius,height:height);g.radialSegmentCount=sides;g.materials=[m]
        let n=SCNNode(geometry:g);n.position.y=y;root.addChildNode(n)
    }
    static func ring(_ root:SCNNode,_ radius:CGFloat,_ y:Float,_ m:SCNMaterial,tilt:Float=0,thickness:CGFloat=0.014) {
        let g=SCNTorus(ringRadius:radius,pipeRadius:thickness);g.ringSegmentCount=32;g.pipeSegmentCount=6;g.materials=[m]
        let n=SCNNode(geometry:g);n.position.y=y;n.eulerAngles.z=tilt;root.addChildNode(n)
    }
    static func shape(_ points:[CGPoint],depth:CGFloat,m:SCNMaterial)->SCNNode {
        let p=UIBezierPath();p.move(to:points[0]);for q in points.dropFirst(){p.addLine(to:q)};p.close()
        let g=SCNShape(path:p,extrusionDepth:depth);g.chamferRadius=0.012;g.materials=[m];return SCNNode(geometry:g)
    }
    static func crown(_ kind:String,_ m:SCNMaterial)->SCNNode {
        let root=SCNNode();root.name="chess-identity-"+kind
        switch kind {
        case "p":root.addChildNode(PieceSculptor.sphere(0.148,SCNVector3(0,0.09,0),m))
        case "r":
            box(root,0.42,0.11,0.35,SCNVector3(0,0.04,0),m)
            for x:Float in [-0.16,0.16] {for z:Float in [-0.13,0.13] {box(root,0.12,0.16,0.11,SCNVector3(x,0.16,z),m)}}
        case "n":
            let p:[CGPoint]=[.init(x:-0.20,y:-0.16),.init(x:-0.22,y:0.13),.init(x:-0.13,y:0.35),.init(x:-0.075,y:0.31),.init(x:0.015,y:0.38),.init(x:0.07,y:0.24),.init(x:0.28,y:0.11),.init(x:0.28,y:0.015),.init(x:0.20,y:-0.02),.init(x:0.065,y:0.045),.init(x:0.08,y:-0.08),.init(x:0.17,y:-0.16)]
            root.addChildNode(shape(p,depth:0.24,m:m))
            let eye=material(0x151E30,glow:0)
            for z:Float in [-0.129,0.129] {root.addChildNode(PieceSculptor.sphere(0.024,SCNVector3(0.059,0.184,z),eye))}
        case "b":
            root.addChildNode(shape([.init(x:0,y:0.37),.init(x:-0.19,y:0.15),.init(x:-0.18,y:0.035),.init(x:-0.10,y:-0.025),.init(x:0.09,y:-0.025),.init(x:0.19,y:0.065),.init(x:0.17,y:0.17),.init(x:-0.035,y:0.075),.init(x:-0.06,y:0.13),.init(x:0.11,y:0.245)],depth:0.23,m:m))
        case "q":
            root.addChildNode(shape([.init(x:-0.17,y:-0.015),.init(x:0.17,y:-0.015),.init(x:0.265,y:0.25),.init(x:0.15,y:0.15),.init(x:0.13,y:0.30),.init(x:0.065,y:0.18),.init(x:0,y:0.35),.init(x:-0.065,y:0.18),.init(x:-0.13,y:0.30),.init(x:-0.15,y:0.15),.init(x:-0.265,y:0.25)],depth:0.16,m:m))
        default:
            box(root,0.12,0.38,0.13,SCNVector3(0,0.18,0),m)
            box(root,0.40,0.11,0.13,SCNVector3(0,0.23,0),m)
            cylinder(root,0.18,0.07,-0.045,m)
        }
        root.eulerAngles.x = -0.26
        return root
    }
    static func piece(_ symbol:Character,_ t:CollectionTheme)->SCNNode {
        let root=SCNNode(),body=SCNNode(),kind=symbol.lowercased(),white=symbol.isUppercase
        let color=white ? t.light:t.dark
        let m=material(color,metal:[1,7,9,121].contains(t.id) ? 0.48:0.06,rough:[1,3,10].contains(t.id) ? 0.17:0.42)
        m.shaderModifiers=[.fragment:"""
        #pragma body
        float rim=smoothstep(0.45,0.95,1.0-abs(dot(normalize(_surface.normal),normalize(_surface.view))));
        _output.color.rgb=mix(_output.color.rgb, \(white ? "float3(0.15,0.23,0.30)":"float3(0.58,0.70,0.80)"),rim*0.54);
        """]
        let accent=material(t.accent,metal:0.35,rough:0.24,glow:[1,2,9,102,121].contains(t.id) ? 0.3:0)
        let edge=material(white ? t.dark:t.light,rough:0.46)
        // Compact, with the same readable head scale across every architecture.
        let h:Float=kind=="p" ? 0.38:(kind=="r" ? 0.48:0.51)
        body.position.y=0.09;body.eulerAngles.x = -.pi/10
        root.name="world-\(t.family)-\(symbol)"
        switch t.id {
        case 1: // Wet, faceted storm pylons, lightning running through their ribs.
            cylinder(root,0.29,0.09,0.045,edge,sides:6)
            let g=SCNCone(topRadius:0.13,bottomRadius:0.215,height:CGFloat(h));g.radialSegmentCount=6;g.materials=[m]
            let n=SCNNode(geometry:g);n.position.y=h/2;body.addChildNode(n)
            m.clearCoat.contents=1;m.clearCoatRoughness.contents=0.06
            for z:Float in [-0.174,0.174] {
                let bolt=shape([.init(x:0.025,y:0.06),.init(x:-0.07,y:0.23),.init(x:0.005,y:0.23),.init(x:-0.035,y:CGFloat(h-0.01)),.init(x:0.09,y:0.17),.init(x:0.015,y:0.17)],depth:0.008,m:accent)
                bolt.position.z=z;body.addChildNode(bolt)
            }
            for i in 0..<9 {let a=Float(i)*2.399;let drop=PieceSculptor.sphere(0.012,SCNVector3(0.19*cos(a),Float(i%3)*0.085+0.10,0.19*sin(a)),accent,scale:SCNVector3(1,1.8,0.6));body.addChildNode(drop)}
        case 2: // Setback skyscrapers; illuminated windows are real inset geometry.
            box(root,0.56,0.09,0.49,SCNVector3(0,0.045,0),edge)
            box(body,0.39,CGFloat(h)*0.64,0.32,SCNVector3(0,h*0.32,0),m)
            box(body,0.28,CGFloat(h)*0.42,0.25,SCNVector3(-0.025,h*0.80,0),m)
            let unlit=material(white ? 0x48647A:0x0A152A,rough:0.18),lit=material(0xFFD895,glow:0.7)
            for row in 0..<4 {for col in 0..<3 {for z:Float in [-0.166,0.166] {
                box(body,0.043,0.038,0.008,SCNVector3(Float(col-1)*0.099,0.065+Float(row)*0.075,z),(row*3+col+(white ? 0:2))%4==0 ? unlit:lit,0.002)
            }}}
            for x:Float in [-0.203,0.203] {for row in 0..<4 {box(body,0.008,0.035,0.15,SCNVector3(x,0.06+Float(row)*0.078,0),lit,0.001)}}
            box(body,0.055,0.12,0.055,SCNVector3(0.10,h+0.015,-0.05),accent)
        case 3,10,101: // Aquarium, snowglobe and a rare botanical conservatory.
            cylinder(root,0.285,0.095,0.048,m)
            let glass=material(white ? 0xC7F5EE:color,rough:0.09);glass.transparency=0.16;glass.transparencyMode = .singleLayer;glass.isDoubleSided=false;glass.writesToDepthBuffer=false;glass.clearCoat.contents=1
            glass.blendMode = .alpha
            glass.shaderModifiers=[.fragment:"""
            #pragma transparent
            #pragma body
            float edge=pow(1.0-abs(dot(normalize(_surface.normal),normalize(_surface.view))),2.0);
            _output.color.a=0.045+0.24*edge;
            """]
            let shell=PieceSculptor.sphere(0.224,SCNVector3(0,h*0.47,0),glass,scale:SCNVector3(1,h/0.43,1));shell.renderingOrder=10;body.addChildNode(shell)
            cylinder(body,0.195,0.045,0.025,accent)
            if t.id==3 {
                for i in 0..<5 {let a=Float(i)*1.7;let branch=PieceSculptor.sphere(0.03,SCNVector3(cos(a)*0.10,0.105,sin(a)*0.10),accent,scale:SCNVector3(0.7,2.3,0.7));body.addChildNode(branch)}
                let fish=PieceSculptor.sphere(0.051,SCNVector3(0.035,h*0.61,0.05),material(0xFFB96A),scale:SCNVector3(1.4,0.65,0.5));body.addChildNode(fish)
                let fin=SCNPyramid(width:0.07,height:0.075,length:0.025);fin.materials=[accent];let f=SCNNode(geometry:fin);f.position=SCNVector3(-0.045,h*0.61,0.05);f.eulerAngles.z = .pi/2;body.addChildNode(f)
            } else if t.id==10 {
                let ice=SCNPyramid(width:0.18,height:CGFloat(h)*0.65,length:0.18);ice.materials=[m];let n=SCNNode(geometry:ice);n.position.y=h*0.30;body.addChildNode(n)
                for i in 0..<13 {let a=Float(i)*2.399;body.addChildNode(PieceSculptor.sphere(0.012,SCNVector3(cos(a)*0.15,0.08+Float(i%5)*0.048,sin(a)*0.15),material(0xFFFFFF,glow:0.15)))}
            } else {
                cylinder(body,0.025,CGFloat(h)*0.8,h*0.4,accent,sides:8)
                for i in 0..<7 {let a=Float(i)*2.399;let leaf=PieceSculptor.sphere(0.052,SCNVector3(cos(a)*0.095,0.12+Float(i)*0.031,sin(a)*0.095),accent,scale:SCNVector3(1.3,0.40,0.65));leaf.eulerAngles.z=a;body.addChildNode(leaf)}
                for i in 0..<5 {let a=Float(i)*2 * .pi/5;body.addChildNode(PieceSculptor.sphere(0.045,SCNVector3(cos(a)*0.06,h*0.82,sin(a)*0.06),material(0xF9AFCB),scale:SCNVector3(1,0.4,1)))}
                ring(body,0.238,h*0.46,accent,tilt:0.23,thickness:0.009)
                for i in 0..<4 {let a=Float(i) * .pi/2;box(body,0.015,CGFloat(h)*0.75,0.015,SCNVector3(cos(a)*0.20,h*0.48,sin(a)*0.20),accent,0.003)}
            }
            cylinder(body,0.15,0.055,h,m)
        case 4: // Tapered tree trunks, exposed roots and a warm hanging lantern.
            cylinder(root,0.28,0.07,0.04,material(0x735644),sides:12)
            let g=SCNCone(topRadius:0.11,bottomRadius:0.20,height:CGFloat(h));g.radialSegmentCount=7;g.materials=[m];let n=SCNNode(geometry:g);n.position.y=h/2;body.addChildNode(n)
            for i in 0..<5 {let a=Float(i)*1.256;let leaf=PieceSculptor.sphere(0.07,SCNVector3(cos(a)*0.16,h*0.7,sin(a)*0.16),accent,scale:SCNVector3(1,0.40,0.65));leaf.eulerAngles.y=a;body.addChildNode(leaf)}
            let lantern=material(0xFFD08A,glow:0.35);box(body,0.065,0.1,0.065,SCNVector3(0.17,h*0.43,0.07),lantern)
            for x:Float in [-0.07,0.07] {box(body,0.012,CGFloat(h)*0.7,0.013,SCNVector3(x,h*0.4,0.15),edge)}
        case 5: // Lunar habitat: segmented ceramic pod on four landing feet.
            for i in 0..<4 {let a=Float(i) * .pi/2 + .pi/4;box(root,0.12,0.08,0.12,SCNVector3(cos(a)*0.21,0.04,sin(a)*0.21),accent)}
            cylinder(body,0.18,CGFloat(h)*0.85,h*0.46,m,sides:12)
            ring(body,0.182,h*0.30,edge);ring(body,0.182,h*0.68,edge)
            let portal=PieceSculptor.sphere(0.085,SCNVector3(0,h*0.5,0.17),material(0x163449,metal:0.7,rough:0.1),scale:SCNVector3(1,0.65,0.25));body.addChildNode(portal)
            for x:Float in [-0.19,0.19] {box(body,0.055,CGFloat(h)*0.62,0.08,SCNVector3(x,h*0.38,0),m)}
        case 6: // A stacked confection with piped frosting and handmade sprinkles.
            cylinder(root,0.29,0.09,0.045,material(0xC88E5E),sides:24)
            for j in 0..<3 {cylinder(body,CGFloat(0.22-Float(j)*0.036),CGFloat(h)/3,Float(j)*h/3+h/6,j%2==0 ? m:accent);ring(body,CGFloat(0.22-Float(j)*0.036),Float(j+1)*h/3,m,thickness:0.025)}
            for i in 0..<9 {let a=Float(i)*2.399;let s=PieceSculptor.box(0.02,0.055,0.02,0.009,edge,at:SCNVector3(cos(a)*0.16,h*0.63,sin(a)*0.16));s.eulerAngles.z=a;body.addChildNode(s)}
        case 7: // An open cage exposing an escapement, axle and toothed gears.
            cylinder(root,0.28,0.075,0.04,accent,sides:12)
            cylinder(body,0.055,CGFloat(h),h/2,m,sides:12)
            for y:Float in [0.10,h*0.72] {
                cylinder(body,0.17,0.035,y,accent,sides:24)
                for i in 0..<12 {let a=Float(i) * .pi/6;let tooth=PieceSculptor.box(0.055,0.04,0.038,0.003,accent,at:SCNVector3(cos(a)*0.187,y,sin(a)*0.187));tooth.eulerAngles.y = -a;body.addChildNode(tooth)}
            }
            for i in 0..<4 {let a=Float(i) * .pi/2;box(body,0.028,CGFloat(h),0.028,SCNVector3(cos(a)*0.16,h/2,sin(a)*0.16),m)}
            for j in 0..<5 {ring(body,0.078,0.17+Float(j)*0.025,edge,thickness:0.008)}
        case 8: // Paper folds: separated triangular planes, no turned stem.
            box(root,0.52,0.035,0.48,SCNVector3(0,0.02,0),edge,0.001)
            for i in 0..<4 {
                let fold=shape([.init(x:-0.21,y:0),.init(x:0.03,y:CGFloat(h)),.init(x:0.18,y:0.08)],depth:0.009,m:i%2==0 ? m:accent)
                fold.eulerAngles.y=Float(i) * .pi/2;body.addChildNode(fold)
            }
        case 9: // Basalt columns parted by molten seams; a cooled rock crown.
            cylinder(root,0.29,0.085,0.043,m,sides:7)
            cylinder(body,0.12,CGFloat(h)*0.92,h*0.46,accent,sides:7)
            for i in 0..<6 {let a=Float(i) * .pi/3;let g=SCNCylinder(radius:0.078,height:CGFloat(h)*(i%2==0 ? 0.9:0.72));g.radialSegmentCount=5;g.materials=[m];let n=SCNNode(geometry:g);n.position=SCNVector3(cos(a)*0.137,h*0.43,sin(a)*0.137);body.addChildNode(n)}
        case 102: // A coral cathedral: open arching ribs around a luminous pearl.
            cylinder(root,0.28,0.07,0.035,m,sides:9)
            body.addChildNode(PieceSculptor.sphere(0.105,SCNVector3(0,h*0.52,0),accent))
            for i in 0..<6 {let a=Float(i) * .pi/3
                for j in 0..<4 {let y=0.065+Float(j)/3*(h-0.065),r:Float=0.19-0.09*sin(Float(j)/3 * .pi);body.addChildNode(PieceSculptor.sphere(0.05,SCNVector3(cos(a)*r,y,sin(a)*r),m,scale:SCNVector3(0.72,1.55,0.72)))}
                body.addChildNode(PieceSculptor.sphere(0.032,SCNVector3(cos(a)*0.22,h*0.66,sin(a)*0.22),accent))
            }
            ring(body,0.18,h,m,thickness:0.025)
        default: // Legendary orrery: a suspended planet with three intersecting gimbals.
            cylinder(root,0.275,0.065,0.035,m,sides:8)
            cylinder(body,0.042,CGFloat(h),h/2,accent,sides:12)
            body.addChildNode(PieceSculptor.sphere(0.125,SCNVector3(0,h*0.47,0),m))
            for (i,tilt) in [Float(-0.70),0,0.70].enumerated() {ring(body,0.23,h*0.47,accent,tilt:tilt,thickness:0.012);let a=Float(i)*2.1;body.addChildNode(PieceSculptor.sphere(0.044,SCNVector3(cos(a)*0.23,h*0.47+sin(a)*0.11,sin(a)*0.15),material(i==1 ? 0xAAADFF:0xFFC586,metal:0.5,glow:0.3)))}
            for i in 0..<4 {let a=Float(i) * .pi/2;let g=SCNPyramid(width:0.055,height:0.12,length:0.055);g.materials=[accent];let n=SCNNode(geometry:g);n.position=SCNVector3(cos(a)*0.22,0.075,sin(a)*0.22);body.addChildNode(n)}
        }
        let head=crown(kind,m);head.position.y=h+0.025;body.addChildNode(head)
        // Tiny city rooftop windows reinforce the building without changing its crown.
        if t.id==2,kind != "p" {box(head,0.045,0.028,0.01,SCNVector3(0,0.035,0.13),accent,0.002)}
        root.addChildNode(body)
        root.enumerateChildNodes{node,_ in node.castsShadow=true}
        return root
    }
    static func tile(_ t:CollectionTheme,light:Bool)->UIImage {
        let f=UIGraphicsImageRendererFormat();f.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:f).image {ctx in
            let c=ctx.cgContext,accent=UIColor(rgb:t.accent),base=UIColor(rgb:light ? t.light:t.dark)
            base.setFill();c.fill(CGRect(x:0,y:0,width:256,height:256));c.setLineWidth(2)
            func stroke(_ alpha:CGFloat=0.35) {c.setStrokeColor(accent.withAlphaComponent(alpha).cgColor)}
            func line(_ points:[CGPoint]) {c.move(to:points[0]);for p in points.dropFirst(){c.addLine(to:p)};c.strokePath()}
            stroke()
            switch t.id {
            case 1:
                // Wet slate slabs, reflected streaks and one restrained lightning seam.
                for i in 0..<20 {let y=CGFloat(i*13);c.setStrokeColor(UIColor.white.withAlphaComponent(i%4==0 ? 0.10:0.025).cgColor);line([.init(x:0,y:y),.init(x:256,y:y-32)])}
                stroke(0.5);line([.init(x:36,y:0),.init(x:62,y:74),.init(x:47,y:105),.init(x:81,y:172),.init(x:69,y:256)])
            case 2:
                // Paving on light cells, asphalt and lane markings on dark cells.
                if light {c.setStrokeColor(UIColor(rgb:t.dark).withAlphaComponent(0.16).cgColor);for i in 1..<5 {line([.init(x:i*51,y:0),.init(x:i*51,y:256)]);line([.init(x:0,y:i*51),.init(x:256,y:i*51)])}}
                else {c.setLineWidth(3);c.setLineDash(phase:0,lengths:[15,17]);stroke(0.65);line([.init(x:128,y:0),.init(x:128,y:256)]);c.setLineDash(phase:0,lengths:[]);stroke(0.28);for x:CGFloat in [16,240] {line([.init(x:x,y:0),.init(x:x,y:256)])}}
            case 3:
                for i in 0..<9 {let y=CGFloat(i)*32;c.move(to:.init(x:0,y:y));c.addCurve(to:.init(x:256,y:y+12),control1:.init(x:50,y:y-32),control2:.init(x:190,y:y+38));c.strokePath()}
                for i in 0..<7 {let x=CGFloat((i*67)%235),y=CGFloat((i*47)%231);c.strokeEllipse(in:.init(x:x,y:y,width:17,height:17))}
            case 4:
                for i in 0..<14 {let y=CGFloat(i)*20;c.move(to:.init(x:0,y:y));c.addCurve(to:.init(x:256,y:y),control1:.init(x:60,y:y-15),control2:.init(x:180,y:y+20));c.strokePath()}
                c.strokeEllipse(in:.init(x:76,y:71,width:75,height:110));c.strokeEllipse(in:.init(x:94,y:90,width:40,height:72))
            case 5:
                for i in 0..<11 {let x=CGFloat((i*73+19)%230),y=CGFloat((i*47+37)%230),r=CGFloat(8+i%4*5);c.setFillColor(UIColor.black.withAlphaComponent(0.065).cgColor);c.fillEllipse(in:.init(x:x,y:y,width:r*2,height:r*2));c.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor);c.strokeEllipse(in:.init(x:x,y:y,width:r*2,height:r*2))}
                stroke();c.stroke(CGRect(x:8,y:8,width:240,height:240))
            case 6:
                c.setLineWidth(13);stroke(0.3);for i in -4..<10 {line([.init(x:i*48,y:0),.init(x:i*48+256,y:256)])}
                c.setLineWidth(5);c.setStrokeColor(UIColor.white.withAlphaComponent(0.4).cgColor);c.stroke(CGRect(x:10,y:10,width:236,height:236))
            case 7:
                for (x,y,r) in [(70.0,75.0,41.0),(183,172,50)] {c.strokeEllipse(in:.init(x:x-r,y:y-r,width:r*2,height:r*2));c.strokeEllipse(in:.init(x:x-r*0.7,y:y-r*0.7,width:r*1.4,height:r*1.4));for i in 0..<16 {let a=Double(i)*Double.pi/8;line([.init(x:x+cos(a)*r,y:y+sin(a)*r),.init(x:x+cos(a)*(r+9),y:y+sin(a)*(r+9))])}}
            case 8:
                let p=[CGPoint(x:0,y:0),.init(x:256,y:0),.init(x:125,y:134)];c.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor);c.addLines(between:p);c.fillPath();stroke(0.22);line([.init(x:0,y:0),.init(x:256,y:256)]);line([.init(x:256,y:0),.init(x:0,y:256)])
            case 9:
                c.setLineWidth(4);stroke(0.7);line([.init(x:0,y:60),.init(x:69,y:90),.init(x:123,y:46),.init(x:158,y:123),.init(x:256,y:156)]);line([.init(x:69,y:90),.init(x:57,y:171),.init(x:98,y:256)])
            case 10:
                c.setLineWidth(1.7);stroke(0.7);for i in 0..<6 {let a=CGFloat(i)*CGFloat.pi/3;line([.init(x:128,y:128),.init(x:128+88*cos(a),y:128+88*sin(a))]);for r:CGFloat in [38,62] {let x=128+r*cos(a),y=128+r*sin(a);line([.init(x:x+20*cos(a-0.8),y:y+20*sin(a-0.8)),.init(x:x,y:y),.init(x:x+20*cos(a+0.8),y:y+20*sin(a+0.8))])}}
            case 101:
                for i in 0..<8 {let a=CGFloat(i)*CGFloat.pi/4;c.saveGState();c.translateBy(x:128,y:128);c.rotate(by:a);c.strokeEllipse(in:.init(x:-24,y:-104,width:48,height:104));c.restoreGState()}
                c.strokeEllipse(in:.init(x:102,y:102,width:52,height:52))
            case 102:
                for i in 0..<7 {let x=CGFloat(i)*42;c.move(to:.init(x:x,y:256));c.addCurve(to:.init(x:x+20,y:0),control1:.init(x:x-30,y:175),control2:.init(x:x+65,y:80));c.strokePath()}
                for i in 0..<10 {let x=CGFloat((i*71)%240),y=CGFloat((i*43)%240);c.setFillColor(accent.withAlphaComponent(0.45).cgColor);c.fillEllipse(in:.init(x:x,y:y,width:5,height:5))}
            default:
                for a:CGFloat in [0,.pi/3,2 * .pi/3] {c.saveGState();c.translateBy(x:128,y:128);c.rotate(by:a);c.strokeEllipse(in:.init(x:-100,y:-45,width:200,height:90));c.restoreGState()}
                c.setFillColor(accent.withAlphaComponent(0.45).cgColor);c.fillEllipse(in:.init(x:113,y:113,width:30,height:30))
            }
        }
    }
}

/// Blender-authored sculptures. Immutable vertex buffers and four material batches;
/// distance LOD is prepared offline, so equipping a set never tessellates a model.
enum AtelierAssets {
    // Free original stays free and keeps its ivory/ink identity with the new sculpture.
    static let originalTheme=CollectionTheme(id:1,name:"Original",family:"classic",light:0xFAF6EC,dark:0x090D14,accent:0xC3A36D,pattern:1)
    private static let lock=NSRecursiveLock()
    private static let geometries=NSCache<NSString,SCNGeometry>()
    private static let frames=NSCache<NSString,SCNNode>()
    private static let images=NSCache<NSString,UIImage>()
    static func url(_ name:String,_ ext:String)->URL? {
        Bundle.main.url(forResource:name,withExtension:ext,subdirectory:"EngineResources/Atelier")
    }
    static func texture(_ theme:Int,_ name:String)->UIImage? {
        lock.lock();defer{lock.unlock()}
        let key="\(theme)-\(name)" as NSString
        if let value=images.object(forKey:key){return value}
        guard let path=url(key as String,"png"),let source=UIImage(contentsOfFile:path.path) else{return nil}
        let value=source.preparingForDisplay() ?? source
        images.totalCostLimit=32*1024*1024;images.setObject(value,forKey:key,cost:512*512*4);return value
    }
    private static func mesh(_ name:String)->SCNGeometry? {
        lock.lock();defer{lock.unlock()}
        let key=name as NSString
        if let g=geometries.object(forKey:key){return g}
        guard let path=url(name,"ccmesh"),let data=try? Data(contentsOf:path,options:.mappedIfSafe),data.count>=28,
              String(data:data.prefix(4),encoding:.ascii)=="CCA1" else{return nil}
        func integer(_ offset:Int)->Int {data.withUnsafeBytes{Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))}}
        let count=integer(4),sizes=(0..<4).map{integer(8+$0*4)},version=integer(24)
        guard version==1,count>0,count<500_000,sizes.allSatisfy({$0%3==0 && $0<3_000_000}),28+count*24+sizes.reduce(0,+)*4==data.count else{return nil}
        var vertices=data.subdata(in:28..<28+count*24)
        if !name.hasSuffix("-frame") {
            // Non-destructive styling of the authored sculpture. No extra nodes,
            // draw calls, per-frame deformation, or shader-only picking mismatch.
            vertices.withUnsafeMutableBytes {raw in
                for i in 0..<count {
                    let offset=i*24
                    func read(_ component:Int)->Float {raw.loadUnaligned(fromByteOffset:offset+component*4,as:Float.self)}
                    let p=SIMD3(read(0),read(1),read(2)),n=SIMD3(read(3),read(4),read(5))
                    let point=PieceReadability.position(p),normal=PieceReadability.normal(n,atY:p.y)
                    for axis in 0..<3 {
                        raw.storeBytes(of:point[axis],toByteOffset:offset+axis*4,as:Float.self)
                        raw.storeBytes(of:normal[axis],toByteOffset:offset+(axis+3)*4,as:Float.self)
                    }
                }
            }
        }
        let position=SCNGeometrySource(data:vertices,semantic:.vertex,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:24)
        let normal=SCNGeometrySource(data:vertices,semantic:.normal,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:12,dataStride:24)
        var offset=28+count*24,elements:[SCNGeometryElement]=[]
        for size in sizes {
            elements.append(SCNGeometryElement(data:data.subdata(in:offset..<offset+size*4),primitiveType:.triangles,primitiveCount:size/3,bytesPerIndex:4));offset+=size*4
        }
        let geometry=SCNGeometry(sources:[position,normal],elements:elements)
        geometries.totalCostLimit=40*1024*1024;geometries.setObject(geometry,forKey:key,cost:data.count)
        return geometry
    }
    private static func materials(_ theme:CollectionTheme,white:Bool)->[SCNMaterial] {
        let metallic=[1,2,5,7,9,121,122].contains(theme.id)
        let body=PieceSculptor.material(UIColor(rgb:white ? theme.light:theme.dark),metal:metallic ? 0.18:0.035,roughness:0.27)
        body.clearCoat.contents=0.28;body.clearCoatRoughness.contents=0.16
        let inlay=PieceSculptor.material(UIColor(rgb:theme.accent),metal:0.72,roughness:0.26)
        let recess=PieceSculptor.material(UIColor(rgb:white ? theme.dark:0x101723),metal:0.12,roughness:0.40)
        let enamel=PieceSculptor.material(UIColor(rgb:theme.accent),metal:0.15,roughness:0.18)
        enamel.clearCoat.contents=0.65
        // Fine chased details receive the same light as the whole board. No fake
        // screen-space halo, emissive silhouette or transparency on opaque carvings.
        return [body,inlay,recess,enamel]
    }
    static func piece(_ symbol:Character,theme:CollectionTheme)->SCNNode? {
        let name="\(theme.id)-\(symbol.uppercased())"
        guard let source=mesh(name),let geometry=source.copy() as? SCNGeometry else{return nil}
        let m=materials(theme,white:symbol.isUppercase);geometry.materials=m
        if let source=mesh(name+"-lod"),let low=source.copy() as? SCNGeometry {
            low.materials=m;geometry.levelsOfDetail=[SCNLevelOfDetail(geometry:low,screenSpaceRadius:65)]
        }
        let root=SCNNode(geometry:geometry);root.name="atelier-\(name)";root.castsShadow=true
        return root
    }
    static func frame(_ theme:CollectionTheme,columns:Int,rows:Int)->SCNNode? {
        lock.lock();defer{lock.unlock()}
        let key="\(theme.id)-\(theme.light)-\(theme.dark)-\(theme.accent)-\(columns)x\(rows)" as NSString
        if let frame=frames.object(forKey:key){return frame.clone()}
        guard let source=mesh("\(theme.id)-frame"),let geometry=source.copy() as? SCNGeometry else{return nil}
        geometry.materials=materials(theme,white:false)
        let root=SCNNode();root.name="theme-platform"
        for side in 0..<4 {
            let count=side%2==0 ? columns:rows
            for i in 0..<count {
                let node=SCNNode(geometry:geometry),v=Float(i)-Float(count-1)/2
                switch side {
                case 0:node.position=SCNVector3(v,-0.02,Float(rows)/2+0.14)
                case 1:node.position=SCNVector3(Float(columns)/2+0.14,-0.02,-v)
                case 2:node.position=SCNVector3(-v,-0.02,-Float(rows)/2-0.14)
                default:node.position=SCNVector3(-Float(columns)/2-0.14,-0.02,v)
                }
                node.eulerAngles.y=Float(side)*Float.pi/2;root.addChildNode(node)
            }
        }
        let flattened=root.flattenedClone();flattened.name=root.name
        frames.totalCostLimit=20*1024*1024
        let cost=source.elements.reduce(0,{$0+$1.primitiveCount})*2*(columns+rows)*32
        frames.setObject(flattened,forKey:key,cost:cost);return flattened.clone()
    }
}

// Shared color conversion also used by the board and cloud UI.
extension Color {init(rgb:UInt32){self.init(uiColor:UIColor(rgb:rgb))}}
