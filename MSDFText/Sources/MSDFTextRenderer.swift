import Foundation
import Metal
import simd

// MARK: - Shared types

public struct MSDFTextRenderStyle {
    public var textColor: SIMD4<Float>
    public var renderMode: UInt32 // 0 = fill, 1 = hollow
    public var strokeColor: SIMD4<Float>
    public var strokeWidthPx: Float
    public var strokeFeatherPx: Float

    public init(textColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                renderMode: UInt32 = 0,
                strokeColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.75, 1.0, 1.0),
                strokeWidthPx: Float = 2.0,
                strokeFeatherPx: Float = 1.0) {
        self.textColor = textColor
        self.renderMode = renderMode
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
        self.strokeFeatherPx = strokeFeatherPx
    }
}

enum _MSDFBufferIndex: Int {
    case meshPositions = 0
    case meshGenerics = 1
    case uniforms = 2
}

enum _MSDFVertexAttribute: Int {
    case position = 0
    case texcoord = 1
}

public struct MSDFUniforms {
    public var projectionMatrix: matrix_float4x4
    public var modelViewMatrix: matrix_float4x4
    public var textColor: SIMD4<Float>
    public var unitRange: SIMD2<Float>
    public var strokeColor: SIMD4<Float> // Border color (rgba)
    public var renderOptions: SIMD2<UInt32> // x: render mode (0=normal, 1=hollow)
    public var strokeParams: SIMD2<Float> // x: stroke width in px, y: feather px

    public init() {
        self.projectionMatrix = matrix_identity_float4x4
        self.modelViewMatrix = matrix_identity_float4x4
        self.textColor = SIMD4<Float>(1, 1, 1, 1)
        self.unitRange = SIMD2<Float>(0, 0)
        self.strokeColor = SIMD4<Float>(0, 0, 0, 0)
        self.renderOptions = SIMD2<UInt32>(0, 0)
        self.strokeParams = SIMD2<Float>(0, 0)
    }
}

private let _alignedUniformsSize = (MemoryLayout<MSDFUniforms>.size + 0xFF) & -0x100

// MARK: - Renderer

public final class MSDFTextRenderer {
    public let device: MTLDevice
    public let pipelineState: MTLRenderPipelineState
    public let depthState: MTLDepthStencilState

    private let dynamicUniformBuffer: MTLBuffer
    private var uniformBufferOffset = 0
    private var uniformBufferIndex = 0
    private var uniformsPtr: UnsafeMutablePointer<MSDFUniforms>

    public var projectionMatrix: matrix_float4x4 = matrix_identity_float4x4
    public var modelViewMatrix: matrix_float4x4 = matrix_identity_float4x4

    // Distance range in texels from the atlas metadata
    private let atlasPxRange: SIMD2<Float>

    public init(device: MTLDevice,
                pixelFormat: MTLPixelFormat,
                sampleCount: Int = 1,
                atlasPxRange: SIMD2<Float>) throws {
        self.device = device
        self.atlasPxRange = atlasPxRange

        // Triple-buffer uniforms
        let uniformBufferSize = _alignedUniformsSize * 3
        guard let buffer = device.makeBuffer(length: uniformBufferSize, options: .storageModeShared) else {
            throw NSError(domain: "MSDFTextRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate uniform buffer"])
        }
        buffer.label = "MSDFText.Uniforms"
        self.dynamicUniformBuffer = buffer
        self.uniformsPtr = UnsafeMutableRawPointer(dynamicUniformBuffer.contents())
            .bindMemory(to: MSDFUniforms.self, capacity: 1)

        // Pipeline
        let vertexDescriptor = Self.buildMetalVertexDescriptor()
        self.pipelineState = try Self.buildRenderPipeline(device: device,
                                                          pixelFormat: pixelFormat,
                                                          sampleCount: sampleCount,
                                                          vertexDescriptor: vertexDescriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw NSError(domain: "MSDFTextRenderer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to create depth state"])
        }
        self.depthState = depthState
    }

    public func beginFrame() {
        uniformBufferIndex = (uniformBufferIndex + 1) % 3
        uniformBufferOffset = _alignedUniformsSize * uniformBufferIndex
        uniformsPtr = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset)
            .bindMemory(to: MSDFUniforms.self, capacity: 1)
    }

    public func setOrthoProjection(width: Float, height: Float) {
        let sx: Float = width != 0 ? 2.0 / width : 0
        let sy: Float = height != 0 ? -2.0 / height : 0
        projectionMatrix = matrix_float4x4(columns: (
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        ))
    }

    public func encode(encoder: MTLRenderCommandEncoder,
                       mesh: MSDFTextMesh,
                       atlasTexture: MTLTexture,
                       style: MSDFTextRenderStyle) {
        // Update uniforms
        var uniforms = MSDFUniforms()
        uniforms.projectionMatrix = projectionMatrix
        uniforms.modelViewMatrix = modelViewMatrix
        uniforms.textColor = style.textColor
        let unitRange = SIMD2<Float>(atlasPxRange.x / Float(atlasTexture.width),
                                     atlasPxRange.y / Float(atlasTexture.height))
        uniforms.unitRange = unitRange
        uniforms.strokeColor = style.strokeColor
        uniforms.renderOptions = SIMD2<UInt32>(style.renderMode, 0)
        uniforms.strokeParams = SIMD2<Float>(style.strokeWidthPx, style.strokeFeatherPx)

        uniformsPtr[0] = uniforms

        // Encode draw
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: _MSDFBufferIndex.meshPositions.rawValue)
        encoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: _MSDFBufferIndex.uniforms.rawValue)
        encoder.setFragmentBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: _MSDFBufferIndex.uniforms.rawValue)
        encoder.setFragmentTexture(atlasTexture, index: 0)

        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
    }

    // MARK: - Helpers

    public static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = _MSDFBufferIndex.meshPositions.rawValue

        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = _MSDFBufferIndex.meshPositions.rawValue

        vertexDescriptor.layouts[0].stride = MemoryLayout<MSDFGlyphVertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        return vertexDescriptor
    }

    private static func buildRenderPipeline(device: MTLDevice,
                                            pixelFormat: MTLPixelFormat,
                                            sampleCount: Int,
                                            vertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library: MTLLibrary = try device.makeDefaultLibrary(bundle: .module)
        guard let vfn = library.makeFunction(name: "msdfVertexShader"),
              let ffn = library.makeFunction(name: "msdfFragmentShader") else {
            throw NSError(domain: "MSDFTextRenderer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Metal shader functions not found in default library"])
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "MSDFText.Pipeline"
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.vertexDescriptor = vertexDescriptor
        desc.rasterSampleCount = sampleCount
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.depthAttachmentPixelFormat = .invalid
        desc.stencilAttachmentPixelFormat = .invalid

        if let attachment = desc.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.rgbBlendOperation = .add
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            attachment.alphaBlendOperation = .add
        }

        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
