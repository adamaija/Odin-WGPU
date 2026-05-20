package odin_wgpu

import "core:sys/wasm/js"
import "vendor:wgpu"
import "base:runtime"

import "core:math"
import "core:math/linalg" /* lisätty */

OS :: struct {
	initialized: bool,
    clipboard: [dynamic]byte
}

// Local tracking for touch movement deltas.
@(private = "file")
touch_last_pos: [2]i32
@(private = "file")
touch_last_pos_valid: bool

// Install OS-level hooks (resize listener).
os_init :: proc() {
	ok := js.add_window_event_listener(.Resize, nil, size_callback);        assert(ok)
	ok =  js.add_window_event_listener(.Key_Down, nil, key_down_callback);  assert(ok)
	ok =  js.add_window_event_listener(.Key_Up, nil, key_up_callback);	    assert(ok)
	ok =  js.add_event_listener("playBtn", .Click, nil, pause_callback);    assert(ok)
	ok =  js.add_event_listener("resetBtn", .Click, nil, reset_callback);   assert(ok)
	ok =  js.add_event_listener("rotateBtn", .Click, nil, rotate_callback);    assert(ok)
 
    // Mouse controls
	ok =  js.add_event_listener("wgpu-canvas", .Mouse_Move, nil, mouse_move_callback); assert(ok)
	ok =  js.add_event_listener("wgpu-canvas", .Mouse_Down, nil, mouse_down_callback); assert(ok)
	ok =  js.add_event_listener("wgpu-canvas", .Mouse_Up, nil, mouse_up_callback);     assert(ok)
	ok =  js.add_event_listener("wgpu-canvas", .Wheel, nil, mwheel_callback);          assert(ok)
    
}


// NOTE: frame loop is done by the runtime.js repeatedly calling `step`.
// Mark the OS loop as ready so `step` begins rendering.
os_run :: proc() {
	g.os.initialized = true
}

// Runtime callback: called every tick from JS to drive rendering.
@(private="file", export)
step :: proc(dt: f32) -> bool {
	if !g.os.initialized {
		return true
	}
    g.dt = dt
    update()
	frame()
	return true
}

@(export)
set_zoom :: proc(v: f32) {
	camera.distance = v
}

@(export)
get_zoom :: proc() -> f32 {
	return camera.distance
}


@(export)
set_dev :: proc(x,y,z:f32) {
    g.params.dev = {x,y,z}
    g.params_dirty = true
}

@(export)
set_mean :: proc(x,y,z:f32) {
    g.params.mean = {x,y,z}
    g.params_dirty = true
}

/* tässä uus */
@(export)
set_height :: proc(v: f32) {
    pitch := linalg.to_radians(camera.pitch)
    camera.target.y =
        v - camera.distance * math.sin(pitch)
}

@(export)
get_height :: proc() -> f32 {
    pitch := linalg.to_radians(camera.pitch)
    return camera.target.y +
           camera.distance * math.sin(pitch)
}

@(export)
get_fov :: proc() -> f32 {
	return camera.fov
}

@(export)
set_fov :: proc(v: f32) {
	camera.fov = clamp(v, 40, 140)
}

@(export)
set_particle_size :: proc(v: f32) {
	r := &g.r

	r.particle_size = v

	wgpu.QueueWriteBuffer(
		r.queue,
		r.particle_ubo,
		0,
		&ParticleUniform{
			size = v,
		},
		size_of(ParticleUniform),
	)
}

@(export)
update_params_gpu :: proc() {
    r := &g.r

    data := ParamsUniform{
        mean = g.params.mean,
        dev  = g.params.dev,
    }

    wgpu.QueueWriteBuffer(
        r.queue,
        r.params_ubo,
        0,
        &data,
        size_of(data),
    )
}

@(export)
reset_particles :: proc() {
    g.reset = true
}

@(export)
get_particle_size :: proc() -> f32 {
	return g.r.particle_size
}
/*!!*/


@(export)
get_running_state :: proc() -> bool {
    return g.running
}

@(export)
get_rotate_state :: proc() -> bool {
    return g.rotate
}

// Query the canvas size in physical pixels (CSS size * device pixel ratio).
os_get_framebuffer_size :: proc() -> (width, height: u32) {
	rect := js.get_bounding_client_rect("body")

	dpi := f32(js.device_pixel_ratio())
	return u32(f32(rect.width) * dpi), u32(f32(rect.height) * dpi)
}

// Create a WebGPU surface bound to the canvas selector.
os_get_surface :: proc(instance: wgpu.Instance) -> wgpu.Surface {
	return wgpu.InstanceCreateSurface(
		instance,
		&wgpu.SurfaceDescriptor{
			nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{
				sType = .SurfaceSourceCanvasHTMLSelector,
				selector = "#wgpu-canvas",
			},
		},
	)
}

// Finalizer: remove hooks and release GPU resources.
@(private="file", fini)
os_fini :: proc "contextless" () {
	context = runtime.default_context()
	js.remove_window_event_listener(.Resize, nil, size_callback)
	js.remove_event_listener("wgpu-canvas", .Mouse_Move, nil, mouse_move_callback)
	js.remove_window_event_listener(.Mouse_Down, nil, mouse_down_callback)
	js.remove_window_event_listener(.Mouse_Up, nil, mouse_up_callback)
	finish()
}

// Window resize handler: update surface configuration.
@(private="file")
size_callback :: proc(e: js.Event) {
	context = g.ctx
	r_resize()
}

@(private="file")
mouse_move_callback :: proc(e: js.Event) {
	g.mouse_delta += {i32(e.mouse.movement.x), i32(e.mouse.movement.y)}
}

@(private="file")
mouse_down_callback :: proc(e: js.Event) {
	g.lmb_down = 0 in e.mouse.buttons
}

@(private="file")
mouse_up_callback :: proc(e: js.Event) {
	g.lmb_down = 0 in e.mouse.buttons
}



@(private="file")
mwheel_callback :: proc(e: js.Event) {
    if g.shift_down {
        camera.target.y -= f32(e.wheel.delta.y) * camera.zoom_speed
        /* if camera.target.y < 0 do camera.target.y = 0 */
    } else {
        camera.distance += f32(e.wheel.delta.y) * camera.zoom_speed
    }
    clamp_camera()
}

@(private="file")
pause_callback :: proc(e: js.Event) {
	g.running = !g.running
}

@(private="file")
rotate_callback :: proc(e: js.Event) {
	g.rotate = !g.rotate
}

@(private="file")
reset_callback :: proc(e: js.Event) {
	g.reset = true
    g.running = false
}

@(private="file")
key_down_callback :: proc(e: js.Event) {
	switch e.key.code {
		case "Space":
			g.running = !g.running
        case "ShiftLeft", "ShiftRight":
            g.shift_down = true
	}
}

@(private="file")
key_up_callback :: proc(e: js.Event) {
	switch e.key.code {
        case "ShiftLeft", "ShiftRight":
            g.shift_down = false
	}
}