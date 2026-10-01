import SwiftUI
import MetalKit

struct CloudAtmosphere: UIViewRepresentable {
    var motion:Bool
    let field:CloudAtmosphereDynamics
    @Environment(\.scenePhase) private var scenePhase
    func makeCoordinator()->Renderer {Renderer(field:field)}
    func makeUIView(context:Context)->CloudMetalView {
        let view=CloudMetalView(frame:.zero,device:context.coordinator.device)
        view.field=field;view.colorPixelFormat = .bgra8Unorm
        view.isOpaque=true;view.backgroundColor=UIColor(red:0.86,green:0.91,blue:0.98,alpha:1)
        view.preferredFramesPerSecond=30;view.autoResizeDrawable=false
        view.delegate=context.coordinator;view.isAccessibilityElement=false
        return view
    }
    func updateUIView(_ view:CloudMetalView,context:Context) {
        let paused = !motion || scenePhase != .active
        field.setPaused(paused);view.isPaused=paused
        if paused {view.draw()}
    }
    final class Renderer:NSObject,MTKViewDelegate {
        let field:CloudAtmosphereDynamics
        let device:MTLDevice
        let queue:MTLCommandQueue
        let pipeline:MTLRenderPipelineState
        let noise:MTLTexture
        #if DEBUG
        private let auditLock=NSLock()
        private var auditSamples=[Double]()
        private var auditStart:Double?
        #endif
        struct Uniforms {
            var screen:SIMD4<Float>;var touch:SIMD4<Float>;var wind:SIMD4<Float>
            var eye:SIMD4<Float>;var forward:SIMD4<Float>;var up:SIMD4<Float>;var sun:SIMD4<Float>;var board:SIMD4<Float>;var shadow:SIMD4<Float>;var light:SIMD4<Float>
        }
        init(field:CloudAtmosphereDynamics) {
            self.field=field
            let resources=CloudRenderResources.shared
            device=resources.device;queue=resources.queue;pipeline=resources.pipeline;noise=resources.noise
            super.init()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--render-audit"),let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {
                let report:[String:Any]=["status":"awaiting frames","started_at":ISO8601DateFormatter().string(from:Date()),"frames":0]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) {try? data.write(to:root.appendingPathComponent("cloud-render-audit.json"))}
            }
            #endif
        }
        func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
        func draw(in view:MTKView) {
            guard let descriptor=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,let command=queue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else{return}
            let frame=field.frame(at:CACurrentMediaTime())
            #if DEBUG
            let windTime=ProcessInfo.processInfo.arguments.contains("--cloud-validation") ? Float(0):frame.0
            #else
            let windTime=frame.0
            #endif
            let aspect=Float(view.drawableSize.width/view.drawableSize.height)
            let appearance=field.appearance
            let eye=SceneComposition.eye,forward=SceneComposition.forward,up=SceneComposition.up,sun=SceneComposition.sun
            var uniforms=Uniforms(screen:SIMD4(Float(view.drawableSize.width),Float(view.drawableSize.height),windTime,0),touch:SIMD4(frame.1.x,frame.1.y,0,0),wind:SIMD4(frame.2.x,frame.2.y,frame.2.z,0),eye:SIMD4(eye.x,eye.y,eye.z,SceneComposition.tangentHalfFOV(aspect:aspect)),forward:SIMD4(forward.x,forward.y,forward.z,0),up:SIMD4(up.x,up.y,up.z,0),sun:SIMD4(sun.x,sun.y,sun.z,0),board:field.boardLayout,shadow:appearance.0,light:appearance.1)
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:0);encoder.setFragmentTexture(noise,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--render-audit") {
                command.addCompletedHandler { [weak self] buffer in
                    guard let self=self else{return}
                    self.auditLock.lock();defer{self.auditLock.unlock()}
                    guard self.auditSamples.count<120 else{return}
                    if self.auditStart==nil {self.auditStart=CACurrentMediaTime()}
                    self.auditSamples.append(max(0,(buffer.gpuEndTime-buffer.gpuStartTime)*1000))
                    if self.auditSamples.count==30 || self.auditSamples.count==120 {
                        let sorted=self.auditSamples.sorted(),elapsed=CACurrentMediaTime()-(self.auditStart ?? CACurrentMediaTime())
                        #if targetEnvironment(simulator)
                        let scope="Simulator development host; cloud pass only"
                        #else
                        let scope="Physical iPhone; cloud Metal pass only, not whole-app frame cost"
                        #endif
                        let report:[String:Any]=["recorded_at":ISO8601DateFormatter().string(from:Date()),"frames":sorted.count,"observed_fps":Double(sorted.count-1)/max(0.001,elapsed),"gpu_ms_median":sorted[sorted.count/2],"gpu_ms_p95":sorted[Int(Double(sorted.count)*0.95)],"device":self.device.name,"scope":scope]
                        if let data=try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted),let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {try? data.write(to:root.appendingPathComponent("cloud-render-audit.json"))}
                    }
                }
            }
            #endif
            command.present(drawable);command.commit()
        }
    }
}
final class CloudMetalView:MTKView {
    weak var field:CloudAtmosphereDynamics?
    private var start=CGPoint.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        // Cloud contours are low frequency: a bounded target saves fill rate while
        // the chessboard stays at native resolution in its separate SceneKit layer.
        let scale=min(1.0,480/max(1,bounds.width))
        drawableSize=CGSize(width:max(1,bounds.width*scale),height:max(1,bounds.height*scale))
        if isPaused {draw()}
    }
    private func unit(_ point:CGPoint)->SIMD2<Float> {SIMD2(Float(point.x/max(1,bounds.width)),Float(point.y/max(1,bounds.height)))}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) {
        guard let touch=touches.first else{return};start=touch.location(in:self);_ = field?.begin(at:unit(start))
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) {
        guard let touch=touches.first else{return};let p=touch.location(in:self);field?.drag(unit(CGPoint(x:p.x-start.x,y:p.y-start.y)))
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) {field?.end()}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) {field?.end()}
}

/// The ordinary sky and the short foreground cloud journey share immutable GPU
/// assets. Entering a transition never recompiles a shader or reloads 8 MB of noise.
private final class CloudRenderResources {
    static let shared=CloudRenderResources()
    let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLRenderPipelineState,noise:MTLTexture
    private init() {
            guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal unavailable")}
            self.device=device;self.queue=queue
            do {
                let library=try device.makeLibrary(source:CloudVolumeShader.source,options:nil)
                let descriptor=MTLRenderPipelineDescriptor();descriptor.vertexFunction=library.makeFunction(name:"cloudVertex");descriptor.fragmentFunction=library.makeFunction(name:"cloudFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
            } catch {fatalError("Cloud shader compilation failed: \(error)")}
            let descriptor=MTLTextureDescriptor();descriptor.textureType = .type3D;descriptor.pixelFormat = .rgba8Unorm
            descriptor.width=128;descriptor.height=64;descriptor.depth=256;descriptor.usage = .shaderRead;descriptor.storageMode = .shared
            guard let texture=device.makeTexture(descriptor:descriptor),let data=NSDataAsset(name:"CloudDensity")?.data,data.count==128*64*256*4 else{fatalError("Cloud density asset missing")}
            data.withUnsafeBytes { raw in texture.replace(region:MTLRegionMake3D(0,0,0,128,64,256),mipmapLevel:0,slice:0,withBytes:raw.baseAddress!,bytesPerRow:128*4,bytesPerImage:128*64*4) }
            noise=texture
    }
}
