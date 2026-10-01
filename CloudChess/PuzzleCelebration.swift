import SceneKit
import UIKit

/// A single bounded animation drives all ribbons. They launch just OUTSIDE the
/// platform, arc outward, flutter, then fall into the cloud layer and dissolve.
final class PuzzleCelebration {
    let root=SCNNode()
    private(set) var bursts=0
    var count:Int {root.childNodes.count}
    func clear(){root.removeAllActions();root.childNodes.forEach{$0.removeFromParentNode()}}
    func play(in world:CloudScene) {
        clear();bursts+=1
        guard !world.reducedMotion else{return}
        world.scene.rootNode.addChildNode(root)
        let colors:[UIColor]=[.init(red:0.96,green:0.78,blue:0.47,alpha:1),.init(red:0.52,green:0.78,blue:0.79,alpha:1),.init(red:0.83,green:0.69,blue:0.85,alpha:1),.init(red:0.96,green:0.74,blue:0.71,alpha:1),.init(red:0.95,green:0.97,blue:1,alpha:1)]
        let geometries=colors.map {color->SCNGeometry in
            let g=SCNBox(width:0.075,height:0.012,length:0.15,chamferRadius:0.012)
            g.materials=[PieceSculptor.material(color,metal:0.12,roughness:0.48)];return g
        }
        struct Ribbon {let node:SCNNode,origin:SIMD3<Float>,velocity:SIMD3<Float>,delay:Float,phase:Float}
        var ribbons:[Ribbon]=[]
        let scale=world.island.simdScale.x,c=Float(world.dimensions.columns),r=Float(world.dimensions.rows)
        for i in 0..<96 {
            let edge=i%4,t=Float((i*37)%97)/96,phase=Float(i)*2.39996
            let x=edge<2 ? (edge==0 ? -c/2-0.22:c/2+0.22):(t-0.5)*c
            let z=edge>=2 ? (edge==2 ? -r/2-0.22:r/2+0.22):(t-0.5)*r
            let origin=SIMD3<Float>(x,0.20,z)*scale+world.boardAnchor.simdPosition
            let normal=simd_normalize(SIMD3<Float>(x,0,z))
            let speed:Float=0.65+Float((i*17)%19)/18
            let velocity=normal*speed+SIMD3<Float>(sin(phase)*0.24,1.7+Float(i%7)*0.16,cos(phase)*0.22)
            let n=SCNNode(geometry:geometries[i%geometries.count]);n.categoryBitMask=4;n.castsShadow=false;n.opacity=0
            n.simdPosition=origin;root.addChildNode(n)
            ribbons.append(Ribbon(node:n,origin:origin,velocity:velocity,delay:Float(i%5)*0.055,phase:phase))
        }
        let action=SCNAction.customAction(duration:2.7) {_,elapsed in
            for ribbon in ribbons {
                let t=Float(elapsed)-ribbon.delay
                guard t>=0 else{continue}
                let wind=SIMD3<Float>(sin(t*5+ribbon.phase)*0.08*t,0,cos(t*4+ribbon.phase)*0.09*t)
                ribbon.node.simdPosition=ribbon.origin+ribbon.velocity*t+SIMD3<Float>(0,-2.2*t*t,0)+wind
                ribbon.node.eulerAngles=SCNVector3(ribbon.phase+t*4.3,ribbon.phase+t*2.1,t*3.2)
                ribbon.node.opacity=CGFloat(min(1,t*14)*max(0,min(1,(2.4-t)/0.9)))
            }
        }
        root.runAction(.sequence([action,.run{[weak self] _ in self?.clear()}]),forKey:"celebrate")
    }
}

