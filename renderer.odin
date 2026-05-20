package odin_wgpu

import "core:fmt"
import "vendor:wgpu"
import "core:math/linalg"
import "core:math"


gfx_base         :: #load("shaders/gfx_base.wgsl")
gfx_2D           :: #load("shaders/gfx_2D.wgsl")
gfx_particle     :: #load("shaders/gfx_particle.wgsl")
compute_particle :: #load("shaders/compute_particle.wgsl")

Renderer :: struct {
	instance:                   wgpu.Instance,
	surface:                    wgpu.Surface,
	adapter:                    wgpu.Adapter,
	device:                     wgpu.Device,
	config:                     wgpu.SurfaceConfiguration,
	queue:                      wgpu.Queue,

	gfx_module:                 wgpu.ShaderModule,
	gfx_pipeline_layout:        wgpu.PipelineLayout,
	gfx_pipeline:               wgpu.RenderPipeline,

	particle_module:            wgpu.ShaderModule,
	particle_pipeline_layout:   wgpu.PipelineLayout,
	particle_pipeline:          wgpu.RenderPipeline,

    grid_vbo:                   wgpu.Buffer,
	cube_vbo:                   wgpu.Buffer,
    quad_vbo:                   wgpu.Buffer,
    ubo:                        wgpu.Buffer,
    particle_ubo: wgpu.Buffer,
    particle_size: f32,
    params_ubo: wgpu.Buffer,
    ubo_bind_group:             wgpu.BindGroup,

    depth_texture:              Texture,

    curr_pass:                  wgpu.RenderPassEncoder,
    curr_encoder:               wgpu.CommandEncoder,
    curr_texture:               wgpu.SurfaceTexture,
    curr_view:                  wgpu.TextureView,

    particle: struct {
        module:             wgpu.ShaderModule,
        ubo:                wgpu.Buffer,
        pipeline:           wgpu.ComputePipeline,
        bind_group:         wgpu.BindGroup,
        buffer:             wgpu.Buffer,
    },

    voxel: Voxels
}

vec4 :: [4]f32
vec3 :: [3]f32
vec2 :: [2]f32

CameraUniform :: struct {
	view: linalg.Matrix4x4f32,
	view_proj: linalg.Matrix4x4f32,
    cam_pos: vec3
}

ParticleUniform :: struct {
	size: f32,
	_pad0: f32,
	_pad1: f32,
	_pad2: f32,
} /* hmmm */

ParamsUniform :: struct {
    mean: [3]f32,
    _pad0: f32,
    dev: [3]f32,
    _pad1: f32,
} /* hmmm?? */

Texture :: struct {
    t: wgpu.Texture,
    v: wgpu.TextureView,
    s: wgpu.Sampler,
}

Particle :: struct {
    pos:    vec3,
    _pad:   f32,
    vel:    vec3,
    life:   f32,
}

QuadVertex :: struct {
    offset: vec3,
    normal: vec3,
}

Vertex :: struct {
    pos: vec3,
    uv: vec2,
}

on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1: rawptr, userdata2: rawptr) {
    context = g.ctx
    if status != .Success || adapter == nil {
        fmt.panicf("request adapter failure: [%v] %s", status, message)
    }
    g.r.adapter = adapter
    wgpu.AdapterRequestDevice(adapter, nil, { callback = on_device })
}

on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1: rawptr, userdata2: rawptr) {
    context = g.ctx
    r := &g.r
    if status != .Success || device == nil {
        fmt.panicf("request device failure: [%v] %s", status, message)
    }
    r.device = device 

    r.queue = wgpu.DeviceGetQueue(r.device)

    width, height := os_get_framebuffer_size()

    r.config = wgpu.SurfaceConfiguration {
        device      = r.device,
        usage       = { .RenderAttachment },
        format      = .BGRA8Unorm,
        width       = width,
        height      = height,
        presentMode = .Fifo,
        alphaMode   = .Opaque,
    }
    setup_gfx()
    create_grid(20)

    switch MODE {
        case .Particles:
            create_particles()
            setup_particle()
        case .Voxels:
            setup_voxels()
    }

    os_run()
}

