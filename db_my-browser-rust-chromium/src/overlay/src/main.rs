mod input;
mod webrender;

use cef::{args::Args, *};
use std::{cell::RefCell, process::ExitCode, sync::Arc, thread::sleep, time::Duration};
use wgpu::{Backends, CurrentSurfaceTexture, util::DeviceExt};
use winit::{
    application::ApplicationHandler,
    event::{KeyEvent as WinitKeyEvent, MouseButton, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    platform::pump_events::{EventLoopExtPumpEvents, PumpStatus},
    window::{Window, WindowAttributes, WindowId},
};

use crate::input::{ContentRect, HitTarget, MouseButtons};

use crate::webrender::{
    ClientBuilder, OsrApp, OsrRenderHandler, OsrRequestContextHandler,
    RequestContextHandlerBuilder, TEXTURE,
};

// ponytail: static default for the content rect's top offset until the shell
// reports its own chrome height over the P1 state channel (see
// `input::content_rect`'s doc comment). Overridable via `--chrome-height=`.
const DEFAULT_CHROME_HEIGHT: f32 = 88.0;

struct State {
    window: Arc<Window>,
    device: wgpu::Device,
    pipeline: wgpu::RenderPipeline,
    queue: wgpu::Queue,
    size: winit::dpi::PhysicalSize<u32>,
    surface: wgpu::Surface<'static>,
    surface_format: wgpu::TextureFormat,
    /// Chrome quad: covers the whole window.
    quad: Geometry,
    /// Content quad: the sub-rect below the chrome rows (see
    /// `content_quad_geometry`); rebuilt whenever the window resizes.
    content_quad: Geometry,
}

impl State {
    async fn new(window: Arc<Window>, chrome_height: f32) -> State {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            #[cfg(target_os = "windows")]
            backends: Backends::from_comma_list("dx12"),
            #[cfg(target_os = "macos")]
            backends: Backends::from_comma_list("metal"),
            // Vulkan-only panics with NoAdapter on boxes with no usable Vulkan ICD; fall
            // back to GL, and still honour WGPU_BACKEND if the user set it.
            #[cfg(target_os = "linux")]
            backends: Backends::from_env().unwrap_or(Backends::VULKAN | Backends::GL),
            //flags: wgpu::InstanceFlags::debugging(),
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = match instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                ..Default::default()
            })
            .await
        {
            Ok(adapter) => adapter,
            Err(err) => {
                // Retry with no constraints/low power before giving up, in case the
                // preferred adapter (e.g. a discrete GPU) isn't available.
                eprintln!("primary wgpu adapter request failed ({err:?}), retrying with LowPower");
                instance
                    .request_adapter(&wgpu::RequestAdapterOptions {
                        power_preference: wgpu::PowerPreference::LowPower,
                        ..Default::default()
                    })
                    .await
                    .expect(
                        "no wgpu adapter available: check GPU drivers / Vulkan or GL ICD installation",
                    )
            }
        };
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                required_limits: wgpu::Limits {
                    max_non_sampler_bindings: 2048,
                    ..Default::default()
                },
                ..Default::default()
            })
            .await
            .unwrap();

        let size = window.inner_size();

        let surface = instance.create_surface(window.clone()).unwrap();
        let surface_format = wgpu::TextureFormat::Bgra8Unorm;
        let texture_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Cef Texture Bind Group Layout"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            multisampled: false,
                            view_dimension: wgpu::TextureViewDimension::D2,
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Cef Shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        let render_pipeline_layout =
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("Cef Pipeline Layout"),
                bind_group_layouts: &[Some(&texture_bind_group_layout)],
                immediate_size: 0,
            });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Cef Render Pipeline"),
            layout: Some(&render_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[Some(Vertex::desc())],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: Some(wgpu::BlendState {
                        color: wgpu::BlendComponent::OVER,
                        alpha: wgpu::BlendComponent::OVER,
                    }),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Cw,
                cull_mode: Some(wgpu::Face::Back),
                polygon_mode: wgpu::PolygonMode::Fill,
                unclipped_depth: false,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState {
                count: 1,
                mask: !0,
                alpha_to_coverage_enabled: false,
            },
            multiview_mask: None,
            cache: None,
        });
        let quad = Geometry::new(&device, -1.0, 1.0, 2.0, 2.0);
        let content_quad =
            Self::content_quad_geometry(&device, size, chrome_height, window.scale_factor());

        let state = State {
            window,
            pipeline,
            device,
            queue,
            size,
            surface,
            surface_format,
            quad,
            content_quad,
        };

        state.configure_surface();

        state
    }

    fn get_window(&self) -> &Window {
        &self.window
    }

    fn configure_surface(&self) {
        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: self.surface_format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            view_formats: vec![self.surface_format],
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            width: self.size.width,
            height: self.size.height,
            desired_maximum_frame_latency: 2,
            present_mode: wgpu::PresentMode::AutoVsync,
        };
        self.surface.configure(&self.device, &surface_config);
    }

    fn resize(&mut self, new_size: winit::dpi::PhysicalSize<u32>, chrome_height: f32) {
        if new_size.width > 0 && new_size.height > 0 {
            self.size = new_size;
            self.configure_surface();
            self.content_quad = Self::content_quad_geometry(
                &self.device,
                new_size,
                chrome_height,
                self.window.scale_factor(),
            );
        }
    }

    /// Builds the content quad's geometry: an NDC rect matching
    /// `input::content_rect` (full width, below the chrome rows), so the
    /// content browser's texture is drawn in the right place on screen.
    fn content_quad_geometry(
        device: &wgpu::Device,
        size: winit::dpi::PhysicalSize<u32>,
        chrome_height: f32,
        scale_factor: f64,
    ) -> Geometry {
        let logical_width = (size.width as f64 / scale_factor).max(1.0) as f32;
        let logical_height = (size.height as f64 / scale_factor).max(1.0) as f32;
        let rect = input::content_rect(logical_width, logical_height, chrome_height);

        // Logical pixels -> NDC: x in [-1, 1] left-to-right, y in [-1, 1]
        // bottom-to-top (NDC y=1 is the top of the window).
        let x0 = -1.0 + 2.0 * (rect.x / logical_width);
        let x1 = -1.0 + 2.0 * ((rect.x + rect.width) / logical_width);
        let y_top = 1.0 - 2.0 * (rect.y / logical_height);
        let y_bottom = 1.0 - 2.0 * ((rect.y + rect.height) / logical_height);

        Geometry::new(device, x0, y_top, x1 - x0, y_top - y_bottom)
    }

    fn render(&mut self, chrome_id: Option<i32>, content_id: Option<i32>) {
        let surface_texture = match self.surface.get_current_texture() {
            CurrentSurfaceTexture::Success(success) => success,
            CurrentSurfaceTexture::Suboptimal(suboptimal) => {
                self.configure_surface();
                suboptimal
            }
            _ => return,
        };

        let frame = surface_texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor {
                label: Some("Surface"),
                format: Some(wgpu::TextureFormat::Bgra8Unorm),
                ..Default::default()
            });

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Render Encoder"),
            });
        TEXTURE.with_borrow_mut(|textures| {
            let content_bind_group = content_id.and_then(|id| textures.get(&id));
            let chrome_bind_group = chrome_id.and_then(|id| textures.get(&id));
            if content_bind_group.is_none() && chrome_bind_group.is_none() {
                return;
            }
            {
                let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("Cef Render Pass"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &frame,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                            store: wgpu::StoreOp::Store,
                        },
                        depth_slice: None,
                    })],
                    ..Default::default()
                });
                render_pass.set_pipeline(&self.pipeline);
                // Content is drawn first, underneath; chrome is drawn second,
                // on top - its transparent content-row area is where the
                // pipeline's OVER blend lets the content browser show through.
                if let Some(bind_group) = content_bind_group {
                    render_pass.set_bind_group(0, bind_group, &[]);
                    render_pass.set_vertex_buffer(0, self.content_quad.vertex_buffer.slice(..));
                    render_pass.draw(0..self.content_quad.vertex_count, 0..1);
                }
                if let Some(bind_group) = chrome_bind_group {
                    render_pass.set_bind_group(0, bind_group, &[]);
                    render_pass.set_vertex_buffer(0, self.quad.vertex_buffer.slice(..));
                    render_pass.draw(0..self.quad.vertex_count, 0..1);
                }
            }
            self.queue.submit(std::iter::once(encoder.finish()));
        });

        self.window.pre_present_notify();
        self.queue.present(surface_texture);
    }
}

