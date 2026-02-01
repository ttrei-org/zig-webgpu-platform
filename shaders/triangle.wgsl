// Triangle shader for basic WebGPU rendering
//
// This shader handles vertex transformation and fragment coloring for triangles.
// It is designed to work with the Renderer module in the zig-gui-experiment project.
//
// The shader expects vertices with position and color attributes, transforms them
// from screen space to clip space, and outputs interpolated colors for fragment shading.
//
// Coordinate system transformation:
// - Screen space: origin at top-left, Y increases downward, units in pixels
// - Clip space (NDC): origin at center, Y increases upward, range [-1, 1]

// Uniform buffer for screen dimensions
// Required for transforming screen coordinates to normalized device coordinates
struct ScreenUniforms {
    width: f32,   // Screen width in pixels
    height: f32,  // Screen height in pixels
}

@group(0) @binding(0)
var<uniform> screen: ScreenUniforms;

// Vertex input structure - defines the per-vertex attributes
// This will be populated from vertex buffers bound during rendering
struct VertexInput {
    @location(0) position: vec2<f32>,  // 2D position in screen coordinates (pixels)
    @location(1) color: vec3<f32>,     // RGB vertex color for interpolation
}

// Vertex output / Fragment input structure
// Data passed from vertex shader to fragment shader via rasterizer interpolation
struct VertexOutput {
    @builtin(position) position: vec4<f32>,  // Clip-space position (required output)
    @location(0) color: vec3<f32>,           // Interpolated color for fragment shader
}

// Vertex shader entry point
// Transforms vertex positions from screen space to clip space and passes color through
@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    
    // Transform screen coordinates to clip space (NDC)
    // Screen space: origin top-left, Y down, range [0, width] x [0, height]
    // Clip space: origin center, Y up, range [-1, 1] x [-1, 1]
    //
    // Formula:
    //   ndc.x = (screen.x / width) * 2.0 - 1.0
    //   ndc.y = 1.0 - (screen.y / height) * 2.0
    let ndc_x = (input.position.x / screen.width) * 2.0 - 1.0;
    let ndc_y = 1.0 - (input.position.y / screen.height) * 2.0;
    
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
    // Output RGB color with full opacity (alpha = 1.0)
    return vec4<f32>(input.color, 1.0);
}
