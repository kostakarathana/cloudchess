import SceneKit
import UIKit

/// Original, smooth revolved porcelain forms. No font glyphs or flat piece sprites.
enum PieceSculptor {
    static func material(_ color: UIColor, metal: CGFloat = 0, roughness: CGFloat = 0.28) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        m.diffuse.contents = color; m.metalness.contents = metal; m.roughness.contents = roughness
        return m
    }
    static let ivory = material(UIColor(red: 0.98, green: 0.94, blue: 0.84, alpha: 1))
    static let navy = material(UIColor(red: 0.065, green: 0.14, blue: 0.25, alpha: 1), metal: 0.18, roughness: 0.23)
    static let gold = material(UIColor(red: 0.76, green: 0.59, blue: 0.32, alpha: 1), metal: 0.78, roughness: 0.26)
    static func lathe(_ profile: [(Float, Float)], material: SCNMaterial) -> SCNNode {
        let segments = 48
        var vertices = [SCNVector3](), normals = [SCNVector3](), indices = [Int32](),uv=[CGPoint]()
        for (j, p) in profile.enumerated() {
            let before = profile[max(0,j-1)], after = profile[min(profile.count-1,j+1)]
            let dr = after.0-before.0, dy = after.1-before.1
            let length = max(0.00001, sqrt(dr*dr+dy*dy))
            for i in 0...segments {
                let a = Float(i)/Float(segments) * .pi * 2
                vertices.append(SCNVector3(p.0*cos(a),p.1,p.0*sin(a)))
                uv.append(CGPoint(x:Double(i)/Double(segments),y:Double(p.1)*2))
                normals.append(SCNVector3(dy*cos(a)/length,-dr/length,dy*sin(a)/length))
            }
        }
        for j in 0..<profile.count-1 { for i in 0..<segments {
            let a = Int32(j*(segments+1)+i), b = a+Int32(segments+1)
            indices += [a,b,a+1,a+1,b,b+1]
        }}
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)], elements: [SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        geometry.materials = [material]
        let node=SCNNode(geometry:geometry);node.name="turned-form";return node
    }
    static func sphere(_ radius: CGFloat, _ p: SCNVector3, _ m: SCNMaterial, scale: SCNVector3 = SCNVector3(1,1,1)) -> SCNNode {
        let g = SCNSphere(radius:radius);g.segmentCount=24;g.materials=[m]
        let n=SCNNode(geometry:g);n.position=p;n.scale=scale;return n
    }
    static func ring(_ radius: CGFloat, y: Float, tube: CGFloat = 0.018) -> SCNNode {
        let g=SCNTorus(ringRadius:radius,pipeRadius:tube);g.ringSegmentCount=64;g.pipeSegmentCount=12;g.materials=[gold]
        let n=SCNNode(geometry:g);n.position.y=y;return n
    }
    static func box(_ w: CGFloat,_ h: CGFloat,_ l: CGFloat,_ r: CGFloat,_ m: SCNMaterial, at p: SCNVector3) -> SCNNode {
        let g=SCNBox(width:w,height:h,length:l,chamferRadius:r);g.chamferSegmentCount=4;g.materials=[m]
        let n=SCNNode(geometry:g);n.position=p;return n
    }
    static func sculptedPiece(_ symbol: Character) -> SCNNode {
        let white=symbol.isUppercase, kind=symbol.lowercased(), m=white ? ivory : navy
        let root=SCNNode();root.name="sculpture"
        root.addChildNode(lathe([(0,0.015),(0.22,0.015),(0.29,0.035),(0.31,0.065),(0.31,0.10),(0.29,0.135),(0.255,0.15),(0.25,0.19),(0.23,0.215),(0.19,0.235)],material:m))
        root.addChildNode(ring(0.268,y:0.145,tube:0.013))
        switch kind {
        case "p":
            root.addChildNode(lathe([(0.19,0.22),(0.18,0.255),(0.145,0.29),(0.105,0.41),(0.105,0.48),(0.13,0.51),(0.18,0.525),(0.185,0.56),(0.155,0.585),(0.10,0.60)],material:m))
            root.addChildNode(sphere(0.195,SCNVector3(0,0.735,0),m))
            root.addChildNode(ring(0.144,y:0.575,tube:0.01))
        case "r":
            root.addChildNode(lathe([(0.19,0.22),(0.175,0.27),(0.16,0.4),(0.17,0.7),(0.205,0.74),(0.245,0.76),(0.25,0.805),(0.235,0.86),(0.23,0.96),(0,0.96)],material:m))
            for i in 0..<6 {
                let a=Float(i)*Float.pi/3
                let n=box(0.14,0.16,0.15,0.021,m,at:SCNVector3(0.182*cos(a),0.995,0.182*sin(a)))
                n.eulerAngles.y = -a;root.addChildNode(n)
            }
            root.addChildNode(ring(0.237,y:0.80,tube:0.013))
        case "n":
            root.addChildNode(lathe([(0.19,0.22),(0.205,0.27),(0.19,0.33),(0.155,0.36),(0,0.36)],material:m))
            let path=UIBezierPath()
            path.move(to:CGPoint(x:-0.20,y:0.32))
            path.addCurve(to:CGPoint(x:-0.20,y:0.97),controlPoint1:CGPoint(x:-0.32,y:0.57),controlPoint2:CGPoint(x:-0.31,y:0.79))
            path.addLine(to:CGPoint(x:-0.11,y:1.16));path.addLine(to:CGPoint(x:-0.045,y:1.10))
            path.addLine(to:CGPoint(x:0.015,y:1.26));path.addQuadCurve(to:CGPoint(x:0.10,y:1.07),controlPoint:CGPoint(x:0.09,y:1.22))
            path.addCurve(to:CGPoint(x:0.32,y:0.92),controlPoint1:CGPoint(x:0.20,y:1.03),controlPoint2:CGPoint(x:0.21,y:0.96))
            path.addLine(to:CGPoint(x:0.35,y:0.79));path.addQuadCurve(to:CGPoint(x:0.21,y:0.72),controlPoint:CGPoint(x:0.34,y:0.70))
            path.addLine(to:CGPoint(x:0.075,y:0.78))
            path.addCurve(to:CGPoint(x:0.20,y:0.33),controlPoint1:CGPoint(x:-0.045,y:0.61),controlPoint2:CGPoint(x:0.15,y:0.55));path.close()
            let g=SCNShape(path:path,extrusionDepth:0.25);g.chamferRadius=0.045;g.chamferMode = .both;g.materials=[m]
            let head=SCNNode(geometry:g);head.eulerAngles.y=white ? -0.35 : Float.pi-0.35
            for z:Float in [-0.14,0.14] { head.addChildNode(sphere(0.027,SCNVector3(0.105,0.98,z),gold)) }
            for i in 0..<5 {
                head.addChildNode(box(0.055,0.067,0.27,0.016,m,at:SCNVector3(-0.237+Float(i)*0.011,0.63+Float(i)*0.075,0)))
            }
            root.addChildNode(head)
        case "b":
            root.addChildNode(stem(m,height:0.80))
            let path=UIBezierPath();path.move(to:CGPoint(x:0,y:1.30))
            path.addCurve(to:CGPoint(x:-0.205,y:0.97),controlPoint1:CGPoint(x:-0.11,y:1.20),controlPoint2:CGPoint(x:-0.25,y:1.09))
            path.addCurve(to:CGPoint(x:0.18,y:0.95),controlPoint1:CGPoint(x:-0.20,y:0.79),controlPoint2:CGPoint(x:0.21,y:0.80))
            path.addQuadCurve(to:CGPoint(x:0.12,y:1.13),controlPoint:CGPoint(x:0.24,y:1.03))
            path.addLine(to:CGPoint(x:-0.035,y:0.99));path.addLine(to:CGPoint(x:-0.07,y:1.04));path.addLine(to:CGPoint(x:0.075,y:1.18));path.close()
            let g=SCNShape(path:path,extrusionDepth:0.26);g.chamferRadius=0.042;g.materials=[m]
            root.addChildNode(SCNNode(geometry:g));root.addChildNode(sphere(0.053,SCNVector3(0,1.32,0),gold))
        case "q":
            root.addChildNode(stem(m,height:0.92))
            root.addChildNode(lathe([(0.11,0.92),(0.14,1.00),(0.19,1.10),(0.24,1.18),(0.225,1.22),(0.17,1.13),(0,1.10)],material:m))
            for i in 0..<8 {
                let a=Float(i)*Float.pi/4
                let n=box(0.065,0.23,0.065,0.025,m,at:SCNVector3(0.20*cos(a),1.24,0.20*sin(a)))
                n.eulerAngles=SCNVector3(0.2*sin(a),0,-0.2*cos(a));root.addChildNode(n)
                root.addChildNode(sphere(0.05,SCNVector3(0.225*cos(a),1.36,0.225*sin(a)),gold))
            }
            root.addChildNode(sphere(0.095,SCNVector3(0,1.24,0),m))
            root.addChildNode(ring(0.18,y:1.09,tube:0.016))
        default:
            root.addChildNode(stem(m,height:1.02))
            root.addChildNode(sphere(0.19,SCNVector3(0,1.12,0),m,scale:SCNVector3(1,0.75,1)))
            root.addChildNode(ring(0.16,y:1.16,tube:0.014))
            root.addChildNode(box(0.09,0.35,0.10,0.022,m,at:SCNVector3(0,1.40,0)))
            root.addChildNode(box(0.29,0.09,0.10,0.022,m,at:SCNVector3(0,1.45,0)))
            root.addChildNode(sphere(0.034,SCNVector3(0,1.45,0.062),gold))
        }
        root.enumerateChildNodes { n,_ in n.castsShadow=true }
        return root
    }
    static func stem(_ m: SCNMaterial,height h: Float) -> SCNNode {
        let root=SCNNode()
        root.addChildNode(lathe([(0.19,0.22),(0.18,0.27),(0.14,0.35),(0.105,h-0.22),(0.115,h-0.13),(0.17,h-0.08),(0.21,h-0.055),(0.205,h-0.02),(0.16,h),(0.11,h+0.01)],material:m))
        root.addChildNode(ring(0.185,y:h-0.027,tube:0.012));return root
    }
}
