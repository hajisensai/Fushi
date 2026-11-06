import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

/// 合成的一层：调色板索引平面 [indices]（按 [stride] 跨行，从 ([sourceX], [sourceY]) 起取
/// [width] × [height]）贴到画布坐标 ([x], [y])；[palette] 为 ARGB。
typedef FfcIndexedLayer = ({
  Uint8List indices,
  Uint32List palette,
  int x,
  int y,
  int width,
  int height,
  int stride,
  int sourceX,
  int sourceY,
});

/// DVB 区域里的一个对象：两场像素串（[bottom] 为 null = 重复顶场）摆在 ([x], [y])。
typedef FfcDvbObject = ({Uint8List top, Uint8List? bottom, int x, int y});

final class _Layer extends Struct {
  external Pointer<Uint8> indices;
  @Size()
  external int indicesLen;
  external Pointer<Uint32> palette;
  @Size()
  external int paletteLen;
  @Int32()
  external int x;
  @Int32()
  external int y;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int stride;
  @Int32()
  external int sourceX;
  @Int32()
  external int sourceY;
}

final class _DvbObject extends Struct {
  external Pointer<Uint8> top;
  @Size()
  external int topLen;
  external Pointer<Uint8> bottom;
  @Size()
  external int bottomLen;
  @Int32()
  external int x;
  @Int32()
  external int y;
}

typedef _PgsC =
    Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Uint8>, Size);
typedef _PgsDart =
    int Function(Pointer<Uint8>, int, int, int, Pointer<Uint8>, int);
typedef _DvdC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Uint8>,
      Size,
    );
typedef _DvdDart =
    int Function(Pointer<Uint8>, int, int, int, int, int, Pointer<Uint8>, int);