setup_gfx :: proc() {
    r := &g.r
    wgpu.SurfaceConfigure(r.surface, &r.config)
    create_depth_texture()

    r.quad_vbo = wgpu.DeviceCreateBufferWithDataSlice(r.device, &{
        label = "quad buf",
        usage = {.Vertex}
    }, QUAD_VERTICES); assert(r.quad_vbo != nil)

    r.cube_vbo = wgpu.DeviceCreateBufferWithDataSlice(r.device, &{
        label = "cube buf",
        usage = {.Vertex}
    }, CUBE_VERTICES); assert(r.cube_vbo != nil)

	r.gfx_module = wgpu.DeviceCreateShaderModule(r.device, &{
		label = "GFX module",
		nextInChain = &wgpu.ShaderSourceWGSL{
			sType = .ShaderSourceWGSL,
			code  = string(gfx_base),
		},
	})


    r.ubo = wgpu.DeviceCreateBufferWithDataTyped(r.device, &{
        label = "ubo",
        usage = {.Uniform, .CopyDst}
    }, CameraUniform{}); assert(r.ubo != nil)

    r.particle_ubo = wgpu.DeviceCreateBufferWithDataTyped(r.device, &{
        label = "particle ubo",
        usage = {.Uniform, .CopyDst},
    }, ParticleUniform{size = 1.0}) /* uus */

    r.params_ubo = wgpu.DeviceCreateBuffer(
        r.device,
        &wgpu.BufferDescriptor{
            usage = {.Uniform, .CopyDst},
            size  = size_of(ParamsUniform),
        },
    )

    ubo_bind_group_layout := wgpu.DeviceCreateBindGroupLayout(r.device, &{ /* muok*/
        label = "ubo_bind_group_layout",

        entryCount = 3,
        entries = raw_data([]wgpu.BindGroupLayoutEntry{
            {
                binding = 0,
                visibility = {.Vertex, .Fragment},
                buffer = {
                    type = .Uniform,
                },
            },
            {
                binding = 1,
                visibility = {.Vertex, .Fragment},
                buffer = {
                    type = .Uniform,
                },
            },
            {
                binding = 2,
                visibility = {.Vertex, .Fragment},
                buffer = {
                    type = .Uniform,
                },
            },
        }),
    })
    ; assert(ubo_bind_group_layout != nil)

    
    r.ubo_bind_group = wgpu.DeviceCreateBindGroup(r.device, &{
        label = "ubo_bind_group",
        layout = ubo_bind_group_layout,

        entryCount = 3,
        entries = raw_data([]wgpu.BindGroupEntry{
            {
                binding = 0,
                buffer = r.ubo,
                size = wgpu.BufferGetSize(r.ubo),
            },
            {
                binding = 1,
                buffer = r.particle_ubo,
                size = wgpu.BufferGetSize(r.particle_ubo),
            },
            {
                binding = 2,
                buffer = r.params_ubo,
                size = wgpu.BufferGetSize(r.params_ubo),
            },
        }),
    }); assert(r.ubo_bind_group != nil) /* tää */

    // GFX
    r.gfx_pipeline_layout = wgpu.DeviceCreatePipelineLayout(r.device, &{
        label = "Render pipeline layout",
        bindGroupLayoutCount = 1,
        bindGroupLayouts = raw_data([]wgpu.BindGroupLayout{ubo_bind_group_layout})
    }); assert(r.ubo_bind_group != nil)

    r.gfx_pipeline = wgpu.DeviceCreateRenderPipeline(r.device, &{
        layout = r.gfx_pipeline_layout,
        vertex = {
            module     = r.gfx_module,
            entryPoint = "vs_main",
            bufferCount = 1,
            buffers = raw_data([]wgpu.VertexBufferLayout{
                get_vertex_buffer_layout(Vertex, .Vertex)
            })
        },
        fragment = &{
            module      = r.gfx_module,
            entryPoint  = "fs_main",
            targetCount = 1,
            targets     = &wgpu.ColorTargetState{
                format    = .BGRA8Unorm,
                writeMask = wgpu.ColorWriteMaskFlags_All,
            },
        },
        depthStencil = &{
            format = .Depth32Float,
            depthWriteEnabled = .True,
            depthCompare = .Less,
        },
        primitive = {
            topology = .LineList,

        },
        multisample = {
            count = 1,
            mask  = 0xFFFFFFFF,
        },
    })

    // Particle
    r.particle_module = wgpu.DeviceCreateShaderModule(r.device, &{
        label = "Particle module",
        nextInChain = &wgpu.ShaderSourceWGSL{
            sType = .ShaderSourceWGSL,
            code  = string(gfx_particle),
        },
    })

    r.particle_pipeline_layout = wgpu.DeviceCreatePipelineLayout(r.device, &{
        label = "Particle pipeline layout",
        bindGroupLayoutCount = 1,
        bindGroupLayouts = raw_data([]wgpu.BindGroupLayout{ubo_bind_group_layout})
    }); assert(r.particle_pipeline_layout != nil)

    r.particle_pipeline = wgpu.DeviceCreateRenderPipeline(r.device, &{
        layout = r.particle_pipeline_layout,
        vertex = {
            module     = r.particle_module,
            entryPoint = "vs_main",
            bufferCount = 2,
            buffers = raw_data([]wgpu.VertexBufferLayout{
                get_vertex_buffer_layout(Vertex, .Vertex),
                get_vertex_buffer_layout(Particle, .Instance, location_offset=2),
            }),
        },
        fragment = &{
            module      = r.particle_module,
            entryPoint  = "fs_main",
            targetCount = 1,
            targets     = &wgpu.ColorTargetState{
                format    = .BGRA8Unorm,
                writeMask = wgpu.ColorWriteMaskFlags_All,
            },
        },
        depthStencil = &{
            format = .Depth32Float,
            depthWriteEnabled = .True,
            depthCompare = .Less,
        },
        primitive = {
            topology = .TriangleList,
        },
        multisample = {
            count = 1,
            mask  = 0xFFFFFFFF,
        },
    })
}

