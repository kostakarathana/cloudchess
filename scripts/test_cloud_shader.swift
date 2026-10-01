import Metal
@main struct Check { static func main() throws {
 let device=MTLCreateSystemDefaultDevice()!
 let library=try device.makeLibrary(source:CloudVolumeShader.source,options:nil)
 print("Metal shader compiled: \(library.functionNames.sorted())")
}}