typedef _DvbSizeC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint32>);
typedef _DvbSizeDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _DvbRenderC =
    Int32 Function(
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Pointer<_DvbObject>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _DvbRenderDart =
    int Function(
      int,
      int,
      int,
      int,
      Pointer<_DvbObject>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _ComposeC =
    Int32 Function(
      Pointer<_Layer>,
      Size,
      Int32,
      Int32,
      Uint32,
      Uint32,
      Pointer<Uint8>,
      Size,
    );
typedef _ComposeDart =
    int Function(Pointer<_Layer>, int, int, int, int, int, Pointer<Uint8>, int);

/// 位图字幕的 DVB 像素串（测量 / 区域渲染，`ffc_image_dvb_*`）与黑底合成
/// （`ffc_image_compose_indexed`）。只有原生这一份实现；库或符号缺失抛
/// [FushiComputeUnavailableError]。PGS / VobSub 的 RLE 解码也在这里（单份实现）。
///
/// 输出写进 arena 缓冲后拷回 Dart 堆：渲染跑在 `Isolate.run` 里、结果经 `Isolate.exit`
/// 移交，挂 finalizer 的原生内存会在工作 isolate 退出时被释放（见 `FushiComputeImage`）。
class FushiComputeBitmapSubtitle {
  FushiComputeBitmapSubtitle._(FushiCompute lib)
    : _pgs = lib.library.lookupFunction<_PgsC, _PgsDart>(
        'ffc_image_pgs_rle_decode',
      ),
      _dvd = lib.library.lookupFunction<_DvdC, _DvdDart>(
        'ffc_image_dvd_rle_decode',
      ),
      _dvbSize = lib.library.lookupFunction<_DvbSizeC, _DvbSizeDart>(
        'ffc_image_dvb_object_size',
      ),
      _dvbRender = lib.library.lookupFunction<_DvbRenderC, _DvbRenderDart>(
        'ffc_image_dvb_render_region',
      ),
      _compose = lib.library.lookupFunction<_ComposeC, _ComposeDart>(
        'ffc_image_compose_indexed',
      );

  final _PgsDart _pgs;
  final _DvdDart _dvd;
  final _DvbSizeDart _dvbSize;
  final _DvbRenderDart _dvbRender;
  final _ComposeDart _compose;

  static FushiComputeBitmapSubtitle? _instance;

  /// 默认库上的绑定；库不可用或缺本域符号抛 [FushiComputeUnavailableError]。
  static FushiComputeBitmapSubtitle get instance =>
      _instance ??= bind(FushiCompute.require());

  /// 在指定库上绑定（测试用）。缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeBitmapSubtitle bind(FushiCompute lib) {
    try {
      return FushiComputeBitmapSubtitle._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('bitmap subtitle', e.message ?? e);
    }
  }

  static void _check(String symbol, int status) {
    if (status != FfcStatus.ok) {
      throw StateError('fushi_compute $symbol failed: status $status');
    }
  }

  static Pointer<Uint8> _copyIn(Uint8List bytes, Arena arena) {
    final Pointer<Uint8> ptr = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    ptr.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    return ptr;
  }

  /// 输入拷进本 isolate 的输入暂存区（不逐次 malloc / free）。
  static Pointer<Uint8> _scratchIn(Uint8List bytes) {
    final Pointer<Uint8> ptr = NativeScratch.input.reserve(
      bytes.isEmpty ? 1 : bytes.length,
    );
    ptr.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    return ptr;
  }

  /// PGS RLE → [width] × [height] 调色板索引平面（数据不足时余下为 0；清零在原生里做）。
  Uint8List decodePgsRle(Uint8List rle, int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('invalid size ${width}x$height');
    }
    final int outLen = width * height;
    return using((Arena arena) {
      final Pointer<Uint8> out = NativeScratch.output.reserve(outLen);
      _check(
        'ffc_image_pgs_rle_decode',
        _pgs(_scratchIn(rle), rle.length, width, height, out, outLen),
      );
      return Uint8List.fromList(out.asTypedListOutOfLine(outLen));
    });
  }

  /// VobSub SPU 两场 2 bit RLE → [width] × [height] 索引平面（0..3）。
  Uint8List decodeDvdRle(
    Uint8List packet, {
    required int width,
    required int height,
    required int topFieldOffset,
    required int bottomFieldOffset,
  }) {
    if (width <= 0 || height <= 0) return Uint8List(0);
    if (topFieldOffset < 0 || bottomFieldOffset < 0) {
      throw ArgumentError('negative field offset');
    }
    final int outLen = width * height;
    return using((Arena arena) {
      final Pointer<Uint8> out = NativeScratch.output.reserve(outLen);
      _check(
        'ffc_image_dvd_rle_decode',
        _dvd(
          _scratchIn(packet),
          packet.length,
          width,
          height,
          topFieldOffset,
          bottomFieldOffset,
          out,
          outLen,
        ),
      );
      return Uint8List.fromList(out.asTypedListOutOfLine(outLen));
    });
  }

  /// DVB 对象两场像素串实际覆盖的宽高。
  ({int width, int height}) dvbObjectSize(Uint8List top, Uint8List? bottom) =>
      using((Arena arena) {
        final Pointer<Uint32> out = arena<Uint32>(2);
        _check(
          'ffc_image_dvb_object_size',
          _dvbSize(
            _copyIn(top, arena),
            top.length,
            bottom == null ? nullptr : _copyIn(bottom, arena),
            bottom?.length ?? 0,
            out,
          ),
        );
        return (width: out[0], height: out[1]);
      });

  /// DVB 区域平面：先填 [background]，再按序画 [objects]（色深 [depth]）。
  Uint8List renderDvbRegion({
    required int width,
    required int height,
    required int depth,
    required int background,
    required List<FfcDvbObject> objects,
  }) {
    if (width < 0 || height < 0) {
      throw ArgumentError('invalid region ${width}x$height');
    }
    final int outLen = width * height;
    return using((Arena arena) {
      final Pointer<Uint8> out = NativeScratch.output.reserve(outLen);
      final Pointer<_DvbObject> objs = arena<_DvbObject>(
        objects.isEmpty ? 1 : objects.length,
      );
      for (int i = 0; i < objects.length; i++) {
        final FfcDvbObject o = objects[i];
        final _DvbObject s = (objs + i).ref;
        s.top = _copyIn(o.top, arena);
        s.topLen = o.top.length;
        final Uint8List? bottom = o.bottom;
        s.bottom = bottom == null ? nullptr : _copyIn(bottom, arena);
        s.bottomLen = bottom?.length ?? 0;
        s.x = o.x;
        s.y = o.y;
      }
      _check(
        'ffc_image_dvb_render_region',
        _dvbRender(
          width,
          height,
          depth,
          background,
          objs,
          objects.length,
          out,
          outLen,
        ),
      );
      // 拷回 Dart 堆：原生内存不挂 finalizer 交出（见类注释）。
      return Uint8List.fromList(out.asTypedListOutOfLine(outLen));
    });
  }

  /// 把 [layers] 合成到 [canvasWidth] × [canvasHeight]、原点在 ([originX], [originY])
  /// 的不透明黑底 RGBA 画布（`composeBitmapSubtitleImage` 的规则），返回 RGBA 字节。
  Uint8List composeIndexed({
    required List<FfcIndexedLayer> layers,
    required int originX,
    required int originY,
    required int canvasWidth,
    required int canvasHeight,
  }) {
    if (canvasWidth <= 0 || canvasHeight <= 0) {
      throw ArgumentError('invalid canvas ${canvasWidth}x$canvasHeight');
    }
    final int outLen = canvasWidth * canvasHeight * 4;
    return using((Arena arena) {
      final Pointer<Uint8> out = NativeScratch.output.reserve(outLen);
      final Pointer<_Layer> ls = arena<_Layer>(
        layers.isEmpty ? 1 : layers.length,
      );
      for (int i = 0; i < layers.length; i++) {
        final FfcIndexedLayer l = layers[i];
        final _Layer s = (ls + i).ref;
        s.indices = _copyIn(l.indices, arena);
        s.indicesLen = l.indices.length;
        final Pointer<Uint32> pal = arena<Uint32>(
          l.palette.isEmpty ? 1 : l.palette.length,
        );
        pal.asTypedListOutOfLine(l.palette.length).setAll(0, l.palette);
        s.palette = pal;
        s.paletteLen = l.palette.length;
        s.x = l.x;
        s.y = l.y;
        s.width = l.width;
        s.height = l.height;
        s.stride = l.stride;
        s.sourceX = l.sourceX;
        s.sourceY = l.sourceY;
      }
      _check(
        'ffc_image_compose_indexed',
        _compose(
          ls,
          layers.length,
          originX,
          originY,
          canvasWidth,
          canvasHeight,
          out,
          outLen,
        ),
      );
      // 拷回 Dart 堆：原生内存不挂 finalizer 交出（见类注释）。
      return Uint8List.fromList(out.asTypedListOutOfLine(outLen));
    });
  }
}
