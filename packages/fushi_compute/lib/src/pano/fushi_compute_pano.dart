import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _NewC =
    Int32 Function(
      Pointer<Float>,
      Pointer<Int32>,
      Size,
      Pointer<Float>,
      Pointer<Int32>,
      Size,
      Pointer<Int32>,
      Size,
      Pointer<Int32>,
      Pointer<Float>,
      Size,
      Float,
      Uint64,
      Pointer<Pointer<Void>>,
    );
typedef _NewDart =
    int Function(
      Pointer<Float>,
      Pointer<Int32>,
      int,
      Pointer<Float>,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      Pointer<Float>,
      int,
      double,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _BuffersC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Pointer<Float>>,
      Pointer<Pointer<Float>>,
      Pointer<Pointer<Int32>>,
      Pointer<Pointer<Uint16>>,
      Pointer<Pointer<Int32>>,
      Pointer<Pointer<Float>>,
      Pointer<Size>,
    );
typedef _BuffersDart =
    int Function(
      Pointer<Void>,
      Pointer<Pointer<Float>>,
      Pointer<Pointer<Float>>,
      Pointer<Pointer<Int32>>,
      Pointer<Pointer<Uint16>>,
      Pointer<Pointer<Int32>>,
      Pointer<Pointer<Float>>,
      Pointer<Size>,
    );
typedef _SetModeC = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _SetModeDart = int Function(Pointer<Void>, int, int);
typedef _InputC = Int32 Function(Pointer<Void>, Int32, Float, Float);
typedef _InputDart = int Function(Pointer<Void>, int, double, double);
typedef _SelectC = Int32 Function(Pointer<Void>, Int32, Float);
typedef _SelectDart = int Function(Pointer<Void>, int, double);
typedef _PickC = Int32 Function(Pointer<Void>, Float, Float);
typedef _PickDart = int Function(Pointer<Void>, double, double);
typedef _FrameC =
    Int32 Function(Pointer<Void>, Double, Float, Float, Float, Pointer<Size>);
typedef _FrameDart =
    int Function(Pointer<Void>, double, double, double, double, Pointer<Size>);

/// `ffc_pano_*` 失败（参数表不合法、原生 panic）。
final class FfcPanoException implements Exception {
  const FfcPanoException(this.operation, this.status);

  final String operation;
  final int status;

  @override
  String toString() => 'FfcPanoException: $operation failed (status $status)';
}

/// 全景模式：首页可操作（星系开场，拉近变球幕）/ 分享用的 16 秒开场动画。
enum FfcPanoMode {
  interactive(0),
  cinematic(1);

  const FfcPanoMode(this.wire);

  final int wire;
}

/// 交互输入（与 pano.rs 的 `input` 模块同值）。
enum FfcPanoInput {
  /// 拖拽：a = dx 像素，b = dy 像素。
  drag(0),

  /// 松手：a / b = 像素每秒速度。
  release(1),

  /// 缩放：a = 比例（> 1 拉近）。
  zoom(2),

  /// 按下：停住惯性。
  hold(3);

  const FfcPanoInput(this.wire);

  final int wire;
}

/// `info` 数组槽位（与 pano.rs 的 `info` 模块同表）。
abstract final class FfcPanoInfo {
  static const int haloX = 0;
  static const int haloY = 1;
  static const int haloR = 2;
  static const int haloAlpha = 3;
  static const int forward = 4;
  static const int right = 7;
  static const int up = 10;
  static const int focal = 13;
  static const int targetVisible = 14;
  static const int targetRect = 15;
  static const int lockProgress = 19;
  static const int phase = 20;
  static const int handoff = 21;
  static const int dim = 22;

  /// 0 = 星系，1 = 球幕。
  static const int morph = 23;

  /// 1 = 场景仍在变化（继续出帧），0 = 已静止（可停帧循环，等输入 / 切模式再起）。
  static const int moving = 24;
  static const int length = 32;
}

/// 建图输入：图集格子 + 作品 + 词 + 字形（全部扁平数组，一次交给原生侧）。
final class FfcPanoScene {
  const FfcPanoScene({
    required this.cellRects,
    required this.cellPages,
    required this.workParams,
    required this.workCells,
    required this.words,
    required this.glyphCells,
    required this.glyphAdvances,
    required this.glyphEmPx,
    this.seed = 1,
  });

  /// 每格 (x, y, w, h) 图集像素。
  final Float32List cellRects;

  /// 每格所在图集页。
  final Int32List cellPages;

  /// 每部作品 (宽高比, 封面本体在格子里的像素宽, 色相 0..1)。
  final Float32List workParams;

  /// 每部作品的封面格子。
  final Int32List workCells;

  /// 每个词 (所属作品或 -1, 字形起点, 字形数)。
  final Int32List words;

  /// 每个字形 (细体, 粗体字心, 粗体描边) 格子。
  final Int32List glyphCells;

  /// 每个字形的字宽（em 倍数）。
  final Float32List glyphAdvances;

