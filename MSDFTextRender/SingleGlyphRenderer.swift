import Metal
import MetalKit
import simd
import MSDFText

@MainActor
final class SingleGlyphRenderer: NSObject, MTKViewDelegate {

    private enum Constants {
        static let glyphSize: Float = 64
        static let glyphPxRange: Float = 4
        static let minZoom: Float = 0.5
        static let maxZoom: Float = 20.0
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    private var mesh: MSDFText.MSDFTextMesh
    private var glyphSize: Float = Constants.glyphSize

    let glyphTexture: MTLTexture
    var textColor = SIMD4<Float>(repeating: 1)

    private var msdfRenderer: MSDFText.MSDFTextRenderer
    private var glyphScale: Float = 1.0

    weak var view: MTKView?

    init?(metalKitView: MTKView) {
        guard let device = metalKitView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        metalKitView.depthStencilPixelFormat = .invalid
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1

        do {
            msdfRenderer = try MSDFTextRenderer(
                device: device,
                pixelFormat: metalKitView.colorPixelFormat,
                sampleCount: metalKitView.sampleCount,
                atlasPxRange: Constants.glyphPxRange
            )
        } catch {
            print("Failed to build MSDFText renderer: \(error)")
            return nil
        }

        do {
            glyphTexture = try SingleGlyphRenderer.loadTexture(device: device)
        } catch {
            print("Failed to load MSDF glyph texture: \(error)")
            return nil
        }

        let initialSize = Constants.glyphSize * Float(metalKitView.contentScaleFactor)
        guard let geometry = SingleGlyphRenderer.makeGlyphGeometry(
            device: device,
            size: initialSize
        ) else {
            return nil
        }
        vertexBuffer = geometry.vertexBuffer
        indexBuffer = geometry.indexBuffer
        indexCount = geometry.indexCount
        glyphSize = Constants.glyphSize

        mesh = MSDFText.MSDFTextMesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            bounds: CGSize(width: CGFloat(initialSize), height: CGFloat(initialSize))
        )

        super.init()

        view = metalKitView
        updateProjection(for: metalKitView.drawableSize)
        updateModelViewMatrix(for: metalKitView.drawableSize)
    }

    func draw(in view: MTKView) {
        _ = inFlightSemaphore.wait(timeout: .distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.label = "SingleGlyphCommandBuffer"
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        renderEncoder.label = "SingleGlyphEncoder"
        let style = MSDFText.MSDFTextRenderStyle(textColor: textColor)
        msdfRenderer.encode(
            encoder: renderEncoder,
            mesh: mesh,
            atlasTexture: glyphTexture,
            style: style
        )
        renderEncoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateProjection(for: size)
        updateModelViewMatrix(for: size)
    }

    func updateZoom(scale: CGFloat) {
        let clamped = max(min(Float(scale), Constants.maxZoom), Constants.minZoom)
        guard abs(clamped - glyphScale) > 0.0001 else { return }
        glyphScale = clamped
        glyphSize = Constants.glyphSize * glyphScale
        updateGlyphVertices()
        if let drawableSize = view?.drawableSize {
            updateModelViewMatrix(for: drawableSize)
        }
    }

    private func updateProjection(for drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        msdfRenderer.setOrthoProjection(width: Float(drawableSize.width),
                                        height: Float(drawableSize.height))
    }

    private func updateModelViewMatrix(for drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            msdfRenderer.modelViewMatrix = matrix_identity_float4x4
            return
        }

        let tx = (Float(drawableSize.width) - glyphSize) * 0.5
        let ty = (Float(drawableSize.height) - glyphSize) * 0.5
        msdfRenderer.modelViewMatrix = matrix_translate(tx: tx, ty: ty, tz: 0)
    }

    private static func loadTexture(device: MTLDevice) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.topLeft,
            .SRGB: false,
            .generateMipmaps: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        guard let url = Bundle.main.url(forResource: "r", withExtension: "png") else {
            throw NSError(domain: "SingleGlyphRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No r.png from bundle"])
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(domain: "SingleGlyphRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load r.png from bundle"])
        }
        return try loader.newTexture(cgImage: cgImage, options: options)
    }

    private static func makeGlyphGeometry(device: MTLDevice,
                                          size: Float) -> (vertexBuffer: MTLBuffer,
                                                           indexBuffer: MTLBuffer,
                                                           indexCount: Int)? {
        let indices: [UInt32] = [
            0, 1, 2,
            0, 2, 3,
        ]

        let vertexCount = Self.unitVerticesTemplate.count
        guard let vertexBuffer = device.makeBuffer(length: vertexCount * MemoryLayout<MSDFText.MSDFGlyphVertex>.stride,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices,
                                                  length: indices.count * MemoryLayout<UInt32>.stride,
                                                  options: .storageModeShared) else {
            return nil
        }

        vertexBuffer.label = "SingleGlyphVertices"
        indexBuffer.label = "SingleGlyphIndices"

        Self.writeVertices(to: vertexBuffer,
                           using: Self.unitVerticesTemplate,
                           size: size)

        return (vertexBuffer, indexBuffer, indices.count)
    }

    private static let unitVerticesTemplate: [MSDFText.MSDFGlyphVertex] = [
        MSDFText.MSDFGlyphVertex(position: SIMD3<Float>(0, 1, 0),
                                 texCoord: SIMD2<Float>(0, 1)),
        MSDFText.MSDFGlyphVertex(position: SIMD3<Float>(0, 0, 0),
                                 texCoord: SIMD2<Float>(0, 0)),
        MSDFText.MSDFGlyphVertex(position: SIMD3<Float>(1, 0, 0),
                                 texCoord: SIMD2<Float>(1, 0)),
        MSDFText.MSDFGlyphVertex(position: SIMD3<Float>(1, 1, 0),
                                 texCoord: SIMD2<Float>(1, 1)),
    ]

    private static func writeVertices(to buffer: MTLBuffer,
                                      using template: [MSDFText.MSDFGlyphVertex],
                                      size: Float) {
        let count = template.count
        let pointer = buffer.contents().bindMemory(to: MSDFText.MSDFGlyphVertex.self, capacity: count)
        for index in 0..<count {
            var vertex = template[index]
            vertex.position.x *= size
            vertex.position.y *= size
            pointer[index] = vertex
        }
    }

    private func updateGlyphVertices() {
        SingleGlyphRenderer.writeVertices(to: vertexBuffer,
                                          using: SingleGlyphRenderer.unitVerticesTemplate,
                                          size: glyphSize)
    }
}

private func matrix_translate(tx: Float, ty: Float, tz: Float) -> matrix_float4x4 {
    let column0 = SIMD4<Float>(1, 0, 0, 0)
    let column1 = SIMD4<Float>(0, 1, 0, 0)
    let column2 = SIMD4<Float>(0, 0, 1, 0)
    let column3 = SIMD4<Float>(tx, ty, tz, 1)
    return matrix_float4x4(columns: (column0, column1, column2, column3))
}

private func matrix_ortho(width: Float, height: Float) -> matrix_float4x4 {
    let sx: Float = width != 0 ? 2.0 / width : 0
    let sy: Float = height != 0 ? -2.0 / height : 0
    return matrix_float4x4(columns: (
        SIMD4<Float>(sx, 0, 0, 0),
        SIMD4<Float>(0, sy, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(-1, 1, 0, 1)
    ))
}