import "core:reflect"
import "base:runtime"
get_vertex_buffer_layout :: proc(
    $vertex_type: typeid, 
    step_mode: wgpu.VertexStepMode,
    location_offset := 0,
    loc := #caller_location
) -> wgpu.VertexBufferLayout {
    element_info_from_type :: proc(type: ^runtime.Type_Info, loc := #caller_location) -> wgpu.VertexFormat {
        switch type {
            case type_info_of(f32):  return .Float32
            case type_info_of(vec2): return .Float32x2
            case type_info_of(vec3): return .Float32x3
            case type_info_of(vec4): return .Float32x4
            case type_info_of(u32):  return .Uint32
            case: 
                fmt.println("GG")
                panic("Kaikki on pilalla")
        }
    }

    fields := reflect.struct_field_types(vertex_type)
    attributes := make([]wgpu.VertexAttribute, len(fields), context.temp_allocator)

    layout: wgpu.VertexBufferLayout
    layout.stepMode = step_mode
    layout.arrayStride = size_of(vertex_type)
    layout.attributeCount = len(fields)

    accum: int
    for field, i in fields {
        attributes[i] = {element_info_from_type(field), u64(accum), u32(i+location_offset)}
        accum += field.size
    }
    layout.attributes = raw_data(attributes)
    return layout
}

create_depth_texture :: proc() {
    r := &g.r
    if r.depth_texture != {} {
        wgpu.TextureViewRelease(r.depth_texture.v)
        wgpu.SamplerRelease(r.depth_texture.s)
        wgpu.TextureDestroy(r.depth_texture.t)
    }

    size := wgpu.Extent3D{
        width  = math.max(r.config.width,  1),
        height = math.max(r.config.height, 1),
        depthOrArrayLayers = 1
    }

    desc := wgpu.TextureDescriptor {
        label = "Depth texture",
        size = size,
        mipLevelCount = 1,
        sampleCount = 1,
        dimension = ._2D,
        format = .Depth32Float,
        usage = {.RenderAttachment, .TextureBinding}
    }

    texture := wgpu.DeviceCreateTexture(r.device, &desc)

    view := wgpu.TextureCreateView(texture)
    sampler := wgpu.DeviceCreateSampler(r.device, &{
        addressModeU = .ClampToEdge,
        addressModeV = .ClampToEdge,
        addressModeW = .ClampToEdge,
        magFilter = .Linear,
        minFilter = .Linear,
        mipmapFilter = .Nearest,
        compare = .LessEqual,
        lodMinClamp = 0,
        lodMaxClamp = 100,
        maxAnisotropy = 1
    })

    r.depth_texture = {texture, view, sampler}
}

setup_particle :: proc() {
    r := &g.r
    r.particle.module = wgpu.DeviceCreateShaderModule(r.device, &{
        label = "Compute module",
        nextInChain = &wgpu.ShaderSourceWGSL{
            sType = .ShaderSourceWGSL,
            code  = string(compute_particle),
        },
    })

    r.particle.pipeline = wgpu.DeviceCreateComputePipeline(r.device, &{
        label = "Compute pipeline",
        compute = {
            module = r.particle.module,
            entryPoint = "main"
        }
    })

    r.particle.ubo = wgpu.DeviceCreateBufferWithDataTyped(r.device, &{
        label = "compute_ubo",
        usage = {.Uniform, .CopyDst}
    }, f32(0)); assert(r.particle.ubo != nil)

    r.particle.bind_group = wgpu.DeviceCreateBindGroup(r.device, &{
        label = "Compute bind group",
        layout = wgpu.ComputePipelineGetBindGroupLayout(r.particle.pipeline, 0),
        entryCount = 2,
        entries = raw_data([]wgpu.BindGroupEntry{
            {
                binding = 0,
                offset = 0,
                size = wgpu.BufferGetSize(r.particle.buffer),
                buffer = r.particle.buffer,
            },
            {
                binding = 1,
                offset = 0,
                size = wgpu.BufferGetSize(r.particle.ubo),
                buffer = r.particle.ubo
            }
        })
    }); assert(r.particle.bind_group != nil)
}

