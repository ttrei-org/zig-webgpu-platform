// Triangle shader for basic WebGPU rendering
//
// This shader handles vertex transformation and fragment coloring for triangles.
// It is designed to work with the Renderer module in the zig-gui-experiment project.
//
// The shader expects vertices with position in screen coordinates (pixels) and
// color attributes. The vertex shader transforms screen coordinates to NDC using
// the screen dimensions from a uniform buffer.
//
// Screen coordinate system (input):
// - Origin at top-left of screen
// - X: 0 (left) to screen_width (right)
// - Y: 0 (top) to screen_height (bottom)
//
// NDC coordinate system (output):
// - Origin at center of screen
// - X: -1 (left) to +1 (right)
// - Y: -1 (bottom) to +1 (top)

// Uniform buffer containing screen dimensions for coordinate transformation.
// Matches the Uniforms struct in renderer.zig.
struct Uniforms {
    screen_size: vec2<f32>,  // Screen dimensions in pixels (width, height)
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// Vertex input structure - defines the per-vertex attributes
// This will be populated from vertex buffers bound during rendering
struct VertexInput {
    @location(0) position: vec2<f32>,  // 2D position in screen coordinates (pixels)
    @location(1) color: vec4<f32>,     // RGBA vertex color for interpolation (with alpha)
}

// Vertex output / Fragment input structure
// Data passed from vertex shader to fragment shader via rasterizer interpolation
struct VertexOutput {
    @builtin(position) position: vec4<f32>,  // Clip-space position (required output)
    @location(0) color: vec4<f32>,           // Interpolated RGBA color for fragment shader
}

// Vertex shader entry point
// Transforms screen coordinates to NDC using uniform screen dimensions
@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    
    // Transform screen coordinates (pixels) to NDC (normalized device coordinates).
    // Screen coords: origin top-left, X right, Y down, range [0, screen_size]
    // NDC: origin center, X right, Y up, range [-1, 1]
    let ndc_x = (input.position.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let ndc_y = 1.0 - (input.position.y / uniforms.screen_size.y) * 2.0;
    
    // Convert 2D NDC position to 4D clip-space (z=0, w=1 for 2D rendering)
    output.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
    
    // Pass vertex color through for interpolation across the triangle
    output.color = input.color;
    return output;
}

// Fragment shader entry point
// Outputs the interpolated vertex color as the final pixel color
@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Output full RGBA color (alpha is interpolated from vertices)
    return input.color;
}
