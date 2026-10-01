import Foundation
import simd

/// One world-space camera and sun for both SceneKit and the Metal atmosphere.
/// A long camera distance gives gentle perspective, not a dramatic wide angle.
enum SceneComposition {
    static let eye=SIMD3<Float>(0,24,12)
    static let forward=simd_normalize(-eye)
    static let right=SIMD3<Float>(1,0,0)
    static let up=simd_normalize(simd_cross(right,forward))
    static let sun=simd_normalize(SIMD3<Float>(-8,12,-6))
    static let horizontalHalfSpan:Float=5.25
    static func boardPoint(unit:SIMD2<Float>,aspect:Float,scale:Float,height:Float=0.105,origin:SIMD3<Float> = .zero)->SIMD3<Float>? {
        guard unit.x.isFinite,unit.y.isFinite,aspect.isFinite,aspect>0,scale.isFinite,scale>0 else{return nil}
        let tangent=tangentHalfFOV(aspect:aspect)
        let ray=forward+right*((unit.x*2-1)*tangent*aspect)+up*((1-unit.y*2)*tangent)
        guard abs(ray.y)>0.0001 else{return nil}
        let distance=(origin.y+height*scale-eye.y)/ray.y
        guard distance>0 else{return nil}
        return (eye+ray*distance-origin)/scale
    }
    static func tangentHalfFOV(aspect:Float)->Float {horizontalHalfSpan/simd_length(eye)/max(0.25,aspect)}
}

/// A static presentation pose, baked once into cached mesh vertices (including
/// LODs). Ground contact remains unchanged and CPU picking sees the same shape.
enum PieceReadability {
    static let heightGain:Float=0.22
    static let profileLean:Float=0.42
    static func elevation(_ y:Float)->(amount:Float,slope:Float) {
        if y<=0.12 {return (0,0)}
        if y>=0.26 {return (y-0.19,1)}
        let t=(y-0.12)/0.14
        return (0.14*(t*t*t-0.5*t*t*t*t),3*t*t-2*t*t*t)
    }
    static func position(_ p:SIMD3<Float>)->SIMD3<Float> {
        let e=elevation(p.y).amount
        return SIMD3(p.x,p.y+heightGain*e,p.z-profileLean*e)
    }
    static func normal(_ n:SIMD3<Float>,atY y:Float)->SIMD3<Float> {
        let slope=elevation(y).slope
        return simd_normalize(SIMD3(n.x,(n.y+profileLean*slope*n.z)/(1+heightGain*slope),n.z))
    }
}

struct BoardDimensions:Codable,Equatable,Hashable {
    let columns:Int
    let rows:Int
    static let standard=BoardDimensions(columns:8,rows:8)!
    init?(columns:Int,rows:Int) {
        guard (4...8).contains(columns),(4...8).contains(rows) else{return nil}
        self.columns=columns;self.rows=rows
    }
    var storageKey:String {self == .standard ? "cloudchess.moves":"cloudchess.moves.\(columns)x\(rows)"}
    var initialFEN:String {
        if self == .standard {return "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"}
        let back=[4:"RNQK",5:"RNBQK",6:"RNBQKR",7:"RNBQKNR",8:"RNBQKBNR"][columns]!
        let pad=columns<8 ? String(8-columns):""
        var ranks=Array(repeating:"8",count:8)
        ranks[0]=back+pad;ranks[1]=String(repeating:"P",count:columns)+pad
        ranks[rows-2]=String(repeating:"p",count:columns)+pad;ranks[rows-1]=back.lowercased()+pad
        return ranks.reversed().joined(separator:"/")+" w - - 0 1"
    }
    func position(_ square:String,whiteAtBottom:Bool=true)->SIMD3<Float>? {
        let a=Array(square.utf8)
        guard a.count==2,a[0]>=97,a[0]<97+columns,a[1]>=49,a[1]<49+rows else{return nil}
        let direction:Float=whiteAtBottom ? 1:-1
        return SIMD3((Float(Int(a[0])-97)-Float(columns-1)/2)*direction,0.105,(Float(rows-1)/2-Float(Int(a[1])-49))*direction)
    }
    func square(x:Float,z:Float,whiteAtBottom:Bool=true)->String? {
        guard x.isFinite,z.isFinite else{return nil}
        let direction:Float=whiteAtBottom ? 1:-1
        let file=Int(floor(x*direction+Float(columns)/2)),rank=Int(floor(Float(rows)/2-z*direction))
        guard (0..<columns).contains(file),(0..<rows).contains(rank) else{return nil}
        return "\(UnicodeScalar(file+97)!)\(rank+1)"
    }
    /// Separate the low platform from the inset sculptures. A single tall box
    /// put imaginary crowns on the outside rim and unnecessarily shrank the board.
    /// Bounds include every Atelier LOD, original porcelain, readability lean and trim.
    var fittingEnvelope:[SIMD3<Float>] {
        var points:[SIMD3<Float>]=[]
        for x in [-Float(columns)/2-0.24,Float(columns)/2+0.24] {
            for z in [-Float(rows)/2-0.24,Float(rows)/2+0.24] {
                for y:Float in [-0.31,0.12] {points.append(SIMD3(x,y,z))}
            }
        }
        for x in [-Float(columns-1)/2-0.38,Float(columns-1)/2+0.38] {
            for z in [-Float(rows-1)/2-0.68,Float(rows-1)/2+0.38] {
                for y:Float in [0.105,1.36] {points.append(SIMD3(x,y,z))}
            }
        }
        return points
    }
    struct Placement {let scale:Float,origin:SIMD3<Float>}
    // Scale and place in the usable HUD-free region. Translation along camera-up
    // leaves depth/perspective unchanged; one stable parent keeps all animations local.
    func fittedPlacement(width:Float,height:Float,topInset:Float=0,bottomInset:Float=0,leftInset:Float=0,rightInset:Float=0)->Placement {
        guard width.isFinite,height.isFinite,width>0,height>0 else{return Placement(scale:1,origin:.zero)}
        let top=(max(0,topInset)+182)/height,bottom=1-(max(0,bottomInset)+106)/height
        let left=(max(0,leftInset)+6)/width,right=1-(max(0,rightInset)+6)/width
        var low:Float=0.01,high:Float=4
        let aspect=width/height,tangent=SceneComposition.tangentHalfFOV(aspect:aspect),envelope=fittingEnvelope
        func translationRange(_ scale:Float)->ClosedRange<Float>? {
            var lower = -Float.infinity,upper = Float.infinity
            for corner in envelope {
                let p=corner*scale-SceneComposition.eye,depth=simd_dot(p,SceneComposition.forward)
                let span=2*depth*tangent,sx=0.5+p.x/(span*aspect)
                guard depth>0,sx>=left,sx<=right else{return nil}
                let sy=0.5-simd_dot(p,SceneComposition.up)/span
                lower=max(lower,(sy-bottom)*span);upper=min(upper,(sy-top)*span)
            }
            return lower<=upper ? lower...upper:nil
        }
        for _ in 0..<32 {let mid=(low+high)/2;if translationRange(mid) != nil {low=mid}else{high=mid}}
        let range=translationRange(low) ?? 0...0
        let shift=min(range.upperBound,max(range.lowerBound,0))
        return Placement(scale:low,origin:SceneComposition.up*shift)
    }
    func fittedScale(width:Float,height:Float,topInset:Float=0,bottomInset:Float=0,leftInset:Float=0,rightInset:Float=0)->Float {
        fittedPlacement(width:width,height:height,topInset:topInset,bottomInset:bottomInset,leftInset:leftInset,rightInset:rightInset).scale
    }
}
