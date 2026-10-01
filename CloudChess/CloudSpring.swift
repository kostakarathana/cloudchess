import Foundation

/// A critically damped response: billows yield to airflow, then settle without
/// bouncing like rubber. Fixed substeps make gesture feel independent of frame rate.
struct CloudSpring {
    var offset=SIMD3<Float>.zero
    var velocity=SIMD3<Float>.zero
    var target=SIMD3<Float>.zero
    mutating func advance(_ elapsed:Double) {
        guard elapsed.isFinite,elapsed>0 else{return}
        var remaining=Float(min(elapsed,0.1))
        while remaining>0 {
            let dt=min(remaining,1/240)
            velocity += ((target-offset)*18-velocity*8.8)*dt
            offset += velocity*dt
            remaining -= dt
        }
    }
    mutating func aim(_ value:SIMD3<Float>) {
        guard value.x.isFinite,value.y.isFinite,value.z.isFinite else{return}
        let length=sqrt(value.x*value.x+value.y*value.y+value.z*value.z)
        target=value*min(1,0.42/max(0.0001,length))
    }
}