struct App {
    state: Option<State>,
    /// The HTML shell: a full-window CEF browser.
    chrome: Option<BrowserSlot>,
    /// The page: its own CEF browser, composited beneath the chrome's
    /// transparent content area (P3 - this used to be an `<iframe>`, which
    /// sites sending `X-Frame-Options`/`frame-ancestors` simply refuse to
    /// render in).
    content: Option<BrowserSlot>,
    url: String,
    chrome_height: f32,
    cursor_pos: winit::dpi::PhysicalPosition<f64>,
    modifiers: u32,
    buttons: MouseButtons,
    /// Which browser keyboard input goes to. Mouse input is routed per-event
    /// by hit-testing the cursor instead (see `content_rect_for`); only
    /// keyboard events need a sticky notion of "focus".
    focus: Focus,
}

/// Which browser currently has keyboard focus. Defaults to `Chrome`; a mouse
/// press over the content rect switches it to `Content` (see
/// `WindowEvent::MouseInput` below).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Focus {
    Chrome,
    Content,
}

struct BrowserSlot {
    browser: cef::Browser,
    size: std::rc::Rc<RefCell<winit::dpi::LogicalSize<f32>>>,
}

/// Computes the content rect (window-logical pixels) for the window `state`
/// is currently showing. Free function (not an `App` method) so it can be
/// called while a field of `self` (`state`, via `self.state.as_mut()`) is
/// already mutably borrowed in `window_event` below.
fn content_rect_for(state: &State, chrome_height: f32) -> ContentRect {
    let scale = state.get_window().scale_factor();
    let logical = state.get_window().inner_size().to_logical::<f32>(scale);
    input::content_rect(logical.width, logical.height, chrome_height)
}

