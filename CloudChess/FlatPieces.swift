import SceneKit
import UIKit

extension PieceSculptor {
    private static let modelLock=NSRecursiveLock()
    private static var modelCache=[Character:SCNNode]()
    // A restrained view-dependent contour keeps the porcelain silhouette
    // readable on every tile without duplicating meshes or adding a glow pass.
    static func bodyColor(white:Bool)->UIColor {
        white ? UIColor(red:0.98,green:0.965,blue:0.925,alpha:1):UIColor(red:0.035,green:0.052,blue:0.078,alpha:1)
    }
    private static func porcelain(white:Bool)->SCNMaterial {
        let m=material(bodyColor(white:white),roughness:0.42)
        m.clearCoat.contents=0.10;m.clearCoatRoughness.contents=0.42
        let contour=white ? "float3(0.22, 0.29, 0.36)":"float3(0.40, 0.51, 0.61)"
        m.shaderModifiers=[.fragment:"""
        #pragma body
        float facing = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
        float edge = smoothstep(0.38, 0.88, 1.0 - facing);
        _output.color.rgb = mix(_output.color.rgb, \(contour), edge * 0.78);
        """]
        return m
    }
    private static let cloudIvory=porcelain(white:true)
    private static let cloudInk=porcelain(white:false)
    private static let ivoryEdge=material(UIColor(red:0.28,green:0.36,blue:0.43,alpha:1),roughness:0.48)
    private static let inkEdge=material(UIColor(red:0.62,green:0.71,blue:0.77,alpha:1),roughness:0.48)

    // Board-scale curve tolerance and a rounded bevel profile keep small
    // silhouettes smooth without flattening the sculpture hierarchy.
    private static func roundedShape(_ path:UIBezierPath,depth:CGFloat,bevel:CGFloat,material:SCNMaterial)->SCNNode {
        path.flatness=0.003
        let g=SCNShape(path:path,extrusionDepth:depth)
        let profile=UIBezierPath();profile.flatness=0.015;profile.move(to:CGPoint(x:0,y:1))
        profile.addCurve(to:CGPoint(x:1,y:0),controlPoint1:CGPoint(x:0.5523,y:1),controlPoint2:CGPoint(x:1,y:0.5523))
        g.chamferProfile=profile;g.chamferRadius=bevel;g.chamferMode = .both;g.materials=[material]
        return SCNNode(geometry:g)
    }

