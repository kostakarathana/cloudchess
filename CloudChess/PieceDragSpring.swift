import Foundation
import simd

/// Bounded damped springs in board-square units. Independent of render cadence.
struct PieceDragSpring {
    private(set) var position:SIMD3<Float>
    private(set) var velocity=SIMD3<Float>.zero
    private(set) var tilt=SIMD2<Float>.zero
    private var tiltVelocity=SIMD2<Float>.zero
    private var elapsed:Float=0
    init(position:SIMD3<Float>) {self.position=position}
    mutating func advance(target:SIMD3<Float>,dt:Double,reduced:Bool=false) {
        guard dt.isFinite,dt>0,target.x.isFinite,target.y.isFinite,target.z.isFinite else{return}
        if reduced {position=target;velocity = .zero;tilt = .zero;tiltVelocity = .zero;return}
        let interval=Float(min(dt,0.05)),steps=max(1,Int(ceil(interval*240))),h=interval/Float(steps)
        for _ in 0..<steps {
            elapsed += h
            // Fast pointer motion must never leave a piece trailing many cells.
            let delta=position-target,lag=simd_length(delta)
            if lag>0.55 {position=target+delta*(0.55/lag)}
            velocity += ((target-position)*420-velocity*34)*h
            let speed=simd_length(velocity)
            if speed>18 {velocity *= 18/speed}
            position += velocity*h
            let aim=SIMD2(max(-0.18,min(0.18,-velocity.z*0.035)),max(-0.18,min(0.18,velocity.x*0.035)))
                + SIMD2(sin(elapsed*3.3),cos(elapsed*2.7))*0.009
            tiltVelocity += ((aim-tilt)*130-tiltVelocity*14)*h
            tilt += tiltVelocity*h
            tilt=simd_clamp(tilt,SIMD2(repeating:-0.22),SIMD2(repeating:0.22))
        }
    }
}