impl App {
    fn new(url: String, chrome_height: f32) -> Self {
        App {
            state: None,
            chrome: None,
            content: None,
            url,
            chrome_height,
            cursor_pos: winit::dpi::PhysicalPosition::new(0.0, 0.0),
            modifiers: 0,
            buttons: MouseButtons::default(),
            focus: Focus::Chrome,
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let window = Arc::new(
            event_loop
                .create_window(WindowAttributes::default())
                .unwrap(),
        );

        let state = pollster::block_on(State::new(window.clone(), self.chrome_height));
        self.state = Some(state);
        let accelerated_osr = cfg!(all(
            any(
                target_os = "macos",
                target_os = "windows",
                target_os = "linux"
            ),
            feature = "accelerated_osr"
        ));
        let device_scale_factor = window.scale_factor();
        let window_logical = window.inner_size().to_logical::<f32>(device_scale_factor);
        let content_logical_rect =
            input::content_rect(window_logical.width, window_logical.height, self.chrome_height);

        let browser_settings = BrowserSettings {
            windowless_frame_rate: 60,
            ..Default::default()
        };
        let mut context = cef::request_context_create_context(
            Some(&RequestContextSettings::default()),
            Some(&mut RequestContextHandlerBuilder::build(
                OsrRequestContextHandler {},
            )),
        );

        // Chrome browser: the HTML shell, full window - unchanged from the
        // single-browser setup this replaces.
        let chrome_window_info = WindowInfo {
            windowless_rendering_enabled: true as _,
            shared_texture_enabled: accelerated_osr as _,
            external_begin_frame_enabled: accelerated_osr as _,
            ..Default::default()
        };
        let (chrome_render_handler, chrome_size) = OsrRenderHandler::new(
            self.state.as_ref().unwrap().device.clone(),
            self.state.as_ref().unwrap().queue.clone(),
            device_scale_factor as _,
            window_logical,
        );
        let chrome_browser = cef::browser_host_create_browser_sync(
            Some(&chrome_window_info),
            Some(&mut ClientBuilder::build(chrome_render_handler)),
            Some(&CefString::from(self.url.as_str())),
            Some(&browser_settings),
            None,
            context.as_mut(),
        );
        assert!(chrome_browser.is_some());
        self.chrome.replace(BrowserSlot {
            browser: chrome_browser.unwrap(),
            size: chrome_size,
        });

        // Content browser: the page (P3) - its own CEF browser, sized to the
        // rect below the chrome rows, starting blank until a real navigation
        // (P2's `spawn`/URL commands) points it somewhere.
        let content_window_info = WindowInfo {
            windowless_rendering_enabled: true as _,
            shared_texture_enabled: accelerated_osr as _,
            external_begin_frame_enabled: accelerated_osr as _,
            ..Default::default()
        };
        let (content_render_handler, content_size) = OsrRenderHandler::new(
            self.state.as_ref().unwrap().device.clone(),
            self.state.as_ref().unwrap().queue.clone(),
            device_scale_factor as _,
            winit::dpi::LogicalSize::new(content_logical_rect.width, content_logical_rect.height),
        );
        let content_browser = cef::browser_host_create_browser_sync(
            Some(&content_window_info),
            Some(&mut ClientBuilder::build(content_render_handler)),
            Some(&CefString::from("about:blank")),
            Some(&browser_settings),
            None,
            context.as_mut(),
        );
        assert!(content_browser.is_some());
        self.content.replace(BrowserSlot {
            browser: content_browser.unwrap(),
            size: content_size,
        });

        window.request_redraw();
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let state = self.state.as_mut().unwrap();
        match event {
            WindowEvent::CloseRequested => {
                event_loop.exit();
            }
            WindowEvent::RedrawRequested => {
                #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    host.send_external_begin_frame();
                }
                state.render();
                state.get_window().request_redraw();
            }
            WindowEvent::Resized(size) => {
                state.resize(size);
                if let Some(browser) = self.browser.as_mut() {
                    *browser.size.borrow_mut() =
                        size.to_logical(self.state.as_ref().unwrap().get_window().scale_factor());
                    if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                        host.was_resized();
                    }
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor_pos = position;
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    let logical = position.to_logical::<f32>(state.get_window().scale_factor());
                    let mouse_event = MouseEvent {
                        x: logical.x as i32,
                        y: logical.y as i32,
                        modifiers: input::mouse_button_eventflags(self.buttons) | self.modifiers,
                    };
                    host.send_mouse_move_event(Some(&mouse_event), 0);
                }
            }
            WindowEvent::MouseInput {
                state: button_state,
                button,
                ..
            } => {
                let Some(button_type) = cef_mouse_button(button) else {
                    return;
                };
                // Bug fix: stamp the button-down bit into `modifiers` so CEF sees a
                // held button while the cursor moves (drag-to-select). Set the bit
                // before computing modifiers for both press and release, since a
                // mouse-up event still reports the button as down at the instant it
                // happens; only clear it afterwards.
                if let Some(bit) = input::mouse_button_bit(button) {
                    self.buttons.set(bit, true);
                }
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    let logical = self
                        .cursor_pos
                        .to_logical::<f32>(state.get_window().scale_factor());
                    let mouse_event = MouseEvent {
                        x: logical.x as i32,
                        y: logical.y as i32,
                        modifiers: input::mouse_button_eventflags(self.buttons) | self.modifiers,
                    };
                    let mouse_up = !button_state.is_pressed() as i32;
                    host.send_mouse_click_event(Some(&mouse_event), button_type, mouse_up, 1);
                }
                if !button_state.is_pressed() {
                    if let Some(bit) = input::mouse_button_bit(button) {
                        self.buttons.set(bit, false);
                    }
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    let scale_factor = state.get_window().scale_factor();
                    let logical = self.cursor_pos.to_logical::<f32>(scale_factor);
                    let mouse_event = MouseEvent {
                        x: logical.x as i32,
                        y: logical.y as i32,
                        modifiers: input::mouse_button_eventflags(self.buttons) | self.modifiers,
                    };
                    let (delta_x, delta_y) = input::wheel_delta(delta, scale_factor);
                    host.send_mouse_wheel_event(Some(&mouse_event), delta_x, delta_y);
                }
            }
            WindowEvent::ModifiersChanged(mods) => {
                self.modifiers = input::keyboard_eventflags(mods.state());
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    forward_key_event(host, &event, self.modifiers);
                }
            }
            WindowEvent::Focused(focused) => {
                if let Some(host) = self.browser.as_mut().and_then(|b| b.browser.host()) {
                    host.set_focus(focused as i32);
                }
            }
            _ => (),
        }
    }
}