r_particle_compute :: proc() {
	r := &g.r
    dt := g.dt
    particle_count := u32(wgpu.BufferGetSize(r.particle.buffer) / size_of(Particle))
	workgroup_count := (particle_count + 63) / 64

	compute_pass := wgpu.CommandEncoderBeginComputePass(r.curr_encoder)

	wgpu.ComputePassEncoderSetPipeline(compute_pass, r.particle.pipeline)
	wgpu.QueueWriteBuffer(r.queue, r.particle.ubo, 0, &dt, size_of(f32))
	wgpu.ComputePassEncoderSetBindGroup(compute_pass, 0, r.particle.bind_group)
	wgpu.ComputePassEncoderDispatchWorkgroups(compute_pass, workgroup_count, 1, 1)

	wgpu.ComputePassEncoderEnd(compute_pass)
}

r_setup_volume :: proc() {
    // v := &g.r.volume
    // device := g.r.device
  

}

r_volume_compute :: proc() {
   

}

r_begin_frame :: proc() -> bool {
	r := &g.r

	r.curr_texture = wgpu.SurfaceGetCurrentTexture(r.surface)

	switch r.curr_texture.status {
        case .SuccessOptimal, .SuccessSuboptimal:
        // All good, could handle suboptimal here.
        case .Timeout, .Outdated, .Lost:
            if r.curr_texture.texture != nil {
                wgpu.TextureRelease(r.curr_texture.texture)
            }
            r_resize()
            return false
        case .OutOfMemory, .DeviceLost:
            // Window is occluded (e.g. minimized), skip this frame.
            return false
        case .Error:
            fmt.panicf("get_current_texture status=%v", r.curr_texture.status)
	}

	r.curr_view = wgpu.TextureCreateView(r.curr_texture.texture, nil)
	r.curr_encoder = wgpu.DeviceCreateCommandEncoder(r.device, nil)

	return true
}

r_resize :: proc() {
	r := &g.r

	width, height := os_get_framebuffer_size()
	r.config.width, r.config.height = width, height
	wgpu.SurfaceConfigure(r.surface, &r.config)
    create_depth_texture()
}


r_present :: proc() {
	r := &g.r

    wgpu.RenderPassEncoderEnd(r.curr_pass)
	wgpu.RenderPassEncoderRelease(r.curr_pass)

	command_buffer := wgpu.CommandEncoderFinish(r.curr_encoder, nil)
	defer wgpu.CommandBufferRelease(command_buffer)

    wgpu.CommandEncoderRelease(r.curr_encoder)

	wgpu.QueueSubmit(r.queue, { command_buffer })
	wgpu.SurfacePresent(r.surface)

	wgpu.TextureViewRelease(r.curr_view)
	wgpu.TextureRelease(r.curr_texture.texture)

}

r_draw_scene :: proc() {
	r := &g.r

	r.curr_pass = wgpu.CommandEncoderBeginRenderPass(r.curr_encoder, &{
		colorAttachmentCount = 1,
		colorAttachments = raw_data([]wgpu.RenderPassColorAttachment{
			{
				view = r.curr_view,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = {0.1, 0.1, 0.1, 1},
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			},
		}),
        depthStencilAttachment = &{
            view = r.depth_texture.v,
            depthLoadOp = .Clear,
            depthClearValue = 1,
            depthStoreOp = .Store,
        }
	})

	wgpu.RenderPassEncoderSetPipeline(r.curr_pass, r.gfx_pipeline)

	proj := create_proj_matrix()
	view := camera_view_matrix()
	vp := proj * view
    ubo := CameraUniform{view = view, view_proj = vp, cam_pos = camera_position()}
	wgpu.QueueWriteBuffer(r.queue, r.ubo, 0, &ubo, size_of(ubo))

	wgpu.RenderPassEncoderSetBindGroup(r.curr_pass, 0, r.ubo_bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 0, r.grid_vbo, 0, wgpu.BufferGetSize(r.grid_vbo))

	grid_vertex_count := u32(wgpu.BufferGetSize(r.grid_vbo) / size_of(Vertex))
	wgpu.RenderPassEncoderDraw(r.curr_pass, grid_vertex_count, instanceCount=1, firstVertex=0, firstInstance=0)

    switch MODE {
    case .Particles:
        particle_count := u32(wgpu.BufferGetSize(g.r.particle.buffer) / size_of(Particle))
        wgpu.RenderPassEncoderSetPipeline(r.curr_pass, r.particle_pipeline)
        wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 0, r.quad_vbo, 0, wgpu.BufferGetSize(r.quad_vbo))
        wgpu.RenderPassEncoderSetVertexBuffer(r.curr_pass, 1, r.particle.buffer, 0, wgpu.BufferGetSize(r.particle.buffer))
        wgpu.RenderPassEncoderDraw(r.curr_pass, 6, instanceCount=particle_count, firstVertex=0, firstInstance=0)
    case .Voxels:
        draw_voxels()
    }
}
