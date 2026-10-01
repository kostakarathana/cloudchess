import Foundation

@main struct CloudSpringChecks {
    static func main() {
        var checks=0
        func check(_ pass:Bool,_ reason:String) {precondition(pass,reason);checks += 1}
        func length(_ x:SIMD3<Float>)->Float {sqrt(x.x*x.x+x.y*x.y+x.z*x.z)}
        for hz in [30,60,90,120] {
            for direction in [SIMD3<Float>(1,0,0),SIMD3(0,1,0),SIMD3(0,0,-1),SIMD3(1,-1,1)] {
                var spring=CloudSpring();spring.aim(direction*1000)
                check(length(spring.target)<=0.42001,"Drag must remain subtle and bounded")
                for _ in 0..<(hz*4) {
                    spring.advance(1/Double(hz))
                    check(length(spring.offset)<=0.4201,"No overshoot")
                    check(spring.offset.x.isFinite && spring.offset.y.isFinite && spring.offset.z.isFinite,"Finite state")
                }
                check(length(spring.offset)>0.40,"Cloud yields to the drag")
                spring.aim(.zero)
                var previous=length(spring.offset)
                for step in 0..<(hz*6) {
                    spring.advance(1/Double(hz))
                    let current=length(spring.offset)
                    if step>hz/2 {check(current<=previous+0.00001,"Cloud settles without rubbery oscillation")}
                    previous=current
                }
                check(length(spring.offset)<0.0001,"Released cloud recovers")
            }
        }
        var a=CloudSpring(),b=CloudSpring();a.aim(SIMD3(0.3,0,-0.2));b.aim(a.target)
        for _ in 0..<60 {a.advance(1/60)}
        for _ in 0..<120 {b.advance(1/120)}
        check(length(a.offset-b.offset)<0.0002,"Frame-rate independent response")
        let before=a.offset;a.advance(0);a.advance(.nan);a.advance(-1)
        check(a.offset==before,"Paused/invalid time cannot move a cloud")
        let target=a.target;a.aim(SIMD3(.nan,0,0));check(a.target==target,"Invalid input rejected")
        for _ in 0..<10000 {a.aim(SIMD3(0.1,-0.2,0.2));a.advance(1/60)}
        check(length(a.offset)<=0.42001,"Sustained interaction remains stable")
        print("Passed \(checks) cloud dynamics checks")
    }
}
