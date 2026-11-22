/// 镜台的真 3D 渲染器（Flutter GPU，Impeller 之上）。
///
/// folia 的镜台是 three.js 场景：透视相机沿路径飞，文字是摆在 3D 里的贴图平面，点云 / 长廊是
/// ShaderMaterial 点精灵，场景有线性雾。这里一一对应：
///
/// - 相机：[DioramaCamera]（同一套四元数相机）→ 视图矩阵 + 透视投影（竖直 55°，z ∈ [0, 1]）。
/// - 文字：[DioramaPlane] 是世界里的四边形，实例化一次画一组同贴图的平面（`diorama_plane.*`）。
/// - 点云：`diorama_particle.*` 是 folia 顶点 / 片元着色器的移植，实例化四边形代替 gl_PointSize；
///   几何缓冲只在阵列变化时上传一次，逐帧只换统一块（波纹源、包络、颜色）。
/// - 尘埃：`diorama_mote.*`（PointsMaterial 的方点 + 雾）。
/// - 深度：带深度附件并做深度测试；和 folia 一样所有物体都是透明物体、不写深度，按 three 的透明
///   队列排序（renderOrder，再由远到近）。
///
/// 每帧画进 [gpu.GpuImageSurface] 的颜色纹理，再作为 [ui.Image] 交给 CustomPainter 贴到画面上；
/// 表面、深度纹理、缓冲都跨帧复用，只有尺寸变化时重建。
///
/// 平台边界：Flutter GPU 要引擎开关打开（五端的开关见 windows/runner/main.cpp、
/// linux/runner/my_application.cc、AndroidManifest.xml 与两份 Info.plist；`flutter test` 要带
/// `--enable-impeller --enable-flutter-gpu`）。拿不到 [gpu.gpuContext]（开关没开、Impeller 后端
/// 不支持）时整个样式退回 Canvas 后备实现 [DioramaScene.paint]，只检查一次、只记一条诊断日志。
/// 上下文拿到之后的任何错误（着色器包缺失、管线创建失败、绘制失败）都照常上报，不吞。
/// 清理条件：五端发布包都确认带 Flutter GPU（且最低系统版本的 GLES 设备也能建上下文）后，
/// 删掉 Canvas 后备实现与这个回退判断。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_render_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene_layout.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// hook/build.dart 编出来的着色器包（pubspec 的 flutter.assets 登记同一路径）。
const String dioramaShaderBundleAsset =
    'build/shaderbundles/diorama.shaderbundle';

/// 透视投影的远裁剪面（three/R3F 默认相机是 1000；镜台的东西都在 45 以内）。
const double dioramaGpuFar = 200;

/// 三条管线（文字平面 / 点云 / 尘埃）。整个进程共用一份。
class DioramaGpuPipelines {
  DioramaGpuPipelines._(this.particle, this.plane, this.mote);

  final gpu.RenderPipeline particle;
  final gpu.RenderPipeline plane;
  final gpu.RenderPipeline mote;

  static const gpu.VertexBuffer _quad = gpu.VertexBuffer(
    strideInBytes: 8,
    attributes: <gpu.VertexAttribute>[
      gpu.VertexAttribute(name: 'corner', format: gpu.VertexFormat.float32x2),
    ],
  );