extension CloudScene {
    func puzzleExit(duration requested:TimeInterval?=nil) {
        onCancelDrag?();marks.childNodes.forEach{$0.removeFromParentNode()}
        island.removeAction(forKey:"mistake-shake");island.position=SCNVector3Zero
        island.childNode(withName:"mistake-feedback",recursively:false)?.removeFromParentNode()
        island.removeAction(forKey:"puzzle-transition")
        let duration=reducedMotion ? 0.12:(requested ?? 0.48)
        // Both negative camera-up (screen down) and positive camera-forward
        // (away). Moving toward -z here would cancel the visible downward travel.
        let move=SCNAction.move(to:SCNVector3(0,reducedMotion ? 0:-3.2,reducedMotion ? 0:0.4),duration:duration)
        move.timingMode = .easeIn
        island.runAction(.group([move,.fadeOut(duration:duration)]),forKey:"puzzle-transition")
    }
    func puzzleEntrance(duration requested:TimeInterval?=nil) {
        island.removeAction(forKey:"puzzle-transition")
        island.removeAction(forKey:"mistake-shake")
        island.childNode(withName:"mistake-feedback",recursively:false)?.removeFromParentNode()
        island.opacity=0;island.position=SCNVector3(0,reducedMotion ? 0:-1.5,reducedMotion ? 0:0.2)
        let duration=reducedMotion ? 0.15:(requested ?? 0.65)
        let move=SCNAction.move(to:SCNVector3Zero,duration:duration);move.timingMode = .easeOut
        island.runAction(.group([move,.fadeIn(duration:duration)]),forKey:"puzzle-transition")
        if !reducedMotion {
            // A restrained staggered landing leaves the platform itself level.
            for (i,square) in nodes.keys.sorted().enumerated() {
                guard let n=nodes[square] else{continue}
                let target=position(square);n.position=SCNVector3(target.x,target.y+0.25,target.z);n.opacity=0
                let settle=SCNAction.move(to:target,duration:0.38);settle.timingMode = .easeOut
                n.runAction(.sequence([.wait(duration:Double(i%8)*0.025),.group([settle,.fadeIn(duration:0.30)])]),forKey:"puzzle-arrive")
            }
        }
    }
    func puzzleMistake(at square:String) {
        island.childNode(withName:"mistake-feedback",recursively:false)?.removeFromParentNode()
        let root=SCNNode();root.name="mistake-feedback";island.addChildNode(root)
        let red=UIColor(red:0.86,green:0.13,blue:0.23,alpha:1)
        let wash=SCNBox(width:CGFloat(dimensions.columns)+0.24,height:0.018,length:CGFloat(dimensions.rows)+0.24,chamferRadius:0.04)
        let tint=SCNMaterial();tint.diffuse.contents=red;tint.transparency=0.18
        tint.lightingModel = .constant;tint.writesToDepthBuffer=false;wash.materials=[tint]
        let surface=SCNNode(geometry:wash);surface.position.y=0.108;surface.castsShadow=false;surface.categoryBitMask=2;root.addChildNode(surface)
        let material=SCNMaterial();material.diffuse.contents=red;material.lightingModel = .constant
        let width=CGFloat(dimensions.columns)+0.20,length=CGFloat(dimensions.rows)+0.20
        for edge in 0..<4 {
            let horizontal=edge<2
            let strip=SCNBox(width:horizontal ? width:0.045,height:0.012,length:horizontal ? 0.045:length,chamferRadius:0.006)
            strip.materials=[material]
            let outline=SCNNode(geometry:strip);outline.castsShadow=false;outline.categoryBitMask=2
            outline.position=SCNVector3(horizontal ? 0:Float(width/2)*(edge==2 ? -1:1),0.125,horizontal ? Float(length/2)*(edge==0 ? -1:1):0)
            root.addChildNode(outline)
        }
        let ring=SCNTorus(ringRadius:0.40,pipeRadius:0.038);ring.materials=[material]
        let marker=SCNNode(geometry:ring);marker.position=position(square);marker.position.y=0.14;marker.categoryBitMask=2;root.addChildNode(marker)
        root.runAction(.sequence([.wait(duration:0.20),.fadeOut(duration:0.65),.removeFromParentNode()]))
        // Bounded displacement, no rotation, no persistent drift. The feedback
        // root is independent of move markers so a reply cannot erase the flash.
        island.removeAction(forKey:"mistake-shake")
        if !reducedMotion {
            island.runAction(.sequence([.customAction(duration:0.46) {node,elapsed in
                let t=Float(elapsed)/0.46
                node.position.x=sin(t * .pi * 8)*0.085*pow(1-t,2)
            },.run {node in node.position.x=0}]),forKey:"mistake-shake")
        }
    }
}
