//! ONNX Runtime 接入：**不链接、不另带**一份 ORT，而是 dlopen 本进程已有的那份（Windows 上是
//! flutter_onnxruntime 插件随包的 CPU core 或下载的 DirectML core——由 Dart 侧传路径，保证与插件
//! 绑定的是同一个文件；Android 是 AAR 里的 `libonnxruntime.so`；Apple 是静态链进 app 的那份，
//! 从本进程符号表找），取 `OrtGetApiBase` 后经 [ort::set_api] 接上。

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use ort::ep::{self, ExecutionProvider};
use ort::session::Session;
use ort::session::builder::GraphOptimizationLevel;
use ort::value::TensorRef;

use super::tile::SrNet;

/// 推理后端（与 Dart 侧 `UpscaleBackend` 一一对应）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Backend {
    Cpu = 0,
    DirectMl = 1,
    CoreMl = 2,
    Xnnpack = 3,
}

impl Backend {
    pub(crate) fn from_code(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::Cpu),
            1 => Some(Self::DirectMl),
            2 => Some(Self::CoreMl),
            3 => Some(Self::Xnnpack),
            _ => None,
        }
    }
}

struct Loaded {
    _lib: libloading::Library,
    version: String,
    environment: ort::environment::Environment,
}

static RUNTIME: OnceLock<Mutex<Option<Loaded>>> = OnceLock::new();

/// 接上 ORT。同一进程只接一次：之后再调（任何路径）都返回第一次的结果；ORT 一个进程只能有一份。
/// `path` 为 None 时从本进程已加载的符号里找（Apple 静态链接）。返回 ORT 版本串。
pub(crate) fn ensure_loaded(path: Option<&str>) -> Result<String, String> {
    let cell = RUNTIME.get_or_init(|| Mutex::new(None));
    let mut guard = cell.lock().map_err(|_| "runtime lock poisoned".to_string())?;
    if let Some(loaded) = guard.as_ref() {
        return Ok(loaded.version.clone());
    }
    let lib = open_library(path)?;
    let version = unsafe {
        let get_base: libloading::Symbol<unsafe extern "system" fn() -> *const ort::sys::OrtApiBase> =
            lib.get(b"OrtGetApiBase\0").map_err(|e| format!("OrtGetApiBase: {e}"))?;
        let base = get_base();
        if base.is_null() {
            return Err("OrtGetApiBase returned null".into());
        }
        let version = std::ffi::CStr::from_ptr(((*base).GetVersionString)()).to_string_lossy().into_owned();
        let api = ((*base).GetApi)(ort::sys::ORT_API_VERSION);
        if api.is_null() {
            return Err(format!("onnxruntime {version} is older than API {}", ort::sys::ORT_API_VERSION));
        }
        ort::set_api((*api).clone());
        version
    };
    let environment = ort::environment::init().with_name("fushi_upscale").build().map_err(err)?;
    *guard = Some(Loaded { _lib: lib, version: version.clone(), environment });
    Ok(version)
}

fn open_library(path: Option<&str>) -> Result<libloading::Library, String> {
    match path {
        Some(p) => open_path(p).map_err(|e| format!("load {p}: {e}")),
        None => {
            #[cfg(unix)]
            {
                Ok(libloading::os::unix::Library::this().into())
            }
            #[cfg(not(unix))]
            {
                Err("onnxruntime path is required on this platform".into())
            }
        }
    }
}

/// Windows：依赖（DirectML core 旁边的 `DirectML.dll`）从库自己的目录找——默认搜索顺序不含它，ORT 还没被
/// 插件绑定、由这里先加载时会找不到；已被插件加载过时拿到的是同一个模块。
#[cfg(windows)]
fn open_path(path: &str) -> Result<libloading::Library, libloading::Error> {
    use libloading::os::windows::{LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR};
    unsafe {
        libloading::os::windows::Library::load_with_flags(path, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)
    }
    .map(Into::into)
}

#[cfg(not(windows))]
fn open_path(path: &str) -> Result<libloading::Library, libloading::Error> {
    unsafe { libloading::Library::new(path) }
}