fn cef_mouse_button(button: MouseButton) -> Option<MouseButtonType> {
    match button {
        MouseButton::Left => Some(MouseButtonType::LEFT),
        MouseButton::Middle => Some(MouseButtonType::MIDDLE),
        MouseButton::Right => Some(MouseButtonType::RIGHT),
        _ => None,
    }
}

fn forward_key_event(host: BrowserHost, event: &WinitKeyEvent, modifiers: u32) {
    let translated = input::translate_key_event(
        event.physical_key,
        event.state.is_pressed(),
        event.text.as_deref(),
    );
    let type_ = match translated.action {
        input::KeyAction::Down => KeyEventType::RAWKEYDOWN,
        input::KeyAction::Up => KeyEventType::KEYUP,
    };
    let key_event = KeyEvent {
        type_,
        modifiers,
        windows_key_code: translated.windows_key_code,
        ..Default::default()
    };
    host.send_key_event(Some(&key_event));

    // A RAWKEYDOWN alone does not produce text; CEF also wants a CHAR event with the
    // actual character. `translate_key_event` already skips this on key-up and for
    // control keys (e.g. Enter's text is "\r", which is not something we want typed
    // into a text field).
    if let Some(char_code) = translated.char_code {
        let char_event = KeyEvent {
            type_: KeyEventType::CHAR,
            modifiers,
            windows_key_code: translated.windows_key_code,
            character: char_code,
            unmodified_character: char_code,
            ..Default::default()
        };
        host.send_key_event(Some(&char_event));
    }
}

