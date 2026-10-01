import Foundation
import simd
@main struct PieceDragChecks {
    static func main() {
        var checks=0
        func check(_ value:Bool,_ reason:String) {precondition(value,reason);checks += 1}
        for c in 4...8 {for r in 4...8 {
            let board=BoardDimensions(columns:c,rows:r)!
            for (w,h):(Float,Float) in [(402,874),(375,667),(430,932),(768,1024),(1024,768),(874,402)] {
                let placement=board.fittedPlacement(width:w,height:h),scale=placement.scale,aspect=w/h,tan=SceneComposition.tangentHalfFOV(aspect:aspect)
                for file in 0..<c {for rank in 1...r {
                    let square="\(UnicodeScalar(97+file)!)\(rank)",centre=board.position(square)!
                    for delta:SIMD3<Float> in [.zero,SIMD3(-0.45,0,-0.45),SIMD3(0.45,0,0.45)] {
                        let point=centre+delta,p=point*scale+placement.origin-SceneComposition.eye,depth=simd_dot(p,SceneComposition.forward)
                        let screen=SIMD2(0.5+p.x/(2*depth*tan*aspect),0.5-simd_dot(p,SceneComposition.up)/(2*depth*tan))
                        let restored=SceneComposition.boardPoint(unit:screen,aspect:aspect,scale:scale,origin:placement.origin)!
                        check(simd_distance(point,restored)<0.00003,"Perspective picking must invert projection")
                        check(board.square(x:restored.x,z:restored.z)==square,"Drops must land on the finger's square")
                    }
                }}
            }
        }}
        for hz in [30,60,120] {
            var spring=PieceDragSpring(position:SIMD3(0,0.105,0))
            for i in 1...(hz*15) {
                let t=Float(i)/Float(hz),target=SIMD3(sin(t*5)*4,0.78,cos(t*7)*4)
                spring.advance(target:target,dt:1/Double(hz))
                check(spring.position.x.isFinite && spring.position.y.isFinite && spring.position.z.isFinite,"No unstable positions")
                check(simd_distance(spring.position,target)<0.65,"Responsive bounded following")
                check(abs(spring.tilt.x)<=0.22 && abs(spring.tilt.y)<=0.22,"Tilt stays gentle")
            }
            let target=SIMD3<Float>(2,0.78,-1)
            for _ in 0..<(hz*2) {spring.advance(target:target,dt:1/Double(hz))}
            check(simd_distance(spring.position,target)<0.0001,"Piece settles when the finger stops")
            let before=spring.position
            spring.advance(target:SIMD3(.nan,0,0),dt:1);spring.advance(target:.zero,dt:.nan)
            check(spring.position==before,"Invalid samples cannot poison physics")
            spring.advance(target:SIMD3(-3,0.3,3),dt:10)
            check(spring.position.x.isFinite,"Long frame interruption remains bounded")
            spring.advance(target:target,dt:1/60,reduced:true)
            check(spring.position==target && spring.tilt == .zero && spring.velocity == .zero,"Reduced motion follows directly with no jiggle")
        }
        check(SceneComposition.boardPoint(unit:SIMD2(.nan,0),aspect:1,scale:1)==nil,"Reject invalid pointer")
        check(SceneComposition.boardPoint(unit:.zero,aspect:1,scale:0)==nil,"Reject zero scale")
        print("Passed \(checks) drag physics and perspective drop checks")
    }
}
