import Foundation
import simd
@main struct PiecePoseChecks {
 static func main() throws {
    let folder=URL(fileURLWithPath:CommandLine.arguments[1])
    var checks=0,meshes=0,vertices=0
    var maximumHeight:Float=0,maximumProjection:Float=0
    func check(_ condition:Bool,_ label:String) {precondition(condition,label);checks+=1}
    for file in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter({$0.pathExtension=="ccmesh" && !$0.lastPathComponent.contains("frame")}) {
        let data=try Data(contentsOf:file),count=data.withUnsafeBytes{Int($0.loadUnaligned(fromByteOffset:4,as:UInt32.self))}
        meshes+=1;vertices+=count
        try data.withUnsafeBytes {raw in
            for i in 0..<count {
                let offset=28+i*24
                func f(_ n:Int)->Float {raw.loadUnaligned(fromByteOffset:offset+n*4,as:Float.self)}
                let old=SIMD3(f(0),f(1),f(2)),normal=SIMD3(f(3),f(4),f(5))
                let p=PieceReadability.position(old),n=PieceReadability.normal(normal,atY:old.y)
                check(p.x.isFinite && p.y.isFinite && p.z.isFinite && n.x.isFinite && n.y.isFinite && n.z.isFinite,"Finite rendered vertices/normals")
                check(abs(simd_length(n)-1)<0.0001,"Unit lighting normals")
                check(p.y>=old.y && p.x==old.x,"Taller without widening the occupied file")
                if old.y<=0.12 {check(p==old,"Base stays exactly planted")}
                check(p.y<1.26 && abs(p.x)<0.34 && p.z > -0.5 && p.z<0.36,"Mobile board envelope")
                check(abs(p.x)<=0.38 && p.y+0.105<=1.36 && p.z >= -0.68 && p.z<=0.38,"Every shipping vertex fits the tighter board-sizing envelope")
                let vertical=simd_dot(p,SceneComposition.up)
                check(vertical<0.84,"Crowns stay short of adjacent rank centers")
                maximumHeight=max(maximumHeight,p.y);maximumProjection=max(maximumProjection,vertical)
            }
        }
    }
    // Check the analytical normal transform against deformed surface tangents.
    for i in 0..<10000 {
        let y=Float(i)/8000,n=simd_normalize(SIMD3<Float>(0.4,0.7,-0.5))
        let tangent=simd_normalize(simd_cross(n,SIMD3<Float>(1,0,0))),p=SIMD3<Float>(0.1,y,0.03),e:Float=0.0005
        let actual=(PieceReadability.position(p+tangent*e)-PieceReadability.position(p-tangent*e))/(2*e)
        check(abs(simd_dot(PieceReadability.normal(n,atY:y),actual))<0.0005,"Normal remains perpendicular to posed surface")
    }
    check(meshes==204,"Every theme, piece and distance LOD checked")
    print("{\"status\":\"passed\",\"checks\":\(checks),\"meshes\":\(meshes),\"vertices\":\(vertices),\"maximumHeight\":\(maximumHeight),\"maximumProjectedHeight\":\(maximumProjection)}")
 }
}