fn main() -> std::process::ExitCode {
    #[cfg(all(target_os = "windows", debug_assertions))]
    pix::load_winpix_gpu_capturer().unwrap();

    #[cfg(target_os = "macos")]
    let _loader = {
        let loader = library_loader::LibraryLoader::new(&std::env::current_exe().unwrap(), false);
        assert!(loader.load());
        loader
    };

    env_logger::init();

    let _ = api_hash(sys::CEF_API_VERSION_LAST, 0);

    let args = Args::new();
    let cmd = args.as_cmd_line().unwrap();

    let url_switch = CefString::from("url");
    let url = if cmd.has_switch(Some(&url_switch)) == 1 {
        CefString::from(&cmd.switch_value(Some(&url_switch))).to_string()
    } else {
        "about:blank".to_string()
    };

    let switch = CefString::from("type");
    let is_browser_process = cmd.has_switch(Some(&switch)) != 1;
    let mut app = webrender::AppBuilder::build(OsrApp::new());
    let ret = execute_process(
        Some(args.as_main_args()),
        Some(&mut app),
        std::ptr::null_mut(),
    );

    if is_browser_process {
        assert!(ret == -1, "cannot execute browser process");
    } else {
        let process_type = CefString::from(&cmd.switch_value(Some(&switch)));
        println!("launch process {process_type}");
        assert!(ret >= 0, "cannot execute non-browser process");
        // non-browser process does not initialize cef
        return 0.into();
    }
    let settings = Settings {
        windowless_rendering_enabled: true as _,
        external_message_pump: true as _,
        ..Default::default()
    };
    assert_eq!(
        initialize(
            Some(args.as_main_args()),
            Some(&settings),
            Some(&mut app),
            std::ptr::null_mut(),
        ),
        1
    );

    let mut event_loop = EventLoop::new().unwrap();

    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::new(url);
    let ret = loop {
        do_message_loop_work();
        let timeout = Some(Duration::ZERO);
        let status = event_loop.pump_app_events(timeout, &mut app);

        if let PumpStatus::Exit(exit_code) = status {
            break ExitCode::from(exit_code as u8);
        }

        sleep(Duration::from_millis(1000 / 17));
    };
    cef::shutdown();
    ret
}

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex {
    position: [f32; 3],
    tex_coords: [f32; 2],
}