    /// Compact original Staunton-inspired porcelain: one quiet foot, a flowing
    /// body and a legible crown. Sculpture tilt is retained above a planted base.
    static func piece(_ symbol:Character)->SCNNode {
        modelLock.lock();defer{modelLock.unlock()}
        if let cached=modelCache[symbol] {return cached.clone()}
        let white=symbol.isUppercase,kind=symbol.lowercased(),m=white ? cloudIvory:cloudInk
        let edge=white ? ivoryEdge:inkEdge,root=SCNNode(),base=SCNNode()
        let radius:Float=kind=="p" ? 0.258:0.29
        base.addChildNode(lathe([(0,0.016),(radius*0.76,0.016),(radius*0.90,0.026),(radius*0.98,0.044),
            (radius,0.066),(radius*0.99,0.087),(radius*0.95,0.107),(radius*0.84,0.126),(radius*0.70,0.14),(0,0.14)],material:m))
        // A fine satin inlay gives the foot definition without another stacked ring.
        let seam=SCNTorus(ringRadius:CGFloat(radius*0.988),pipeRadius:0.012)
        seam.ringSegmentCount=48;seam.pipeSegmentCount=8;seam.materials=[edge]
        let inlay=SCNNode(geometry:seam);inlay.position.y=0.055;base.addChildNode(inlay)
        root.addChildNode(base)
        func body(top:Float,neck:Float=0.10,collar:Float=0.165) {
            let height=top-0.14
            root.addChildNode(lathe([(0,0.125),(0.195,0.125),(0.199,0.151),(0.189,0.18),
                (0.163,0.14+height*0.23),(0.132,0.14+height*0.43),(neck,top-0.105),
                (neck,top-0.065),(neck*1.14,top-0.044),(collar*0.92,top-0.030),
                (collar,top-0.016),(collar*0.98,top),(collar*0.82,top+0.014),(0,top+0.014)],material:m))
        }
        switch kind {
        case "p":
            body(top:0.39,neck:0.102,collar:0.145)
            root.addChildNode(sphere(0.158,SCNVector3(0,0.505,0),m,scale:SCNVector3(1,1.04,1)))
        case "r":
            root.addChildNode(lathe([(0,0.13),(0.196,0.13),(0.199,0.165),(0.187,0.21),(0.166,0.28),
                (0.161,0.39),(0.171,0.53),(0.19,0.568),(0.223,0.588),(0.236,0.615),
                (0.236,0.685),(0.224,0.707),(0.157,0.707),(0.147,0.684),(0.148,0.645),(0,0.635)],material:m))
            // Curved battlements connect to one recessed turret, rather than
            // floating rectangular blocks. Four broad cuts read at phone scale.
            for i in 0..<4 {
                let centre=CGFloat(i) * .pi/2 + .pi/4,half=CGFloat.pi/6
                let path=UIBezierPath()
                path.addArc(withCenter:.zero,radius:0.234,startAngle:centre-half,endAngle:centre+half,clockwise:true)
                path.addArc(withCenter:.zero,radius:0.153,startAngle:centre+half,endAngle:centre-half,clockwise:false);path.close()
                let tooth=roundedShape(path,depth:0.145,bevel:0.010,material:m)
                tooth.eulerAngles.x = -.pi/2;tooth.position.y=0.749;root.addChildNode(tooth)
            }
        case "n":
            let path=UIBezierPath()
            path.move(to:CGPoint(x:-0.165,y:0.145))
            path.addCurve(to:CGPoint(x:-0.195,y:0.64),controlPoint1:CGPoint(x:-0.255,y:0.31),controlPoint2:CGPoint(x:-0.26,y:0.52))
            path.addQuadCurve(to:CGPoint(x:-0.115,y:0.817),control:CGPoint(x:-0.17,y:0.78))
            path.addQuadCurve(to:CGPoint(x:-0.064,y:0.765),control:CGPoint(x:-0.09,y:0.824))
            path.addQuadCurve(to:CGPoint(x:0.010,y:0.851),control:CGPoint(x:-0.015,y:0.853))
            path.addQuadCurve(to:CGPoint(x:0.068,y:0.712),control:CGPoint(x:0.050,y:0.846))
            path.addCurve(to:CGPoint(x:0.272,y:0.586),controlPoint1:CGPoint(x:0.14,y:0.68),controlPoint2:CGPoint(x:0.264,y:0.636))
            path.addQuadCurve(to:CGPoint(x:0.292,y:0.515),control:CGPoint(x:0.306,y:0.559))
            path.addQuadCurve(to:CGPoint(x:0.214,y:0.469),control:CGPoint(x:0.278,y:0.467))
            path.addQuadCurve(to:CGPoint(x:0.084,y:0.512),control:CGPoint(x:0.157,y:0.477))
            path.addCurve(to:CGPoint(x:0.184,y:0.145),controlPoint1:CGPoint(x:0.015,y:0.419),controlPoint2:CGPoint(x:0.12,y:0.264));path.close()
            path.apply(CGAffineTransform(translationX:0,y:-0.14))
            let head=roundedShape(path,depth:0.265,bevel:0.052,material:m)
            head.position.y=0.14;head.eulerAngles=SCNVector3(-0.34,-0.12,0)
            let eye=material(white ? UIColor(red:0.17,green:0.27,blue:0.32,alpha:1):UIColor(red:0.72,green:0.79,blue:0.82,alpha:1),roughness:0.45)
            for side:Float in [-1,1] {
                head.addChildNode(sphere(0.020,SCNVector3(0.071,0.516,side*0.137),eye,scale:SCNVector3(1,0.85,0.40)))
                head.addChildNode(sphere(0.008,SCNVector3(0.245,0.406,side*0.136),eye,scale:SCNVector3(1,0.65,0.35)))
            }
            root.addChildNode(head)
        case "b":
            body(top:0.535,neck:0.095,collar:0.163)
            let path=UIBezierPath()
            path.move(to:CGPoint(x:0,y:0.915))
            path.addCurve(to:CGPoint(x:-0.203,y:0.685),controlPoint1:CGPoint(x:-0.058,y:0.868),controlPoint2:CGPoint(x:-0.21,y:0.768))
            path.addCurve(to:CGPoint(x:0.013,y:0.576),controlPoint1:CGPoint(x:-0.209,y:0.607),controlPoint2:CGPoint(x:-0.096,y:0.567))
            path.addCurve(to:CGPoint(x:0.191,y:0.716),controlPoint1:CGPoint(x:0.139,y:0.575),controlPoint2:CGPoint(x:0.222,y:0.648))
            path.addQuadCurve(to:CGPoint(x:0.145,y:0.795),control:CGPoint(x:0.18,y:0.758))
            // A real diagonal slit, kept wide enough to survive a small display.
            path.addLine(to:CGPoint(x:-0.035,y:0.698));path.addLine(to:CGPoint(x:-0.059,y:0.751))
            path.addLine(to:CGPoint(x:0.095,y:0.849));path.addQuadCurve(to:CGPoint(x:0,y:0.915),control:CGPoint(x:0.034,y:0.9));path.close()
            path.apply(CGAffineTransform(translationX:0,y:-0.55))
            let mitre=roundedShape(path,depth:0.255,bevel:0.026,material:m)
            mitre.position.y=0.55;mitre.eulerAngles.x = -0.36;root.addChildNode(mitre)
        case "q":
            body(top:0.555,neck:0.10,collar:0.174)
            root.addChildNode(lathe([(0,0.557),(0.126,0.557),(0.13,0.603),(0.152,0.651),
                (0.192,0.709),(0.219,0.757),(0.22,0.784),(0.192,0.797),(0.158,0.77),(0.126,0.701),(0,0.684)],material:m))
            // A broad five-point diadem has an unmistakable crown silhouette
            // from this camera; a radial ring reads as another rook at 40 px.
            let crown=UIBezierPath()
            let points:[CGPoint]=[CGPoint(x:-0.17,y:0),CGPoint(x:0.17,y:0),
                CGPoint(x:0.28,y:0.245),CGPoint(x:0.16,y:0.155),CGPoint(x:0.14,y:0.29),
                CGPoint(x:0.06,y:0.175),CGPoint(x:0,y:0.325),CGPoint(x:-0.06,y:0.175),
                CGPoint(x:-0.14,y:0.29),CGPoint(x:-0.16,y:0.155),CGPoint(x:-0.28,y:0.245)]
            crown.move(to:points[0]);for p in points.dropFirst(){crown.addLine(to:p)};crown.close()
            let diadem=roundedShape(crown,depth:0.13,bevel:0.016,material:m)
            diadem.position.y=0.69;diadem.eulerAngles.x = -0.35
            root.addChildNode(diadem)
        default:
            body(top:0.594,neck:0.109,collar:0.18)
            root.addChildNode(sphere(0.164,SCNVector3(0,0.650,0),m,scale:SCNVector3(1,0.64,1)))
            root.addChildNode(lathe([(0,0.694),(0.149,0.694),(0.17,0.705),(0.168,0.725),(0.143,0.738),(0,0.738)],material:m))
            let path=UIBezierPath()
            let points:[CGPoint]=[CGPoint(x:-0.056,y:0),CGPoint(x:0.056,y:0),CGPoint(x:0.056,y:0.166),CGPoint(x:0.195,y:0.158),CGPoint(x:0.195,y:0.258),CGPoint(x:0.056,y:0.244),CGPoint(x:0.056,y:0.324),CGPoint(x:-0.056,y:0.324),CGPoint(x:-0.056,y:0.244),CGPoint(x:-0.195,y:0.258),CGPoint(x:-0.195,y:0.158),CGPoint(x:-0.056,y:0.166)]
            path.move(to:points[0]);for point in points.dropFirst(){path.addLine(to:point)};path.close()
            let cross=roundedShape(path,depth:0.092,bevel:0.012,material:m)
            cross.position.y=0.70;cross.eulerAngles.x = -0.35;root.addChildNode(cross)
        }
        let sculpture=SCNNode();sculpture.position.y=0.14;sculpture.eulerAngles.x = -.pi/10
        for component in Array(root.childNodes.dropFirst()) {
            component.removeFromParentNode();component.position.y -= 0.14;sculpture.addChildNode(component)
        }
        root.addChildNode(sculpture)
        // Broader silhouettes, unchanged height and planted footprint. Keep
        // this under the animation root so drag/selection resets preserve it.
        let silhouette=SCNNode();silhouette.scale=SCNVector3(1.12,1,1.12)
        for child in Array(root.childNodes) {child.removeFromParentNode();silhouette.addChildNode(child)}
        root.addChildNode(silhouette)
        // Preserve hierarchical transforms; cached clones share immutable meshes.
        root.name="satin-porcelain-piece"
        root.enumerateChildNodes{node,_ in node.castsShadow=true};root.castsShadow=true
        modelCache[symbol]=root;return root.clone()
    }
}

private extension UIBezierPath {
    func addQuadCurve(to point:CGPoint,control:CGPoint) {addQuadCurve(to:point,controlPoint:control)}
}
