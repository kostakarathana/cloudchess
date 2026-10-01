import UIKit
import SceneKit

/// Starts on a short hold OR the first intentional movement. A quick tap fails
/// immediately, so the existing tap recognizer remains responsive.
final class PieceDragGesture:UIGestureRecognizer {
    private(set) var origin=CGPoint.zero
    private(set) var point=CGPoint.zero
    private var finger:UITouch?
    private var hold:DispatchWorkItem?
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) {
        guard finger==nil,touches.count==1,let touch=touches.first else {cancel();return}
        finger=touch;origin=touch.location(in:view);point=origin
        let work=DispatchWorkItem{[weak self] in guard let self=self,self.state == .possible else{return};self.state = .began}
        hold=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent) {
        guard let finger=finger,touches.contains(finger) else{return}
        point=finger.location(in:view)
        if state == .possible,hypot(point.x-origin.x,point.y-origin.y)>=5 {hold?.cancel();state = .began}
        else if state == .began || state == .changed {state = .changed}
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent) {
        guard let finger=finger,touches.contains(finger) else{return}
        point=finger.location(in:view);hold?.cancel()
        state = state == .possible ? .failed:.ended
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent) {cancel()}
    private func cancel() {hold?.cancel();state = state == .possible ? .failed:.cancelled}
    override func reset() {hold?.cancel();hold=nil;finger=nil;super.reset()}
}

private final class DragFrameTarget:NSObject {
    weak var owner:PieceDragController?
    @objc func tick(_ link:CADisplayLink) {owner?.tick(link)}
}

final class PieceDragController {
    private weak var view:AccessibleBoardView?
    private weak var world:CloudScene?
    private var link:CADisplayLink?
    private let frameTarget=DragFrameTarget()
    private var lastTime:CFTimeInterval?
    private var node:SCNNode?
    private var source:String?
    private var spring=PieceDragSpring(position:.zero)
    private var target=SIMD3<Float>.zero
    private var offset=SIMD3<Float>.zero
    private var hover:SCNNode?
    var isActive:Bool {source != nil}
    private(set) var beganCount=0
    private(set) var maximumLift:Float=0
    private(set) var maximumTilt:Float=0
    init(view:AccessibleBoardView,world:CloudScene) {self.view=view;self.world=world;frameTarget.owner=self}
    deinit {link?.invalidate()}
    func begin(square:String,point:CGPoint)->Bool {
        guard !isActive,let world=world,let view=view,let piece=world.nodes[square],
              let ground=view.boardPoint(at:point),world.onDragBegin?(square)==true else{return false}
        source=square;node=piece;beganCount += 1
        let start=world.position(square)
        piece.removeAllActions();piece.scale=SCNVector3(1,1,1)
        spring=PieceDragSpring(position:SIMD3(start.x,start.y,start.z))
        offset=SIMD3(start.x-ground.x,0,start.z-ground.z)
        let ring=SCNTorus(ringRadius:0.43,pipeRadius:0.023)
        let material=SCNMaterial();material.lightingModel = .constant
        material.diffuse.contents=UIColor(red:0.30,green:0.60,blue:0.73,alpha:0.85);ring.materials=[material]
        let halo=SCNNode(geometry:ring);halo.categoryBitMask=2;halo.isHidden=true;world.island.addChildNode(halo);hover=halo
        update(point:point)
        let display=CADisplayLink(target:frameTarget,selector:#selector(DragFrameTarget.tick(_:)))
        display.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
        link=display;lastTime=nil;display.add(to:.main,forMode:.common)
        return true
    }
    func update(point:CGPoint) {
        guard isActive,let view=view,let world=world,let p=view.boardPoint(at:point) else{return}
        let halfX=Float(world.dimensions.columns)/2+0.65,halfZ=Float(world.dimensions.rows)/2+0.65
        target=SIMD3(max(-halfX,min(halfX,p.x+offset.x)),world.reducedMotion ? 0.30:0.78,max(-halfZ,min(halfZ,p.z+offset.z)))
        if let square=world.square(x:p.x,z:p.z),let source=source,world.canDrop?(source,square)==true {
            let q=world.position(square);hover?.position=SCNVector3(q.x,0.13,q.z);hover?.isHidden=false
        } else {hover?.isHidden=true}
    }
    fileprivate func tick(_ display:CADisplayLink) {
        guard isActive,let node=node,let world=world else{stop();return}
        let dt=lastTime.map{display.timestamp-$0} ?? 1/60;lastTime=display.timestamp
        spring.advance(target:target,dt:dt,reduced:world.reducedMotion)
        let p=spring.position
        node.position=SCNVector3(p.x,p.y,p.z);node.eulerAngles=SCNVector3(spring.tilt.x,0,spring.tilt.y)
        maximumLift=max(maximumLift,p.y-0.105);maximumTilt=max(maximumTilt,simd_length(spring.tilt))
    }
    func end(point:CGPoint,cancelled:Bool) {
        guard let world=world,let view=view,let source=source,let node=node else{stop();return}
        let p=view.boardPoint(at:point)
        let square=p.flatMap{world.square(x:$0.x,z:$0.z)}
        stop()
        if !cancelled,let square=square,world.onDrop?(source,square)==true {
            settle(node,to:world.position(square),selected:false,animated:!world.reducedMotion)
        } else {settle(node,to:world.position(source),selected:world.selectedSquare==source,animated:!world.reducedMotion)}
    }
    func cancel(animated:Bool=false) {
        let oldNode=node,oldSource=source;stop()
        if let oldNode=oldNode,let oldSource=oldSource,let world=world {
            settle(oldNode,to:world.position(oldSource),selected:world.selectedSquare==oldSource,animated:animated && !world.reducedMotion)
        }
    }
    private func stop() {link?.invalidate();link=nil;lastTime=nil;source=nil;node=nil;hover?.removeFromParentNode();hover=nil}
    private func settle(_ piece:SCNNode,to point:SCNVector3,selected:Bool,animated:Bool) {
        piece.removeAllActions()
        let scale:CGFloat=selected ? 1.06:1
        if !animated {piece.position=point;piece.eulerAngles=SCNVector3Zero;piece.scale=SCNVector3(scale,scale,scale);return}
        let action=SCNAction.group([.move(to:point,duration:0.24),.rotateTo(x:0,y:0,z:0,duration:0.24),.scale(to:scale,duration:0.24)])
        action.timingMode = .easeOut;piece.runAction(action,forKey:"drag-settle")
    }
}