  static DioramaGpuPipelines _create(gpu.ShaderLibrary lib) {
    gpu.Shader shader(String name) {
      final gpu.Shader? s = lib[name];
      if (s == null) {
        throw StateError('diorama shader bundle has no "$name"');
      }
      return s;
    }

    final gpu.RenderPipeline particle = gpu.gpuContext.createRenderPipeline(
      shader('DioramaParticleVertex'),
      shader('DioramaParticleFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: <gpu.VertexBuffer>[
          _quad,
          gpu.VertexBuffer(
            strideInBytes: dioramaParticleStride * 4,
            stepMode: gpu.VertexStepMode.instance,
            attributes: <gpu.VertexAttribute>[
              gpu.VertexAttribute(
                name: 'base_position',
                format: gpu.VertexFormat.float32x3,
              ),
              gpu.VertexAttribute(
                name: 'normal_dir',
                format: gpu.VertexFormat.float32x3,
                offsetInBytes: 12,
              ),
              gpu.VertexAttribute(
                name: 'anchor',
                format: gpu.VertexFormat.float32x3,
                offsetInBytes: 24,
              ),
              gpu.VertexAttribute(
                name: 'scale',
                format: gpu.VertexFormat.float32x3,
                offsetInBytes: 36,
              ),
              gpu.VertexAttribute(
                name: 'style',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 48,
              ),
              gpu.VertexAttribute(
                name: 'wave',
                format: gpu.VertexFormat.float32x2,
                offsetInBytes: 64,
              ),
            ],
          ),
        ],
      ),
    );
    final gpu.RenderPipeline plane = gpu.gpuContext.createRenderPipeline(
      shader('DioramaPlaneVertex'),
      shader('DioramaPlaneFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: <gpu.VertexBuffer>[
          _quad,
          gpu.VertexBuffer(
            strideInBytes: _planeStride * 4,
            stepMode: gpu.VertexStepMode.instance,
            attributes: <gpu.VertexAttribute>[
              gpu.VertexAttribute(
                name: 'center',
                format: gpu.VertexFormat.float32x3,
              ),
              gpu.VertexAttribute(
                name: 'axis_u',
                format: gpu.VertexFormat.float32x3,
                offsetInBytes: 12,
              ),
              gpu.VertexAttribute(
                name: 'axis_v',
                format: gpu.VertexFormat.float32x3,
                offsetInBytes: 24,
              ),
              gpu.VertexAttribute(
                name: 'uv_rect',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 36,
              ),
              gpu.VertexAttribute(
                name: 'tint',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 52,
              ),
            ],
          ),
        ],
      ),
    );
    final gpu.RenderPipeline mote = gpu.gpuContext.createRenderPipeline(
      shader('DioramaMoteVertex'),
      shader('DioramaMoteFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: <gpu.VertexBuffer>[
          _quad,
          gpu.VertexBuffer(
            strideInBytes: 12,
            stepMode: gpu.VertexStepMode.instance,
            attributes: <gpu.VertexAttribute>[
              gpu.VertexAttribute(
                name: 'mote_position',
                format: gpu.VertexFormat.float32x3,
              ),
            ],
          ),
        ],
      ),
    );
    return DioramaGpuPipelines._(particle, plane, mote);
  }
}

/// Flutter GPU 是否可用（进程内只判一次）。
abstract final class DioramaGpu {
  static Future<DioramaGpuPipelines?>? _loading;
  static DioramaGpuPipelines? _pipelines;
  static bool _resolved = false;

  /// 已经判过时的结果（没判过为 null，且 [resolved] 为 false）。
  static DioramaGpuPipelines? get pipelines => _pipelines;

  /// 是否已经判过。
  static bool get resolved => _resolved;

  /// 判可用性并建好管线；不可用时为 null（调用方走 Canvas 后备实现）。
  static Future<DioramaGpuPipelines?> load() => _loading ??= _load();

  static Future<DioramaGpuPipelines?> _load() async {
    // 平台边界（见文件头）：只有「拿不到 GPU 上下文」这一种情况算不可用。
    final gpu.GpuContext context;
    try {
      context = gpu.gpuContext;
    } on Exception catch (e) {
      ErrorLogService.instance.logDiagnostic(
        'Diorama.gpu',
        'Flutter GPU unavailable, using the Canvas fallback: $e',
      );
      debugPrint('Diorama: Flutter GPU unavailable ($e); Canvas fallback.');
      _resolved = true;
      return null;
    }
    // 上下文在了：后面的失败都是缺陷（着色器包没编 / 没打包、管线建不出来），上报而不吞；
    // 用户这次仍看到 Canvas 版，但错误日志里有完整原因。
    try {
      final gpu.ShaderLibrary? lib = await gpu.ShaderLibrary.fromAsset(
        dioramaShaderBundleAsset,
      );
      if (lib == null) {
        throw StateError('diorama shader bundle failed to load');
      }
      _pipelines = DioramaGpuPipelines._create(lib);
      debugPrint(
        'Diorama: Flutter GPU ready '
        '(color ${context.defaultColorFormat}, '
        'depth ${context.defaultDepthStencilFormat}).',
      );
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'diorama visualizer',
          context: ErrorDescription('while setting up Flutter GPU pipelines'),
        ),
      );
      _pipelines = null;
    }
    _resolved = true;
    return _pipelines;
  }

  /// 测试用：让下一次 [load] 重新判。
  @visibleForTesting
  static void debugReset() {
    _loading = null;
    _pipelines = null;
    _resolved = false;
  }
}

