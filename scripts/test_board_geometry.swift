import Foundation
import simd
@main struct BoardGeometryChecks {
    static func main() {
        var checks=0
        func check(_ condition:Bool,_ reason:String){precondition(condition,reason);checks+=1}
        let viewports:[(Float,Float,Float,Float)]=[(402,874,62,34),(375,667,20,0),(430,932,62,34),(768,1024,24,20),(1024,768,24,20),(874,402,0,21),(820,1180,24,20),(1024,1366,24,20),(1366,1024,24,20),(320,740,20,0)]
        for c in 4...8 {for r in 4...8 {
            let board=BoardDimensions(columns:c,rows:r)!
            for white in [true,false] {
            for rank in 1...r {for file in 0..<c {
                let square="\(UnicodeScalar(97+file)!)\(rank)",p=board.position(square,whiteAtBottom:white)!
                check(board.square(x:p.x,z:p.z,whiteAtBottom:white)==square,"Square hit-test round trip")
                for dx:Float in [-0.49,0.49] {for dz:Float in [-0.49,0.49] {check(board.square(x:p.x+dx,z:p.z+dz,whiteAtBottom:white)==square,"Every tile corner maps to that tile")}}
            }}
            let a=board.position("a1",whiteAtBottom:white)!,far=board.position("\(UnicodeScalar(96+c)!)\(r)",whiteAtBottom:white)!
            check(white ? a.z>far.z:a.z<far.z,"Solver's home rank faces the player")
            check(white ? a.x<far.x:a.x>far.x,"Files reverse with ranks, not a mirror")
            for x:Float in [-Float(c)/2-0.01,Float(c)/2+0.01] {check(board.square(x:x,z:0,whiteAtBottom:white)==nil,"Both side borders excluded")}
            for z:Float in [-Float(r)/2-0.01,Float(r)/2+0.01] {check(board.square(x:0,z:z,whiteAtBottom:white)==nil,"Both rank borders excluded")}
            }
            check(board.square(x:Float(c)/2+0.001,z:0)==nil,"Right border is not a phantom square")
            check(board.square(x:0,z:Float(r)/2+0.001)==nil,"Bottom border is not a phantom square")
            check(board.position("a0")==nil && board.position("z9")==nil && board.position("")==nil,"Reject out-of-board coordinates")
            for (w,h,top,originalBottom) in viewports {
                for clearance:Float in (h>600 ? [0,85,140]:[0]) {
                let bottom=originalBottom+clearance
                let edge:Float=6/w
                let placement=board.fittedPlacement(width:w,height:h,topInset:top,bottomInset:bottom),scale=placement.scale
                var minX:Float=1,maxX:Float=0,minY:Float=1,maxY:Float=0
                let tangent=SceneComposition.tangentHalfFOV(aspect:w/h)
                for corner in board.fittingEnvelope {
                    let p=corner*scale+placement.origin-SceneComposition.eye,d=simd_dot(p,SceneComposition.forward)
                    let sx=0.5+p.x/(2*d*tangent*w/h),sy=0.5-simd_dot(p,SceneComposition.up)/(2*d*tangent)
                    minX=min(minX,sx);maxX=max(maxX,sx);minY=min(minY,sy);maxY=max(maxY,sy)
                    check(sx>=edge-0.00001 && sx<=1-edge+0.00001,"Every piece and platform corner fits horizontally")
                    check(sy>=(top+182)/h-0.00001 && sy<=1-(bottom+106)/h+0.00001,"No overlap with top or bottom controls")
                }
                for white in [true,false] {
                    for rank in 1...r {for file in 0..<c {
                        let square="\(UnicodeScalar(97+file)!)\(rank)",local=board.position(square,whiteAtBottom:white)!
                        let world=local*scale+placement.origin-SceneComposition.eye,d=simd_dot(world,SceneComposition.forward)
                        let unit=SIMD2<Float>(0.5+world.x/(2*d*tangent*w/h),0.5-simd_dot(world,SceneComposition.up)/(2*d*tangent))
                        let hit=SceneComposition.boardPoint(unit:unit,aspect:w/h,scale:scale,origin:placement.origin)!
                        check(simd_length(hit-local)<0.0001,"Translated board projection and touch ray agree")
                        check(board.square(x:hit.x,z:hit.z,whiteAtBottom:white)==square,"Touch reaches the right square after layout/orientation changes")
                    }}
                }
                let topLimit=(top+182)/h,bottomLimit=1-(bottom+106)/h
                check(min(minX-edge,1-edge-maxX,minY-topLimit,bottomLimit-maxY)<0.0001,"Fit uses the available screen, not arbitrary small-board scaling")
            }
            }
        }}
        // Screen-width-filling phones and portrait iPads must actually reach the
        // small gutter; merely staying inside the screen is not sufficient.
        for (w,h,t,b):(Float,Float,Float,Float) in [(402,874,62,34),(430,932,62,34),(1024,1366,24,20)] {
            let board=BoardDimensions.standard,placement=board.fittedPlacement(width:w,height:h,topInset:t,bottomInset:b),scale=placement.scale
            let tangent=SceneComposition.tangentHalfFOV(aspect:w/h)
            let edge=board.fittingEnvelope.map {corner -> Float in
                let p=corner*scale+placement.origin-SceneComposition.eye,d=simd_dot(p,SceneComposition.forward)
                return (0.5+p.x/(2*d*tangent*w/h))*w
            }.min()!
            check(abs(edge-6)<0.05,"Board expands to a six-point gutter when height allows")
        }
        let sideSafe=BoardDimensions.standard.fittedPlacement(width:874,height:402,leftInset:62,rightInset:20)
        for corner in BoardDimensions.standard.fittingEnvelope {
            let p=corner*sideSafe.scale+sideSafe.origin-SceneComposition.eye,d=simd_dot(p,SceneComposition.forward),t=SceneComposition.tangentHalfFOV(aspect:874/402)
            let sx=(0.5+p.x/(2*d*t*874/402))*874
            check(sx>=68-0.01 && sx<=848+0.01,"Side safe areas are respected")
        }
        let small=BoardDimensions(columns:5,rows:5)!.fittedScale(width:402,height:874)
        let large=BoardDimensions.standard.fittedScale(width:402,height:874)
        check(small>large*1.45,"Small-board squares visibly enlarge")
        check(BoardDimensions(columns:3,rows:8)==nil && BoardDimensions(columns:8,rows:9)==nil,"Unsupported sizes are rejected")
        print("Passed \(checks) board layout/mapping checks across 25 shapes and 10 viewports")
    }
}
