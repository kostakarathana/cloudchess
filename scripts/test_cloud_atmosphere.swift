import Foundation
import simd

@main struct AtmosphereChecks {
    static func main() {
        let field=CloudAtmosphereDynamics()
        let origin=field.frame(at:0)
        precondition(origin.0==0)
        precondition(field.begin(at:SIMD2(0.2,0.8)))
        field.drag(SIMD2(4,-4))
        var active=origin
        for i in 1...240 {active=field.frame(at:Double(i)/60)}
        precondition(simd_length(active.2)<=3.36008 && simd_length(active.2)>3.2)
        precondition(active.1==SIMD2(0.2,0.8) && field.interactionCount==1)
        field.setPaused(true)
        let paused=field.frame(at:5)
        precondition(!field.begin(at:SIMD2(0.8,0.2)))
        field.drag(SIMD2(-1,1))
        for i in 1...120 {
            let next=field.frame(at:5+Double(i))
            precondition(next.0==paused.0 && next.2==paused.2)
        }
        field.setPaused(false);field.end()
        for i in 1...480 {active=field.frame(at:125+Double(i)/60)}
        precondition(simd_length(active.2)<0.0001)
        precondition(active.0>paused.0)
        precondition(field.interactionCount==1)
        // An old tap timer must not cancel the drag that followed it.
        let overlapping=CloudAtmosphereDynamics()
        _ = overlapping.frame(at:0)
        precondition(overlapping.begin(at:SIMD2(0.2,0.8)))
        let oldTap=overlapping.interactionCount
        precondition(overlapping.begin(at:SIMD2(0.4,0.8)))
        let newDrag=overlapping.interactionCount
        overlapping.end(interaction:oldTap)
        overlapping.drag(SIMD2(0.1,0))
        var overlap=overlapping.frame(at:0)
        for i in 1...120 {overlap=overlapping.frame(at:Double(i)/60)}
        precondition(overlap.2.x>0.63,"Stale release interrupted the newer drag")
        overlapping.end(interaction:newDrag)
        overlapping.drag(SIMD2(-0.1,0))
        for i in 121...360 {overlap=overlapping.frame(at:Double(i)/60)}
        precondition(simd_length(overlap.2)<0.0001,"Current release must end interaction")
        precondition(overlapping.begin(at:SIMD2(0.4,0.8)))
        overlapping.setPaused(true);overlapping.setPaused(false)
        overlapping.drag(SIMD2(0.1,0))
        for i in 361...480 {overlap=overlapping.frame(at:Double(i)/60)}
        precondition(simd_length(overlap.2)<0.0001,"Pause must cancel the held finger")
        // Compare the full response to the previous spring, not just its target:
        // normal drags, capped drags, press depth, release and every sample rate.
        var checks=0
        for hz in [30,60,120] {
            for drag in [SIMD2<Float>(0.02,-0.01),SIMD2(0.10,0.08),SIMD2(4,-4)] {
                let doubled=CloudAtmosphereDynamics();var previous=CloudSpring()
                _ = doubled.frame(at:0);precondition(doubled.begin(at:SIMD2(0.5,0.8)))
                previous.aim(SIMD3(0,0,-0.055))
                for i in 1...(hz*6) {
                    if i==hz {doubled.drag(drag);previous.aim(SIMD3(drag.x*3.2,drag.y*3.2,-0.06))}
                    if i==hz*3 {doubled.end();previous.aim(.zero)}
                    previous.advance(1/Double(hz))
                    let sample=doubled.frame(at:Double(i)/Double(hz))
                    precondition(simd_length(sample.2-previous.offset*8)<0.00001,"Touch response must be exactly four times its previous (2× spring) response throughout the gesture and release")
                    checks += 1
                }
            }
        }
        print("Passed \(checks) quadrupled-touch response comparisons")
        print("Passed shared cloud field input, displacement, pause, resume, and release checks")
    }
}
