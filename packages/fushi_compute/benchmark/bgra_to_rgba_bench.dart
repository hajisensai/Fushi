// 智能遮布 / 暂停 OCR 截帧变换的耗时对比（HBK-AUDIT-008）：迁 Rust 前的 Dart 换通道循环
// vs `FushiComputeImage.bgraToRgba8`（拷入暂存区 + FFI + 拷回 Dart 堆，带 24 字节头）。
//
// 源帧放在原生内存里（同 mpv `screenshot-raw` 的节点缓冲），stride 带 64 字节填充。
// 「新 isolate」一列模拟真实路径：media_kit 补丁每次截帧都 `compute` 一个新 isolate，
// 在里面跑变换，因此含原生库加载与符号绑定。
//
//   dart run benchmark/bgra_to_rgba_bench.dart            （JIT）
//   dart compile exe benchmark/bgra_to_rgba_bench.dart -o <exe> && <exe>   （AOT，接近发布）
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_compute/fushi_compute.dart';

const int _header = 24;

/// 迁移前 raw_video_frame.dart 的实现（小端 + 4 字节对齐时走 32 位字快路径）。
Uint8List _dartCrop(
  Uint8List src,
  int stride,
  int left,
  int top,
  int w,
  int h,
) {
  final Uint8List out = Uint8List(_header + w * h * 4);
  if (Endian.host == Endian.little &&
      src.offsetInBytes % 4 == 0 &&
      stride % 4 == 0) {
    final Uint32List out32 = out.buffer.asUint32List(_header, w * h);
    final Uint32List src32 = src.buffer.asUint32List(
      src.offsetInBytes,
      src.length ~/ 4,
    );
    final int strideWords = stride ~/ 4;
    int o = 0;
    for (int y = 0; y < h; y++) {
      int i = (top + y) * strideWords + left;
      for (int x = 0; x < w; x++) {
        final int v = src32[i++];
        out32[o++] =
            0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF);
      }
    }
    return out;
  }
  throw StateError('benchmark frames are aligned');
}

Uint8List _rustCrop(
  Uint8List src,
  int stride,
  int left,
  int top,
  int w,
  int h,
) => FushiComputeImage.instance.bgraToRgba8(
  src,
  stride: stride,
  x: left,
  y: top,
  width: w,
  height: h,
  headerBytes: _header,
);

typedef _Crop =
    Uint8List Function(Uint8List src, int stride, int l, int t, int w, int h);

final class _Case {
  const _Case(
    this.name,
    this.width,
    this.height,
    this.l,
    this.t,
    this.r,
    this.b,
  );
  final String name;
  final int width, height;
  final double l, t, r, b;
}

/// 在原生内存里造一帧，按比例矩形裁剪 [runs] 次，返回各次耗时（µs）。
List<int> _run(_Case c, _Crop crop, int runs) {
  final int stride = c.width * 4 + 64;
  final Pointer<Uint8> frame = malloc<Uint8>(c.height * stride);
  try {
    final Uint8List view = frame.asTypedList(c.height * stride);
    for (int i = 0; i < view.length; i++) {
      view[i] = i * 31;
    }
    final int left = (c.l * c.width).floor();
    final int top = (c.t * c.height).floor();
    final int w = (c.r * c.width).ceil() - left;
    final int h = (c.b * c.height).ceil() - top;
    final List<int> times = <int>[];
    final Stopwatch sw = Stopwatch();
    for (int i = 0; i < runs; i++) {
      sw
        ..reset()
        ..start();
      crop(view, stride, left, top, w, h);
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    return times;
  } finally {
    malloc.free(frame);
  }
}

double _median(List<int> us) {
  final List<int> s = List<int>.of(us)..sort();
  return s[s.length ~/ 2] / 1000;
}

Future<double> _freshIsolate(_Case c, bool rust, int runs) async {
  final List<int> times = <int>[];
  for (int i = 0; i < runs; i++) {
    // 量的是子 isolate 里从拿到帧视图到返回结果字节（真实截帧路径的变换段，含库加载 / 绑定）。
    times.add(
      await Isolate.run(() => _run(c, rust ? _rustCrop : _dartCrop, 1).single),
    );
  }
  return _median(times);
}

Future<void> main() async {
  const List<_Case> cases = <_Case>[
    // 智能遮布默认搜索区域（smart_subtitle_mask_test 的 _region）。
    _Case('1080p 遮布区域', 1920, 1080, 0.1, 0.75, 0.9, 0.97),
    _Case('4K 遮布区域', 3840, 2160, 0.1, 0.75, 0.9, 0.97),
    // 暂停 OCR：整帧。
    _Case('1080p 整帧', 1920, 1080, 0, 0, 1, 1),
    _Case('4K 整帧', 3840, 2160, 0, 0, 1, 1),
  ];
  print('case | Dart 热 ms | Rust 热 ms | Dart 新 isolate ms | Rust 新 isolate ms');
  for (final _Case c in cases) {
    // 预热（JIT 编译 / 暂存区分配）。
    _run(c, _dartCrop, 10);
    _run(c, _rustCrop, 10);
    final double dartHot = _median(_run(c, _dartCrop, 60));
    final double rustHot = _median(_run(c, _rustCrop, 60));
    final double dartFresh = await _freshIsolate(c, false, 15);
    final double rustFresh = await _freshIsolate(c, true, 15);
    print(
      '${c.name} | ${dartHot.toStringAsFixed(2)} | ${rustHot.toStringAsFixed(2)}'
      ' | ${dartFresh.toStringAsFixed(2)} | ${rustFresh.toStringAsFixed(2)}',
    );
  }
}
