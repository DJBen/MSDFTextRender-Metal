import simd

// Must match OutlinedUniforms in OutlinedShaders.metal
struct OutlinedUniforms {
    var projectionMatrix: matrix_float4x4 = matrix_identity_float4x4
    var modelViewMatrix: matrix_float4x4 = matrix_identity_float4x4
    var textColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var unitRange: SIMD2<Float> = SIMD2<Float>(0, 0)
    var strokeColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    var renderOptions: SIMD2<UInt32> = SIMD2<UInt32>(0, 0)
    var strokeParams: SIMD2<Float> = SIMD2<Float>(0, 0)
    var _padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}