  /// 字形格子的 em 像素。
  final double glyphEmPx;

  final int seed;

  int get cellCount => cellPages.length;
  int get workCount => workCells.length;
  int get wordCount => words.length ~/ 3;
  int get glyphCount => glyphAdvances.length;
}

/// 一帧的输出视图（指向原生缓冲区，下一次 [FfcPanorama.frame] 前有效，别跨帧持有）。
///
/// 三角网格：封面是 4×4 小格的 3D 平面投影，词是屏幕空间字形片；已按远到近排好，按图集页
/// 切批。每批画一次 `drawVertices`（纹理 = 该页图集，`BlendMode.modulate` 乘顶点色）。
final class FfcPanoFrame {
  const FfcPanoFrame({
    required this.vertices,
    required this.indexCount,
    required this.batches,
    required this.positions,
    required this.texCoords,
    required this.colors,
    required this.indices,
    required this.batchTable,
    required this.info,
  });

  final int vertices;
  final int indexCount;
  final int batches;

  /// 屏幕坐标 (x, y) × [vertices]。
  final Float32List positions;

  /// 图集像素坐标 (u, v) × [vertices]；[FfcPanorama.targetPage] 批为整张高清图的 0..1。
  final Float32List texCoords;

  /// ARGB 调制色 × [vertices]。
  final Int32List colors;

  /// 三角形索引（相对所在批的起始顶点）。
  final Uint16List indices;

  /// (图集页, 顶点起点, 顶点数, 索引起点, 索引数) × [batches]。
  final Int32List batchTable;

  /// 帧信息，下标见 [FfcPanoInfo]。
  final Float32List info;

  int batchPage(int b) => batchTable[b * 5];
  int batchVertexStart(int b) => batchTable[b * 5 + 1];
  int batchVertexCount(int b) => batchTable[b * 5 + 2];
  int batchIndexStart(int b) => batchTable[b * 5 + 3];
  int batchIndexCount(int b) => batchTable[b * 5 + 4];

  bool get targetVisible => info[FfcPanoInfo.targetVisible] > 0.5;
  bool get handoff => info[FfcPanoInfo.handoff] > 0.5;

  /// 场景是否仍在变化（惯性 / 环境动效 / 锁定 / 分享动画）；false 时再出帧画面不变。
  bool get moving => info[FfcPanoInfo.moving] > 0.5;
}

/// 媒体库全景的原生状态句柄（布局、镜头、每帧投影都在 Rust，见 native/fushi_compute/src/pano.rs）。
///
/// 一次用户交互对应个位数 FFI 调用：每帧一次 [frame]，拖拽 / 缩放各一次 [input]。
final class FfcPanorama implements Finalizable {
  FfcPanorama._(this._b, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
    using((Arena arena) {
      final Pointer<Pointer<Float>> pos = arena<Pointer<Float>>();
      final Pointer<Pointer<Float>> uv = arena<Pointer<Float>>();
      final Pointer<Pointer<Int32>> co = arena<Pointer<Int32>>();
      final Pointer<Pointer<Uint16>> ix = arena<Pointer<Uint16>>();
      final Pointer<Pointer<Int32>> ba = arena<Pointer<Int32>>();
      final Pointer<Pointer<Float>> inf = arena<Pointer<Float>>();
      final Pointer<Size> caps = arena<Size>(3);
      _check('buffers', _b.buffers(_handle, pos, uv, co, ix, ba, inf, caps));
      _vertexCapacity = caps[0];
      _positions = pos.value.asTypedListOutOfLine(_vertexCapacity * 2);
      _texCoords = uv.value.asTypedListOutOfLine(_vertexCapacity * 2);
      _colors = co.value.asTypedListOutOfLine(_vertexCapacity);
      _indices = ix.value.asTypedListOutOfLine(caps[1]);
      _batchTable = ba.value.asTypedListOutOfLine(caps[2] * 5);
      _info = inf.value.asTypedListOutOfLine(FfcPanoInfo.length);
    });
  }