/// 这个后端在已接上的 ORT 里可用吗（ORT 未接上时恒 false）。
pub(crate) fn backend_available(backend: Backend) -> bool {
    let loaded = RUNTIME.get().and_then(|m| m.lock().ok().map(|g| g.is_some())).unwrap_or(false);
    if !loaded {
        return false;
    }
    match backend {
        Backend::Cpu => true,
        #[cfg(windows)]
        Backend::DirectMl => ep::DirectML::is_available().unwrap_or(false),
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        Backend::CoreMl => ep::CoreML::is_available().unwrap_or(false),
        #[cfg(target_os = "android")]
        Backend::Xnnpack => ep::XNNPACK::is_available().unwrap_or(false),
        #[allow(unreachable_patterns)]
        _ => false,
    }
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// 一个 ONNX 超分模型的会话。
pub(crate) struct OnnxSr {
    session: Session,
    input: String,
    channels: usize,
    scale: usize,
    offset: usize,
    align: usize,
}

impl OnnxSr {
    /// 建会话并用 `calib` × `calib` 的中灰块跑一次，量出放大倍数与裁边（顺带预热；DirectML 按这个
    /// 形状编译——[super::tile] 的块形状恒定，之后不再重编）。
    pub(crate) fn load(path: &Path, backend: Backend, align: usize, calib: usize, threads: usize) -> Result<Self, String> {
        let environment = {
            let guard = RUNTIME.get().ok_or("onnxruntime not loaded")?.lock().map_err(|_| "runtime lock poisoned")?;
            guard.as_ref().ok_or("onnxruntime not loaded")?.environment.clone()
        };
        let mut builder = Session::builder(&environment)
            .map_err(err)?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(err)?;
        builder = match backend {
            Backend::Cpu => builder.with_intra_threads(threads.max(1)).map_err(err)?,
            #[cfg(windows)]
            Backend::DirectMl => builder
                .with_memory_pattern(false)
                .map_err(err)?
                .with_parallel_execution(false)
                .map_err(err)?
                .with_execution_providers([ep::DirectML::default().build().error_on_failure()])
                .map_err(err)?,
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            Backend::CoreMl => builder
                .with_intra_threads(threads.max(1))
                .map_err(err)?
                // MLProgram：默认的 NeuralNetwork 格式在 ORT 1.23 的 CoreML EP 里建 ArtCNN 会话直接段错误
                // （M4 / macOS 实测，设计文档 §4.2）；MLProgram 正常且与 CPU 输出一致。
                .with_execution_providers([ep::CoreML::default()
                    .with_model_format(ep::coreml::ModelFormat::MLProgram)
                    .build()
                    .error_on_failure()])
                .map_err(err)?,
            #[cfg(target_os = "android")]
            Backend::Xnnpack => builder
                .with_intra_threads(1)
                .map_err(err)?
                .with_execution_providers([ep::XNNPACK::default().build().error_on_failure()])
                .map_err(err)?,
            #[allow(unreachable_patterns)]
            other => return Err(format!("backend {other:?} is not available on this platform")),
        };
        let session = builder.commit_from_file(path).map_err(err)?;
        let first = session.inputs().first().ok_or("model has no input")?;
        let input = first.name().to_string();
        let channels = first
            .dtype()
            .tensor_shape()
            .and_then(|s| s.get(1).copied())
            .filter(|c| *c == 1 || *c == 3)
            .map(|c| c as usize)
            .unwrap_or(3);
        let mut net = Self { session, input, channels, scale: 2, offset: 0, align: align.max(1) };
        let n = calib.div_ceil(net.align) * net.align;
        let (_, oh, _) = net.infer(&vec![0.5f32; net.channels * n * n], n, n)?;
        let scale = ((oh as f32 + 0.5 * n as f32) / n as f32).floor() as usize;
        if scale == 0 || oh > n * scale || (n * scale - oh) % 2 != 0 {
            return Err(format!("cannot infer scale from {n} -> {oh}"));
        }
        net.scale = scale;
        net.offset = (n * scale - oh) / 2;
        Ok(net)
    }
}

impl SrNet for OnnxSr {
    fn channels(&self) -> usize {
        self.channels
    }
    fn scale(&self) -> usize {
        self.scale
    }
    fn offset(&self) -> usize {
        self.offset
    }
    fn align(&self) -> usize {
        self.align
    }
    fn infer(&mut self, input: &[f32], h: usize, w: usize) -> Result<(Vec<f32>, usize, usize), String> {
        let tensor = TensorRef::from_array_view(([1usize, self.channels, h, w], input)).map_err(err)?;
        let outputs = self.session.run(ort::inputs![self.input.as_str() => tensor]).map_err(err)?;
        let (shape, data) = outputs[0].try_extract_tensor::<f32>().map_err(err)?;
        let dims: Vec<i64> = shape.iter().copied().collect();
        if dims.len() != 4 || dims[1] as usize != self.channels {
            return Err(format!("unexpected output shape {dims:?}"));
        }
        Ok((data.to_vec(), dims[2] as usize, dims[3] as usize))
    }
}
