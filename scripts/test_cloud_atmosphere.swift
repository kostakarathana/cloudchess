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
        // Night amount: instant and animated ramps, pause independence, palette and clamping.
        let night=CloudAtmosphereDynamics()
        _ = night.frame(at:0)
        let day=night.appearance
        night.setNight(1,animated:false)
        precondition(night.night==1,"Instant night applies immediately")
        let moon=night.appearance
        precondition(abs(moon.0.x-0.040)<1e-6 && abs(moon.0.y-0.055)<1e-6 && abs(moon.0.z-0.10)<1e-6,"Night ambient palette")
        precondition(abs(moon.1.x-0.20)<1e-6 && abs(moon.1.y-0.25)<1e-6 && abs(moon.1.z-0.37)<1e-6,"Moon-lit palette")
        precondition(moon.0.w==day.0.w && moon.1.w==day.1.w,"Theme flags survive night")
        night.setNight(0,animated:false);precondition(night.night==0 && night.appearance.0==day.0 && night.appearance.1==day.1)
        for hz in [30,60,120] {
            let ramp=CloudAtmosphereDynamics();_ = ramp.frame(at:0)
            ramp.setNight(1,animated:true)
            precondition(ramp.night==0,"Animated ramp waits for the next frame")
            var previous:Float=0,reached:Double?
            for i in 1...(hz*2) {
                let now=Double(i)/Double(hz);_ = ramp.frame(at:now)
                let value=ramp.night
                precondition(value>=previous,"Ramp is monotonic")
                let expected=Float(min(1,max(0,(now-1/Double(hz))/CloudAtmosphereDynamics.nightTransition)))
                let smooth=expected*expected*(3-2*expected)
                precondition(abs(value-smooth)<1e-5,"Smoothstep shape at \(hz) Hz")
                if value>=1 && reached==nil {reached=now}
                previous=value
            }
            precondition(reached != nil && reached!<=1/Double(hz)+CloudAtmosphereDynamics.nightTransition+1e-9,"Ramp completes within 0.5 s")
        }
        // Paused only freezes wind/time; the ramp still completes on frame(at:) calls.
        let pausedRamp=CloudAtmosphereDynamics();_ = pausedRamp.frame(at:0);pausedRamp.setPaused(true)
        pausedRamp.setNight(1,animated:true)
        var frozen=pausedRamp.frame(at:0.5)
        for i in 1...60 {frozen=pausedRamp.frame(at:0.5+Double(i)/60)}
        precondition(pausedRamp.night==1,"Ramp completes while paused");precondition(frozen.0==0,"Pause still freezes wind time")
        // Night never alters wind/touch output.
        let a=CloudAtmosphereDynamics(),b=CloudAtmosphereDynamics()
        _ = a.frame(at:0);_ = b.frame(at:0);b.setNight(1,animated:false)
        precondition(a.begin(at:SIMD2(0.3,0.7)) && b.begin(at:SIMD2(0.3,0.7)));a.drag(SIMD2(0.1,0.05));b.drag(SIMD2(0.1,0.05))
        for i in 1...120 {let x=a.frame(at:Double(i)/60),y=b.frame(at:Double(i)/60);precondition(x.0==y.0 && x.1==y.1 && x.2==y.2,"Night is independent of wind and touch")}
        let clamp=CloudAtmosphereDynamics()
        clamp.setNight(Float.nan,animated:false);precondition(clamp.night==0,"NaN clamps to day")
        clamp.setNight(7,animated:false);precondition(clamp.night==1,"Over-range clamps to night")
        clamp.setNight(-2,animated:false);precondition(clamp.night==0)
        print("Passed night ramp, palette, pause-independence and clamping checks")
        print("Passed shared cloud field input, displacement, pause, resume, and release checks")
    }
}