/// 文字平面实例：center(3) axis_u(3) axis_v(3) uv_rect(4) tint(4)。
const int _planeStride = 17;

/// 视图矩阵写进 [m] 的 [o] 起 16 个 float，列主序（GLSL mat4 的内存布局）。
void dioramaGpuWriteView(Float32List m, int o, DioramaCamera c) {
  final DioramaVec r = c.right, u = c.up, b = c.back, p = c.position;
  // 行 = 相机的右 / 上 / 后基向量（视图 = 相机变换的逆）。
  m[o + 0] = r.x;
  m[o + 1] = u.x;
  m[o + 2] = b.x;
  m[o + 3] = 0;
  m[o + 4] = r.y;
  m[o + 5] = u.y;
  m[o + 6] = b.y;
  m[o + 7] = 0;
  m[o + 8] = r.z;
  m[o + 9] = u.z;
  m[o + 10] = b.z;
  m[o + 11] = 0;
  m[o + 12] = -r.dot(p);
  m[o + 13] = -u.dot(p);
  m[o + 14] = -b.dot(p);
  m[o + 15] = 1;
}

/// 右手系透视投影（看向 -z），NDC 深度 [0, 1]（Impeller 约定，GLES 后端由 impellerc 换算）。
void dioramaGpuWriteProjection(Float32List m, int o, DioramaCamera c) {
  final double f = 1 / math.tan(c.fovDeg * math.pi / 360);
  const double n = DioramaCamera.near;
  const double far = dioramaGpuFar;
  for (int i = 0; i < 16; i++) {
    m[o + i] = 0;
  }
  m[o + 0] = f / c.aspect;
  m[o + 5] = f;
  m[o + 10] = far / (n - far);
  m[o + 11] = -1;
  m[o + 14] = n * far / (n - far);
}

/// 一帧的实际渲染。每个 [DioramaGpuRenderer] 对应一个挂着的镜台。
class DioramaGpuRenderer {
  DioramaGpuRenderer(this._p);

  final DioramaGpuPipelines _p;

  gpu.GpuImageSurface? _surface;
  gpu.Texture? _depth;
  int _width = 0;
  int _height = 0;

  final gpu.HostBuffer _transients = gpu.gpuContext.createHostBuffer();
  late final gpu.DeviceBuffer _quad = gpu.gpuContext.createDeviceBufferWithCopy(
    ByteData.sublistView(
      Float32List.fromList(<double>[
        -1, -1, 1, -1, 1, 1, //
        -1, -1, 1, 1, -1, 1, //
      ]),
    ),
  );

  // 点云几何：阵列一变就整块重传，逐帧不动。
  gpu.DeviceBuffer? _particleBuffer;
  DioramaParticleGeometry? _particleFor;

  // 逐帧复用的暂存区（只在容量不够时增长）。
  final Float32List _particleUniforms = Float32List(144);
  final Float32List _particleFrag = Float32List(4);
  final Float32List _planeUniforms = Float32List(32);
  final Float32List _planeFrag = Float32List(8);
  final Float32List _moteUniforms = Float32List(48);
  final Float32List _moteFrag = Float32List(12);
  Float32List _planeInstances = Float32List(0);
  final List<DioramaPlane> _sorted = <DioramaPlane>[];

  bool _disposed = false;

  /// 测试 / 诊断：上一帧画了多少块文字平面、多少个点。
  int debugPlaneCount = 0;
  int debugParticleCount = 0;

  void dispose() {
    _disposed = true;
    _surface = null;
    _depth = null;
    _particleBuffer = null;
    _particleFor = null;
  }

