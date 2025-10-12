//
//  Renderer.swift
//  MSDFTextRender
//
//  Created by Sihao Lu on 10/8/25.
//

import Metal
import MetalKit
import simd
import CoreText
import MSDFText

let maxBuffersInFlight = 3

class Renderer: NSObject, MTKViewDelegate {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var atlasTexture: MTLTexture
    var atlasData: MSDFText.MSDFAtlas
    let textContent: String
    weak var view: MTKView?
    var textMeshBuilder: MSDFText.MSDFTextMeshBuilder?
    var textMesh: MSDFText.MSDFTextMesh?
    var msdfRenderer: MSDFText.MSDFTextRenderer
    
    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    
    var zoomScale: CGFloat = 1.0
    
    let margin: CGFloat = 16.0
    let baseFontSize: CGFloat = 36.0
    private let baseFont: CTFont
    private var currentFontSize: CGFloat
    var atlasPxRange: SIMD2<Float>
    var textColor = SIMD4<Float>(1, 1, 1, 1)
    // Render style: 0 = normal, 1 = hollow
    var renderMode: UInt32 = 0
    var strokeColor = SIMD4<Float>(0.0, 0.75, 1.0, 1.0) // Cyan border by default
    var strokeWidthPx: Float = 2.0
    var strokeFeatherPx: Float = 1.0

    @MainActor
    init?(metalKitView: MTKView) {
        guard let device = metalKitView.device,
              let queue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = queue
        
        metalKitView.depthStencilPixelFormat = .invalid
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1
        
        guard let atlasJSONURL = Bundle.main.url(forResource: "SF-Pro-Display_mtsdf", withExtension: "json"),
              let fontURL = Bundle.main.url(forResource: "SF-Pro-Display-Regular", withExtension: "otf") else {
            print("Missing MSDF resources in bundle.")
            return nil
        }
        
        do {
            atlasData = try MSDFText.MSDFAtlas.load(from: atlasJSONURL)
            atlasPxRange = atlasData.pxRange
            atlasTexture = try Renderer.loadTexture(device: device)
        } catch {
            print("Unable to load atlas resources. Error: \(error)")
            return nil
        }
        
        do {
            msdfRenderer = try MSDFText.MSDFTextRenderer(device: device,
                                                         pixelFormat: metalKitView.colorPixelFormat,
                                                         sampleCount: metalKitView.sampleCount,
                                                         atlasPxRange: atlasPxRange)
        } catch {
            print("Unable to create MSDFTextRenderer. Error: \(error)")
            return nil
        }
        
        guard let ctFont = Renderer.loadFont(at: fontURL, size: baseFontSize) else {
            print("Unable to load SF Pro Display font.")
            return nil
        }
        
        baseFont = ctFont
        currentFontSize = baseFontSize
        textMeshBuilder = MSDFText.MSDFTextMeshBuilder(device: device, atlas: atlasData, font: ctFont)
        
        textContent = Renderer.composeParagraphText()
        super.init()
        
        view = metalKitView
        
        rebuildTextMesh(for: metalKitView)
        updateProjection(for: metalKitView.drawableSize)
    }
    
    class func loadTexture(device: MTLDevice) throws -> MTLTexture {
        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        guard let url = Bundle.main.url(forResource: "SF-Pro-Display_mtsdf", withExtension: "png") else {
            throw NSError(domain: "Renderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SF-Pro-Display_mtsdf.png from bundle"])
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(domain: "Renderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load SF-Pro-Display_mtsdf.png from bundle"])
        }
        return try textureLoader.newTexture(cgImage: cgImage, options: options)
    }
    
    private static func loadFont(at url: URL, size: CGFloat) -> CTFont? {
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(dataProvider) else {
            return nil
        }
        
        // Use the new API for iOS 18+ and fall back to the deprecated one for older versions
        if #available(iOS 18.0, *) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                if let cfError = error?.takeRetainedValue() {
                    let codeValue = CFErrorGetCode(cfError)
                    if let ctError = CTFontManagerError(rawValue: codeValue),
                       ctError == .alreadyRegistered {
                        // Font already registered; safe to ignore.
                    } else {
                        print("Font registration error: \(cfError)")
                    }
                }
            }
        } else {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterGraphicsFont(cgFont, &error) {
                if let cfError = error?.takeRetainedValue() {
                    let codeValue = CFErrorGetCode(cfError)
                    if let ctError = CTFontManagerError(rawValue: codeValue),
                       ctError == .alreadyRegistered {
                        // Font already registered; safe to ignore.
                    } else {
                        print("Font registration error: \(cfError)")
                    }
                }
            }
        }
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
    }
    
    private func rebuildTextMesh(for view: MTKView) {
        guard let builder = textMeshBuilder else { return }
        updateFontForCurrentZoom()
        let viewScale = max(CGFloat(view.contentScaleFactor), 0.0001)
        let layoutWidth = max(view.bounds.width, 1.0)
        let layoutHeight = max(view.bounds.height, 1.0)
        textMesh = builder.buildMesh(for: textContent,
                                     in: CGSize(width: layoutWidth, height: layoutHeight),
                                     margin: margin,
                                     scale: viewScale)
    }
    
    private func updateProjection(for drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        msdfRenderer.setOrthoProjection(width: Float(drawableSize.width),
                                        height: Float(drawableSize.height))
    }
    
    private func updateFontForCurrentZoom() {
        let targetSize = max(baseFontSize * zoomScale, 0.0001)
        guard abs(targetSize - currentFontSize) > 0.0001 else { return }
        let scaledFont = CTFontCreateCopyWithAttributes(baseFont, targetSize, nil, nil)
        textMeshBuilder?.updateFont(scaledFont)
        currentFontSize = targetSize
    }
    
    
    
    func draw(in view: MTKView) {
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        
        guard let textMesh = textMesh else {
            inFlightSemaphore.signal()
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        
        commandBuffer.label = "TextCommandBuffer"
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        msdfRenderer.beginFrame()
        
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }
        
        renderEncoder.label = "MSDF Text Encoder"
        let style = MSDFText.MSDFTextRenderStyle(textColor: textColor,
                                                 renderMode: renderMode,
                                                 strokeColor: strokeColor,
                                                 strokeWidthPx: strokeWidthPx,
                                                 strokeFeatherPx: strokeFeatherPx)
        msdfRenderer.encode(encoder: renderEncoder,
                            mesh: textMesh,
                            atlasTexture: atlasTexture,
                            style: style)
        renderEncoder.endEncoding()
        
        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateProjection(for: size)
        rebuildTextMesh(for: view)
    }
    
    @MainActor
    func rebuildTextMeshForCurrentView() {
        guard let view = view else { return }
        rebuildTextMesh(for: view)
    }
    
    @MainActor
    func updateZoom(zoomScale: CGFloat) {
        self.zoomScale = max(zoomScale, 0.0001)
        updateFontForCurrentZoom()
    }

    // MARK: - Public API
    @MainActor
    func setRenderMode(isHollow: Bool) {
        renderMode = isHollow ? 1 : 0
    }
    
    private static func composeParagraphText() -> String {
        return """
        ABCDEFGHIJKLMNOPQRSTUVWXYZ
        abcdefghijklmnopqrstuvwxyz
        1234567890
        """
    }
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
