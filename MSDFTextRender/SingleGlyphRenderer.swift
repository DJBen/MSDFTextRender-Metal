import Metal
import MetalKit
import simd

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

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>

    let pipelineState: MTLRenderPipelineState
    let depthState: MTLDepthStencilState

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    private var glyphSize: Float = Constants.glyphSize

    let glyphTexture: MTLTexture
    var unitRange = SIMD2<Float>(repeating: 0)
    var textColor = SIMD4<Float>(repeating: 1)

    var projectionMatrix: matrix_float4x4 = matrix_identity_float4x4
    var modelViewMatrix: matrix_float4x4 = matrix_identity_float4x4
    private var glyphScale: Float = 1.0

    weak var view: MTKView?

    init?(metalKitView: MTKView) {
        guard let device = metalKitView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        guard let uniformBuffer = device.makeBuffer(length: uniformBufferSize, options: .storageModeShared) else {
            return nil
        }
        uniformBuffer.label = "SingleGlyphUniformBuffer"
        dynamicUniformBuffer = uniformBuffer
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents())
            .bindMemory(to: Uniforms.self, capacity: 1)

        metalKitView.depthStencilPixelFormat = .invalid
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1

        let vertexDescriptor = Renderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       metalKitView: metalKitView,
                                                                       mtlVertexDescriptor: vertexDescriptor)
        } catch {
            print("Failed to build single glyph pipeline: \(error)")
            return nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthState = depthState

        do {
            glyphTexture = try SingleGlyphRenderer.loadTexture(device: device)
        } catch {
            print("Failed to load MSDF glyph texture: \(error)")
            return nil
        }

        unitRange = SIMD2<Float>(Constants.glyphPxRange / Float(glyphTexture.width),
                                 Constants.glyphPxRange / Float(glyphTexture.height))

        guard let geometry = SingleGlyphRenderer.makeGlyphGeometry(
            device: device,
            size: Constants.glyphSize * Float(metalKitView.contentScaleFactor)
        ) else {
            return nil
        }
        vertexBuffer = geometry.vertexBuffer
        indexBuffer = geometry.indexBuffer
        indexCount = geometry.indexCount
        glyphSize = Constants.glyphSize

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

        updateDynamicBufferState()
        updateUniforms()

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        renderEncoder.label = "SingleGlyphEncoder"
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)

        renderEncoder.setVertexBuffer(vertexBuffer,
                                      offset: 0,
                                      index: BufferIndex.meshPositions.rawValue)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer,
                                      offset: uniformBufferOffset,
                                      index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer,
                                        offset: uniformBufferOffset,
                                        index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentTexture(glyphTexture, index: TextureIndex.color.rawValue)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: indexCount,
                                            indexType: .uint16,
                                            indexBuffer: indexBuffer,
                                            indexBufferOffset: 0)
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

    private func updateDynamicBufferState() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset)
            .bindMemory(to: Uniforms.self, capacity: 1)
    }

    private func updateUniforms() {
        uniforms[0].projectionMatrix = projectionMatrix
        uniforms[0].modelViewMatrix = modelViewMatrix
        uniforms[0].textColor = textColor
        uniforms[0].unitRange = unitRange
        // Default to normal fill for single glyph screen
        uniforms[0].strokeColor = SIMD4<Float>(0, 0, 0, 0)
        uniforms[0].renderOptions = SIMD2<UInt32>(0, 0)
        uniforms[0].strokeParams = SIMD2<Float>(0, 0)
    }

    private func updateProjection(for drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        projectionMatrix = matrix_ortho(width: Float(drawableSize.width),
                                        height: Float(drawableSize.height))
    }

    private func updateModelViewMatrix(for drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            modelViewMatrix = matrix_identity_float4x4
            return
        }

        let tx = (Float(drawableSize.width) - glyphSize) * 0.5
        let ty = (Float(drawableSize.height) - glyphSize) * 0.5
        modelViewMatrix = matrix_translate(tx: tx, ty: ty, tz: 0)
    }

    private static func loadTexture(device: MTLDevice) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.bottomLeft,
            .SRGB: false,
            .generateMipmaps: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        return try loader.newTexture(name: "r",
                                     scaleFactor: 1.0,
                                     bundle: .main,
                                     options: options)
    }

    private static func makeGlyphGeometry(device: MTLDevice,
                                          size: Float) -> (vertexBuffer: MTLBuffer,
                                                           indexBuffer: MTLBuffer,
                                                           indexCount: Int)? {
        let indices: [UInt16] = [
            0, 1, 2,
            0, 2, 3,
        ]

        let vertexCount = Self.unitVerticesTemplate.count
        guard let vertexBuffer = device.makeBuffer(length: vertexCount * MemoryLayout<MSDFGlyphVertex>.stride,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices,
                                                  length: indices.count * MemoryLayout<UInt16>.stride,
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

    private static let unitVerticesTemplate: [MSDFGlyphVertex] = [
        MSDFGlyphVertex(position: SIMD3<Float>(0, 1, 0),
                        texCoord: SIMD2<Float>(0, 1)),
        MSDFGlyphVertex(position: SIMD3<Float>(0, 0, 0),
                        texCoord: SIMD2<Float>(0, 0)),
        MSDFGlyphVertex(position: SIMD3<Float>(1, 0, 0),
                        texCoord: SIMD2<Float>(1, 0)),
        MSDFGlyphVertex(position: SIMD3<Float>(1, 1, 0),
                        texCoord: SIMD2<Float>(1, 1)),
    ]

    private static func writeVertices(to buffer: MTLBuffer,
                                      using template: [MSDFGlyphVertex],
                                      size: Float) {
        let count = template.count
        let pointer = buffer.contents().bindMemory(to: MSDFGlyphVertex.self, capacity: count)
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