  void _ensureTargets(int w, int h) {
    if (_surface != null && w == _width && h == _height) return;
    if (_surface == null) {
      _surface = gpu.gpuContext.createImageSurface(w, h);
    } else {
      _surface!.resize(w, h);
    }
    _depth = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      w,
      h,
      format: gpu.gpuContext.defaultDepthStencilFormat,
      enableShaderReadUsage: false,
    );
    _width = w;
    _height = h;
  }

  /// 画一帧，返回可直接贴到画面上的图（[w]×[h] 设备像素）。
  ui.Image? render(DioramaRenderFrame f, int w, int h) {
    if (_disposed || w <= 0 || h <= 0) return null;
    _ensureTargets(w, h);
    _transients.reset();
    final gpu.GpuImageSurfaceFrame frame = _surface!.acquireNextFrame();
    final gpu.CommandBuffer cb = gpu.gpuContext.createCommandBuffer();
    final gpu.RenderPass pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: frame.colorTexture,
          clearValue: vm.Vector4(0, 0, 0, 0),
        ),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: _depth!,
          depthClearValue: 1,
        ),
      ),
    );
    pass.setDepthWriteEnable(false);
    pass.setCullMode(gpu.CullMode.none);
    pass.setColorBlendEnable(true);

    final DioramaCamera cam = f.camera;
    final DioramaMotesDraw? motes = f.motes;
    if (motes != null) _drawMotes(pass, cam, motes, f.fogColor, w, h);
    final DioramaParticlesDraw? particles = f.particles;
    debugParticleCount = 0;
    if (particles != null) _drawParticles(pass, cam, particles, w, h);
    _drawPlanes(pass, cam, f);

    frame.present(cb);
    cb.submit();
    return _surface!.currentImage;
  }

  static final gpu.ColorBlendEquation _normal = gpu.ColorBlendEquation();
  static final gpu.ColorBlendEquation _additive = gpu.ColorBlendEquation(
    destinationColorBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );
  static final gpu.SamplerOptions _linear = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
  );

  gpu.BufferView _emplace(Float32List data) =>
      _transients.emplace(ByteData.sublistView(data));

  gpu.BufferView get _quadView =>
      gpu.BufferView(_quad, offsetInBytes: 0, lengthInBytes: 48);

  // ─── 尘埃 ──────────────────────────────────────────────────────────────

  void _drawMotes(
    gpu.RenderPass pass,
    DioramaCamera cam,
    DioramaMotesDraw m,
    ui.Color fog,
    int w,
    int h,
  ) {
    final int n = m.positions.length ~/ 3;
    if (n == 0 || m.alpha <= 0) return;
    final Float32List u = _moteUniforms;
    dioramaGpuWriteView(u, 0, cam);
    dioramaGpuWriteProjection(u, 16, cam);
    u[32] = m.ox;
    u[33] = m.oy;
    u[34] = m.oz;
    u[35] = m.sizeWorld;
    u[36] = w.toDouble();
    u[37] = h.toDouble();
    final Float32List fu = _moteFrag;
    fu[0] = m.color.r;
    fu[1] = m.color.g;
    fu[2] = m.color.b;
    fu[3] = math.min(1.0, m.alpha);
    fu[4] = fog.r;
    fu[5] = fog.g;
    fu[6] = fog.b;
    fu[7] = 1;
    fu[8] = dioramaFogNear;
    fu[9] = dioramaFogFar;
    pass.clearBindings();
    pass.bindPipeline(_p.mote);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setColorBlendEquation(_normal);
    pass.bindVertexBuffer(_quadView);
    pass.bindVertexBuffer(_emplace(m.positions), slot: 1);
    pass.bindUniform(
      _p.mote.vertexShader.getUniformSlot('FrameInfo'),
      _emplace(u),
    );
    pass.bindUniform(
      _p.mote.fragmentShader.getUniformSlot('FragInfo'),
      _emplace(fu),
    );
    pass.draw(6, instanceCount: n);
  }

  // ─── 点云 ──────────────────────────────────────────────────────────────

  void _drawParticles(
    gpu.RenderPass pass,
    DioramaCamera cam,
    DioramaParticlesDraw d,
    int w,
    int h,
  ) {
    final DioramaParticleGeometry g = d.geometry;
    if (g.count == 0) return;
    if (!identical(g, _particleFor)) {
      _particleFor = g;
      _particleBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
        ByteData.sublistView(g.data, 0, g.count * dioramaParticleStride),
      );
    }
    final DioramaParticleFrame fr = d.frame;
    final Float32List u = _particleUniforms;
    dioramaGpuWriteView(u, 0, cam);
    dioramaGpuWriteProjection(u, 16, cam);
    u[32] = cam.position.x;
    u[33] = cam.position.y;
    u[34] = cam.position.z;
    u[35] = 0;
    // p0: time, corridor, amplitude, max_swell
    u[36] = fr.time;
    u[37] = g.corridor ? 1 : 0;
    u[38] = fr.amplitude;
    u[39] = fr.maxSwell;
    // p1: wave_number_max, detail, offset_gain, flow
    u[40] = g.waveNumberMax;
    u[41] = 0;
    u[42] = fr.offsetGain;
    u[43] = fr.flow;
    // p2: formation, scatter, pulse, centroid
    u[44] = fr.formation;
    u[45] = fr.scatter;
    u[46] = fr.pulse;
    u[47] = fr.centroid;
    // p3: viewport_w, viewport_h, size_base, size_gain
    u[48] = w.toDouble();
    u[49] = h.toDouble();
    u[50] = fr.sizeBase;
    u[51] = fr.sizeGain;
    // p4: glow, glow_pass（逐 pass 改）
    u[52] = fr.glowIntensity;
    u[53] = 0;
    u[54] = 0;
    u[55] = 0;
    // life
    u[56] = dioramaShapeFadeInStart;
    u[57] = dioramaShapeFadeInEnd;
    u[58] = dioramaShapeDissolveStart;
    u[59] = dioramaShapeDissolveEnd;
    for (int i = 0; i < 3; i++) {
      final ui.Color c = d.palette[i];
      u[60 + i * 4] = c.r;
      u[61 + i * 4] = c.g;
      u[62 + i * 4] = c.b;
      u[63 + i * 4] = 1;
    }
    u.setRange(72, 72 + dioramaRippleCount * 4, d.pool.sources);
    u.setRange(
      72 + dioramaRippleCount * 4,
      72 + dioramaRippleCount * 8,
      d.pool.shapes,
    );

    pass.clearBindings();
    pass.bindPipeline(_p.particle);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.bindVertexBuffer(_quadView);
    pass.bindVertexBuffer(
      gpu.BufferView(
        _particleBuffer!,
        offsetInBytes: 0,
        lengthInBytes: g.count * dioramaParticleStride * 4,
      ),
      slot: 1,
    );
    final gpu.UniformSlot vSlot = _p.particle.vertexShader.getUniformSlot(
      'FrameInfo',
    );
    final gpu.UniformSlot fSlot = _p.particle.fragmentShader.getUniformSlot(
      'FragInfo',
    );
    // folia：辉光层 renderOrder 3 在前（叠加），对比层 4 在后（普通混合）。
    for (final bool glowPass in <bool>[true, false]) {
      if (glowPass && fr.glowIntensity <= 0) continue;
      u[53] = glowPass ? 1 : 0;
      _particleFrag[0] = fr.glowIntensity;
      _particleFrag[1] = glowPass ? 1 : 0;
      pass.setColorBlendEquation(glowPass ? _additive : _normal);
      pass.bindUniform(vSlot, _emplace(u));
      pass.bindUniform(fSlot, _emplace(_particleFrag));
      pass.draw(6, instanceCount: g.count);
    }
    debugParticleCount = g.count;
  }

  // ─── 文字平面 ──────────────────────────────────────────────────────────

  static gpu.Texture? _textureOf(DioramaPlane p) => switch (p.layer) {
    DioramaRasterLayer.line => p.raster.lineTexture,
    DioramaRasterLayer.units => p.raster.unitTexture,
    DioramaRasterLayer.glow => p.raster.glowTexture,
  };

  void _drawPlanes(
    gpu.RenderPass pass,
    DioramaCamera cam,
    DioramaRenderFrame f,
  ) {
    _sorted
      ..clear()
      ..addAll(f.planes);
    // three 的透明队列：renderOrder 升序，同序由远到近。List.sort 不稳定，带上原序做第三键。
    final Map<DioramaPlane, int> order = <DioramaPlane, int>{
      for (int i = 0; i < f.planes.length; i++) f.planes[i]: i,
    };
    _sorted.sort((DioramaPlane a, DioramaPlane b) {
      final int o = a.renderOrder.compareTo(b.renderOrder);
      if (o != 0) return o;
      final int d = b.sortDepth.compareTo(a.sortDepth);
      if (d != 0) return d;
      return order[a]!.compareTo(order[b]!);
    });
    if (_planeInstances.length < _sorted.length * _planeStride) {
      _planeInstances = Float32List(
        math.max(64, _sorted.length * 2) * _planeStride,
      );
    }
    final Float32List u = _planeUniforms;
    dioramaGpuWriteView(u, 0, cam);
    dioramaGpuWriteProjection(u, 16, cam);
    final gpu.UniformSlot vSlot = _p.plane.vertexShader.getUniformSlot(
      'FrameInfo',
    );
    final gpu.UniformSlot fSlot = _p.plane.fragmentShader.getUniformSlot(
      'FragInfo',
    );
    final gpu.UniformSlot texSlot = _p.plane.fragmentShader.getUniformSlot(
      'atlas',
    );
    pass.clearBindings();
    pass.bindPipeline(_p.plane);
    pass.bindVertexBuffer(_quadView);
    pass.bindUniform(vSlot, _emplace(u));

    // 写实例，连续同贴图 / 同混合 / 同深度测试的合成一次实例化绘制。
    final Float32List inst = _planeInstances;
    int count = 0;
    int runStart = 0;
    gpu.Texture? runTexture;
    bool runAdditive = false;
    bool runDepth = false;
    int drawn = 0;

    void flush() {
      final int n = count - runStart;
      if (n <= 0 || runTexture == null) return;
      final Float32List fu = _planeFrag;
      fu[0] = f.fogColor.r;
      fu[1] = f.fogColor.g;
      fu[2] = f.fogColor.b;
      fu[3] = 1;
      fu[4] = dioramaFogNear;
      fu[5] = dioramaFogFar;
      fu[6] = runAdditive ? 1 : 0;
      fu[7] = 0;
      pass.setColorBlendEquation(runAdditive ? _additive : _normal);
      pass.setDepthCompareOperation(
        runDepth ? gpu.CompareFunction.lessEqual : gpu.CompareFunction.always,
      );
      pass.bindVertexBuffer(
        _transients.emplace(
          ByteData.sublistView(
            inst,
            runStart * _planeStride,
            count * _planeStride,
          ),
        ),
        slot: 1,
      );
      pass.bindUniform(fSlot, _emplace(fu));
      pass.bindTexture(texSlot, runTexture, sampler: _linear);
      pass.draw(6, instanceCount: n);
      drawn += n;
    }

    for (final DioramaPlane p in _sorted) {
      final gpu.Texture? tex = _textureOf(p);
      if (tex == null) continue;
      if (!identical(tex, runTexture) ||
          p.additive != runAdditive ||
          p.depthTest != runDepth) {
        flush();
        runStart = count;
        runTexture = tex;
        runAdditive = p.additive;
        runDepth = p.depthTest;
      }
      final double s = p.scale;
      final double mx = (p.dst.center.dx - p.anchor.dx) * s;
      final double my = -(p.dst.center.dy - p.anchor.dy) * s;
      final double hu = p.dst.width / 2 * s;
      final double hv = p.dst.height / 2 * s;
      final int o = count * _planeStride;
      inst[o] = p.world.x + p.right.x * mx + p.up.x * my;
      inst[o + 1] = p.world.y + p.right.y * mx + p.up.y * my;
      inst[o + 2] = p.world.z + p.right.z * mx + p.up.z * my;
      inst[o + 3] = p.right.x * hu;
      inst[o + 4] = p.right.y * hu;
      inst[o + 5] = p.right.z * hu;
      inst[o + 6] = p.up.x * hv;
      inst[o + 7] = p.up.y * hv;
      inst[o + 8] = p.up.z * hv;
      final double tw = tex.width.toDouble(), th = tex.height.toDouble();
      inst[o + 9] = p.src.left / tw;
      inst[o + 10] = p.src.top / th;
      inst[o + 11] = p.src.right / tw;
      inst[o + 12] = p.src.bottom / th;
      inst[o + 13] = p.color.r;
      inst[o + 14] = p.color.g;
      inst[o + 15] = p.color.b;
      inst[o + 16] = math.min(1.0, p.alpha);
      count++;
    }
    flush();
    debugPlaneCount = drawn;
  }
}
