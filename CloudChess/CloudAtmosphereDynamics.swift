import Foundation
import simd

/// Shared input for the full-screen cloud volume, independent of board coordinates.
final class CloudAtmosphereDynamics {
    private let lock=NSLock()
    private var paused=false,held=false
    private var last:Double?
    private var time:Float=0
    private var spring=CloudSpring()
    private var point=SIMD2<Float>(0.5,0.75)
    private var count=0
    private var theme:Int=0
    // One night amount shared by the sky and the journey veil. The ramp advances
    // on frame(at:) regardless of pause so an instant switch needs only one draw.
    private var nightTarget:Float=0,nightFrom:Float=0,nightValue:Float=0
    private var nightStart:Double?,nightPending=false
    static let nightTransition:Double=0.5
    func setNight(_ amount:Float,animated:Bool) {
        lock.lock();defer{lock.unlock()}
        let value=max(0,min(1,amount.isFinite ? amount:0))
        nightTarget=value
        if animated && value != nightValue {nightFrom=nightValue;nightPending=true;nightStart=nil}
        else {nightValue=value;nightFrom=value;nightPending=false;nightStart=nil}
    }
    var night:Float {lock.lock();defer{lock.unlock()};return nightValue}
    func setTheme(board:Int,pieces:Int) {
        lock.lock();defer{lock.unlock()}
        theme=(board==1 || pieces==1) ? 1:(pieces==0 ? board:pieces)
    }
    var appearance:(SIMD4<Float>,SIMD4<Float>) {
        lock.lock();defer{lock.unlock()}
        let base=themeAppearance,n=nightValue
        // Moon-lit cloud palette: ambient (0.040,0.055,0.10), lit (0.20,0.25,0.37); .w flags preserved.
        let shadow=SIMD4(base.0.x+(0.040-base.0.x)*n,base.0.y+(0.055-base.0.y)*n,base.0.z+(0.10-base.0.z)*n,base.0.w)
        let light=SIMD4(base.1.x+(0.20-base.1.x)*n,base.1.y+(0.25-base.1.y)*n,base.1.z+(0.37-base.1.z)*n,base.1.w)
        return (shadow,light)
    }
    private var themeAppearance:(SIMD4<Float>,SIMD4<Float>) {
        switch theme {
        case 1:return (SIMD4(0.065,0.105,0.18,1),SIMD4(0.37,0.47,0.62,1))
        case 2:return (SIMD4(0.018,0.032,0.075,2),SIMD4(0.20,0.28,0.43,0))
        case 3:return (SIMD4(0.13,0.38,0.40,3),SIMD4(0.57,0.72,0.64,0))
        case 4:return (SIMD4(0.19,0.30,0.23,4),SIMD4(0.68,0.65,0.41,0))
        case 5:return (SIMD4(0.06,0.075,0.13,2),SIMD4(0.46,0.49,0.59,0))
        case 6:return (SIMD4(0.43,0.24,0.37,6),SIMD4(0.55,0.57,0.51,0))
        case 7:return (SIMD4(0.25,0.24,0.20,7),SIMD4(0.66,0.57,0.40,0))
        case 8:return (SIMD4(0.29,0.39,0.53,8),SIMD4(0.68,0.56,0.37,0))
        case 9:return (SIMD4(0.16,0.10,0.12,9),SIMD4(0.66,0.34,0.20,0))
        case 10:return (SIMD4(0.24,0.40,0.59,10),SIMD4(0.62,0.61,0.43,0))
        case 101:return (SIMD4(0.19,0.11,0.32,11),SIMD4(0.54,0.63,0.54,0))
        case 102:return (SIMD4(0.035,0.17,0.24,12),SIMD4(0.22,0.68,0.63,0))
        case 103:return (SIMD4(0.22,0.055,0.10,9),SIMD4(0.72,0.42,0.22,0))
        case 104:return (SIMD4(0.065,0.085,0.17,2),SIMD4(0.40,0.38,0.57,0))
        case 105:return (SIMD4(0.07,0.22,0.18,4),SIMD4(0.53,0.66,0.40,0))
        case 122:return (SIMD4(0.15,0.035,0.09,13),SIMD4(0.68,0.36,0.18,0))
        case 121:return (SIMD4(0.07,0.035,0.16,13),SIMD4(0.50,0.40,0.68,0))
        default:return (SIMD4(0.30,0.44,0.64,0),SIMD4(0.66,0.53,0.34,0))
        }
    }
    private var footprint=SIMD2<Float>(4.18,4.18)
    private var boardOrigin=SIMD3<Float>.zero
    func setBoardFootprint(_ value:SIMD2<Float>,origin:SIMD3<Float> = .zero) {lock.lock();footprint=value;boardOrigin=origin;lock.unlock()}
    var boardLayout:SIMD4<Float> {lock.lock();defer{lock.unlock()};return SIMD4(footprint.x,footprint.y,boardOrigin.y,boardOrigin.z)}
    var boardFootprint:SIMD2<Float> {lock.lock();defer{lock.unlock()};return footprint}
    var interactionCount:Int {lock.lock();defer{lock.unlock()};return count}
    func setPaused(_ value:Bool) {
        lock.lock();defer{lock.unlock()}
        paused=value
        if value {held=false;spring.target = .zero}
    }
    @discardableResult func begin(at point:SIMD2<Float>)->Bool {
        lock.lock();defer{lock.unlock()}
        guard !paused else{return false}
        self.point=point;held=true;count += 1
        spring.aim(SIMD3(0,0,-0.055));return true
    }
    func drag(_ displacement:SIMD2<Float>) {
        lock.lock();defer{lock.unlock()}
        guard held && !paused else{return}
        spring.aim(SIMD3(displacement.x*3.2,displacement.y*3.2,-0.06))
    }
    func end(interaction:Int?=nil) {
        lock.lock();defer{lock.unlock()}
        // A delayed tap release must never end a newer finger interaction.
        guard interaction == nil || interaction == count else{return}
        held=false;spring.aim(.zero)
    }
    func frame(at now:Double)->(Float,SIMD2<Float>,SIMD3<Float>) {
        lock.lock();defer{lock.unlock()}
        let dt=min(0.05,max(0,now-(last ?? now)));last=now
        if !paused {time += Float(dt);spring.advance(dt)}
        if nightPending {nightStart=now;nightPending=false}
        if let start=nightStart {
            let t=Float(min(1,max(0,(now-start)/Self.nightTransition)))
            let s=t*t*(3-2*t)
            nightValue=nightFrom+(nightTarget-nightFrom)*s
            if t>=1 {nightValue=nightTarget;nightStart=nil}
        }
        // Four times the previous full touch response, including its cap.
        // Keeping the spring unchanged preserves its soft settling and timing.
        return (time,point,spring.offset*8)
    }
}
