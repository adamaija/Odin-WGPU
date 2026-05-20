struct CameraUniform {
    view: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    cam_pos: vec3<f32>,
    _pad: f32,
};

@group(0) @binding(0)
var<uniform> camera: CameraUniform;

struct ParticleUniform {
    size: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

struct Globals {
    time: f32,
};

@group(0) @binding(0)
var<uniform> globals: Globals;

@group(0) @binding(1)
var<uniform> particle: ParticleUniform;

struct ParamsUniform {
    mean: vec3<f32>,
    _pad0: f32,

    dev: vec3<f32>,
    _pad1: f32,
};

@group(0) @binding(2)
var<uniform> params: ParamsUniform;


struct VertexInput {
    @location(0) offset: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) pos: vec3<f32>,
    @location(3) vel: vec3<f32>,
    @location(4) life: f32,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) life: f32,
    @location(1) v_pos: vec3<f32>,
};

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let right = vec3<f32>(camera.view[0].x, camera.view[1].x, camera.view[2].x);
    let up    = vec3<f32>(camera.view[0].y, camera.view[1].y, camera.view[2].y);
    let size = particle.size;
    let world = input.pos + right * input.offset.x * size + up * input.offset.y * size;
    out.clip_position = camera.view_proj * vec4<f32>(world, 1);
    out.life = input.life;
    out.v_pos = input.pos;
    return out;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let p = normalize(input.v_pos);

    let color = vec3<f32>(
        0.5 + 0.5 * sin(p.x * 3.0 ),
        0.5 + 0.5 * sin(p.y * 3.0 + 2.0),
        0.5 + 0.5 * sin(p.z * 3.0 + 4.0)
    );

    return vec4<f32>(color, 1);
}