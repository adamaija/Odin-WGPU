package odin_wgpu

import "base:runtime"
import "vendor:wgpu"


PARTICLES :: 250000
MODE :: Mode.Particles

Mode :: enum {
    Particles,
    Voxels
}

g := struct {
	ctx:            runtime.Context,
    dt:             f32,
	os:             OS,
    mouse_delta:    [2]i32,
    lmb_down:       bool,
    shift_down:     bool,
    r:              Renderer,
    running:        bool,
    reset:          bool,
    rotate:         bool,
    params:         SimParams,

    params_dirty: bool
} {
    rotate = true,
    params = {
        dev = {20, 50, 20},
        mean = {20, 50, 20}
    },
    params_dirty = false,
}

SimParams :: struct {
    dev:    vec3,
    mean:   vec3
}


// Entry point: initialize OS bindings and kick off async WebGPU setup.
main :: proc() {
	g.ctx = context
	os_init()
	g.r.instance = wgpu.CreateInstance(nil)
	if g.r.instance == nil {
		panic("WebGPU is not supported")
	}
	g.r.surface = os_get_surface(g.r.instance)

	wgpu.InstanceRequestAdapter(g.r.instance, &{ compatibleSurface = g.r.surface }, { callback = on_adapter })
}

frame :: proc() {
    defer free_all(context.temp_allocator)

    r_begin_frame()

	if g.running do switch MODE {
        case .Particles: r_particle_compute()
        case .Voxels:    voxel_compute()
    }
    r_draw_scene()

    r_present()
}

get_relative_mouse_movement :: proc() -> [2]i32 {
    delta := g.mouse_delta
    g.mouse_delta = {0, 0}
    return delta
}

create_grid :: proc(size: int) {
    r := &g.r
    vertices: [dynamic]Vertex
    defer delete(vertices)
    half := size / 2
    grid_scale: f32 = 20.0
    half_f := f32(half) * grid_scale
    for i in -half..=half {
        x := f32(i) * grid_scale
        z := f32(i) * grid_scale
        append(&vertices, Vertex {pos = {x, 0, -half_f}})
        append(&vertices, Vertex {pos = {x, 0, half_f}})
        append(&vertices, Vertex {pos = {-half_f, 0, z}})
        append(&vertices, Vertex {pos = {half_f, 0, z}})
    }

    r.grid_vbo = wgpu.DeviceCreateBufferWithDataSlice(g.r.device, &{
        label = "Triangle buf",
        usage = {.Vertex}
    }, vertices[:]); assert(r.grid_vbo != nil)
}

maybe_reset :: proc() {
    if !g.reset do return
    defer g.reset = false
    switch MODE {
    case .Particles:
        create_particles()
    case .Voxels:
        create_voxels()
    }
    g.dt = 0
}

import "core:math/rand"
create_particles :: proc() {
	particles := make([]Particle, PARTICLES)
    defer delete(particles)
    dev := g.params.dev
    mean := g.params.mean
    for i in 0..<PARTICLES {
        vx := rand.float32_normal(mean.x, dev.x)
        vy := rand.float32_normal(mean.y, dev.y)
        vz := rand.float32_normal(mean.z, dev.z)

        px := rand.float32_normal(0, 1)
        py := rand.float32_normal(0, 1)
        pz := rand.float32_normal(0, 1)
        if py < 0 do py = 0

        particles[i] = Particle{
            pos = {px, py, pz},
            vel = {vx, vy, vz},
        }
    }

    if g.r.particle.buffer == nil {
        g.r.particle.buffer = wgpu.DeviceCreateBufferWithDataSlice(g.r.device, &{
            label = "Particle buffer",
            usage = {.Storage, .Vertex, .CopyDst}
        }, particles[:]); assert(g.r.particle.buffer != nil)
    } else {
        wgpu.QueueWriteBuffer(g.r.queue, g.r.particle.buffer, 0, raw_data(particles[:]), size_of(Particle) * PARTICLES)
    }
}

update :: proc() {
    if g.lmb_down do update_camera()
    g.mouse_delta = 0;
    if g.rotate do camera.yaw += g.dt * 10
    maybe_reset()
    if g.params_dirty {
        create_particles()
        update_params_gpu()
        g.params_dirty = false
    }
}


// Release all GPU resources in reverse creation order.
finish :: proc() {
    r := &g.r
	wgpu.RenderPipelineRelease(r.gfx_pipeline)
	wgpu.RenderPipelineRelease(r.particle_pipeline)
	wgpu.ComputePipelineRelease(r.particle.pipeline)
	wgpu.PipelineLayoutRelease(r.gfx_pipeline_layout)
	wgpu.PipelineLayoutRelease(r.particle_pipeline_layout)
	wgpu.ShaderModuleRelease(r.gfx_module)
	wgpu.ShaderModuleRelease(r.particle_module)
	wgpu.ShaderModuleRelease(r.particle.module)
	wgpu.QueueRelease(r.queue)
	wgpu.DeviceRelease(r.device)
	wgpu.AdapterRelease(r.adapter)
	wgpu.SurfaceRelease(r.surface)
	wgpu.InstanceRelease(r.instance)
}


