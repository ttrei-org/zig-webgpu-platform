// Triangle shader for basic WebGPU rendering
//
// This shader handles vertex transformation and fragment coloring for triangles.
// It is designed to work with the Renderer module in the zig-gui-experiment project.
//
// The shader expects vertices with position and color attributes, transforms them
// through clip space, and outputs interpolated colors for fragment shading.

// Vertex input structure - defines the per-vertex attributes
// This will be populated from vertex buffers bound during rendering
struct VertexInput {
    @location(0) position: vec2<f32>,  // 2D position in normalized device coordinates
    @location(1) color: vec3<f32>,     // RGB vertex color for interpolation
}

// Vertex output / Fragment input structure
// Data passed from vertex shader to fragment shader via rasterizer interpolation
struct VertexOutput {
    @builtin(position) position: vec4<f32>,  // Clip-space position (required output)
    @location(0) color: vec3<f32>,           // Interpolated color for fragment shader
}

// Vertex shader entry point
// Transforms vertex positions and passes color through for interpolation
@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    // Convert 2D position to 4D clip-space (z=0, w=1 for 2D rendering)
    output.position = vec4<f32>(input.position, 0.0, 1.0);
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