  /// 建图（一次 FFI 交完所有表）。参数不合法抛 [FfcPanoException]。
  factory FfcPanorama.create(FfcPanoScene scene) {
    final _PanoBindings b = _PanoBindings.instance;
    final Pointer<Float> rects = _copyF32(scene.cellRects);
    final Pointer<Int32> pages = _copyI32(scene.cellPages);
    final Pointer<Float> works = _copyF32(scene.workParams);
    final Pointer<Int32> workCells = _copyI32(scene.workCells);
    final Pointer<Int32> words = _copyI32(scene.words);
    final Pointer<Int32> glyphCells = _copyI32(scene.glyphCells);
    final Pointer<Float> adv = _copyF32(scene.glyphAdvances);
    final Pointer<Pointer<Void>> out = malloc<Pointer<Void>>();
    try {
      _check(
        'new',
        b.create(
          rects,
          pages,
          scene.cellCount,
          works,
          workCells,
          scene.workCount,
          words,
          scene.wordCount,
          glyphCells,
          adv,
          scene.glyphCount,
          scene.glyphEmPx,
          scene.seed,
          out,
        ),
      );
      return FfcPanorama._(b, out.value);
    } finally {
      for (final Pointer<NativeType> p in <Pointer<NativeType>>[
        rects,
        pages,
        works,
        workCells,
        words,
        glyphCells,
        adv,
        out,
      ]) {
        malloc.free(p);
      }
    }
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(
    _PanoBindings.instance.freePtr,
  );

  final _PanoBindings _b;
  Pointer<Void> _handle;

  /// 每帧的顶点数 / 索引数 / 批次数输出槽。
  final NativeScratch _counts = NativeScratch.fixed(3 * sizeOf<Size>());
  late final int _vertexCapacity;
  late final Float32List _positions;
  late final Float32List _texCoords;
  late final Int32List _colors;
  late final Uint16List _indices;
  late final Int32List _batchTable;
  late final Float32List _info;

  bool get isDisposed => _handle == nullptr;

  /// 批次表里锁定目标那一批的页号：用高清带框封面画（纹理坐标 0..1）。
  static const int targetPage = -1;

  /// 输出顶点容量（建图时定死）。
  int get vertexCapacity => _vertexCapacity;

  void setMode(FfcPanoMode mode, {int target = -1}) {
    _alive();
    _check('set_mode', _b.setMode(_handle, mode.wire, target));
  }

  void input(FfcPanoInput kind, double a, [double b = 0]) {
    _alive();
    _check('input', _b.input(_handle, kind.wire, a, b));
  }

  /// 交互模式下选中作品 [work]，从当前镜头转向并飞到眼前；[t] 与 [frame] 同一时钟。
  void select(int work, double t) {
    _alive();
    _check('select', _b.select(_handle, work, t));
  }

  /// 上一帧 (x, y) 处的作品下标；没有为 -1。
  int pick(double x, double y) {
    _alive();
    return _b.pick(_handle, x, y);
  }

  /// 算一帧并返回指向原生缓冲区的视图。
  FfcPanoFrame frame({
    required double t,
    required double dt,
    required double width,
    required double height,
  }) {
    _alive();
    final Pointer<Size> counts = _counts.pointer.cast<Size>();
    _check('frame', _b.frame(_handle, t, dt, width, height, counts));
    return FfcPanoFrame(
      vertices: counts[0],
      indexCount: counts[1],
      batches: counts[2],
      positions: _positions,
      texCoords: _texCoords,
      colors: _colors,
      indices: _indices,
      batchTable: _batchTable,
      info: _info,
    );
  }

  /// 立即释放原生状态（幂等）。之后再调用任何方法抛 [StateError]。
  void dispose() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    _b.free(_handle);
    _handle = nullptr;
  }

  void _alive() {
    if (_handle == nullptr) {
      throw StateError('FfcPanorama used after dispose');
    }
  }

  static void _check(String op, int rc) {
    if (rc != FfcStatus.ok) throw FfcPanoException(op, rc);
  }

  static Pointer<Float> _copyF32(Float32List src) {
    final Pointer<Float> p = malloc<Float>(src.isEmpty ? 1 : src.length);
    p.asTypedListOutOfLine(src.length).setAll(0, src);
    return p;
  }

  static Pointer<Int32> _copyI32(Int32List src) {
    final Pointer<Int32> p = malloc<Int32>(src.isEmpty ? 1 : src.length);
    p.asTypedListOutOfLine(src.length).setAll(0, src);
    return p;
  }
}

final class _PanoBindings {
  _PanoBindings._(FushiCompute lib)
    : create = lib.library.lookupFunction<_NewC, _NewDart>('ffc_pano_new'),
      buffers = lib.library.lookupFunction<_BuffersC, _BuffersDart>(
        'ffc_pano_buffers',
      ),
      setMode = lib.library.lookupFunction<_SetModeC, _SetModeDart>(
        'ffc_pano_set_mode',
      ),
      input = lib.library.lookupFunction<_InputC, _InputDart>('ffc_pano_input'),
      select = lib.library.lookupFunction<_SelectC, _SelectDart>(
        'ffc_pano_select',
      ),
      pick = lib.library.lookupFunction<_PickC, _PickDart>('ffc_pano_pick'),
      frame = lib.library.lookupFunction<_FrameC, _FrameDart>('ffc_pano_frame'),
      freePtr = lib.library
          .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'ffc_pano_free',
          ),
      free = lib.library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('ffc_pano_free');

  final _NewDart create;
  final _BuffersDart buffers;
  final _SetModeDart setMode;
  final _InputDart input;
  final _SelectDart select;
  final _PickDart pick;
  final _FrameDart frame;
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>> freePtr;
  final void Function(Pointer<Void>) free;

  static _PanoBindings? _instance;

  static _PanoBindings get instance {
    final _PanoBindings? cached = _instance;
    if (cached != null) return cached;
    final FushiCompute lib = FushiCompute.require();
    try {
      return _instance = _PanoBindings._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('pano', e);
    }
  }
}