impl Vertex {
    const ATTRIBS: [wgpu::VertexAttribute; 2] =
        wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x2];

    fn desc<'a>() -> wgpu::VertexBufferLayout<'a> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Self>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &Self::ATTRIBS,
        }
    }
}

struct Geometry {
    vertex_buffer: wgpu::Buffer,
    vertex_count: u32,
}

impl Geometry {
    /// Builds a quad in NDC space: `x`/`y` is the top-left corner, `width` and
    /// `height` its extent (subtracted from `y` for the bottom edge, matching
    /// NDC's bottom-to-top y axis). The whole source texture is mapped onto
    /// it (`tex_coords` span `0.0..1.0`).
    fn new(device: &wgpu::Device, x: f32, y: f32, width: f32, height: f32) -> Self {
        let z = 1.0; // Z value for 2D quad

        let vertices = [
            Vertex {
                position: [x, y, z],
                tex_coords: [0.0, 0.0],
            },
            Vertex {
                position: [x + width, y, z],
                tex_coords: [1.0, 0.0],
            },
            Vertex {
                position: [x, y - height, z],
                tex_coords: [0.0, 1.0],
            },
            Vertex {
                position: [x + width, y - height, z],
                tex_coords: [1.0, 1.0],
            },
        ];

        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Quad Vertex Buffer"),
            contents: bytemuck::cast_slice(&vertices),
            usage: wgpu::BufferUsages::VERTEX,
        });

        Self {
            vertex_buffer,
            vertex_count: vertices.len() as u32,
        }
    }
}

#[cfg(all(target_os = "windows", debug_assertions))]
mod pix {
    use libloading::Library;
    use std::io::{Error, ErrorKind, Result};
    use std::path::PathBuf;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::core::{HSTRING, PCWSTR};

    fn get_latest_winpix_gpu_capturer_path() -> PathBuf {
        PathBuf::from(r"C:\Program Files")
            .join("Microsoft PIX")
            .join("2505.30")
            .join("WinPixGpuCapturer.dll")
    }

    pub fn load_winpix_gpu_capturer() -> Result<()> {
        let module_name = HSTRING::from("WinPixGpuCapturer.dll");

        unsafe {
            let module_pcwstr = PCWSTR::from_raw(module_name.as_ptr());
            let is_loaded = GetModuleHandleW(module_pcwstr).is_ok();

            if !is_loaded {
                let path = get_latest_winpix_gpu_capturer_path();

                if !path.exists() {
                    return Err(Error::new(
                        ErrorKind::NotFound,
                        format!("WinPixGpuCapturer.dll not found at {}", path.display()),
                    ));
                }

                match Library::new(&path) {
                    Ok(lib) => {
                        use std::sync::Once;
                        static INIT: Once = Once::new();
                        static mut LIBRARY: Option<Library> = None;

                        INIT.call_once(|| {
                            LIBRARY = Some(lib);
                        });

                        Ok(())
                    }
                    Err(e) => Err(Error::other(format!(
                        "Failed to load WinPixGpuCapturer.dll: {e}"
                    ))),
                }
            } else {
                Ok(())
            }
        }
    }
}
