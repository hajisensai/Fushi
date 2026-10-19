// ffc_text_cue_match 的 FFI 绑定：编组 / 分窗口输出 / 错误码。算法逐位一致性的
// 对拍在 packages/fushi_audio/test/matching/epub_srt_matcher_golden_test.dart。
//
// 原生库是硬依赖：找不到库时这里失败而不是跳过。库定位同
// fushi_compute_library_test.dart（FUSHI_COMPUTE_LIB，缺省 native/fushi_compute/prebuilt）。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

String _libraryPath() {
  final String? env = Platform.environment[kFushiComputeLibEnv];
  if (env != null && env.isNotEmpty) return env;
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_compute${sep}prebuilt';
  final String rel = Platform.isWindows
      ? '$root${sep}windows-x64${sep}fushi_compute.dll'
      : Platform.isMacOS
      ? '$root${sep}macos${sep}libfushi_compute.dylib'
      : '$root${sep}linux-x64${sep}libfushi_compute.so';
  return File(rel).absolute.path;
}

Int32List _params({int maxMisses = 20}) {
  final Int32List p = Int32List(CueMatchIntParam.count);
  p[CueMatchIntParam.probeCount] = 24;
  p[CueMatchIntParam.recoverMinSupport] = 3;
  p[CueMatchIntParam.recoverScanLimit] = 72;
  p[CueMatchIntParam.recoverMaxFuzzyProbes] = 8;
  p[CueMatchIntParam.recoverFuzzyBudgetTotal] = 64;
  p[CueMatchIntParam.startClusterSpan] = 3000;
  p[CueMatchIntParam.probeMinLen] = 6;
  p[CueMatchIntParam.shortCueMaxLen] = 2;
  p[CueMatchIntParam.shortCueMaxAdvance] = 16;
  p[CueMatchIntParam.cueTailOverlap] = 4;
  p[CueMatchIntParam.maxExactHits] = 8;
  p[CueMatchIntParam.maxConsecutiveMisses] = maxMisses;
  return p;
}

void main() {
  final String path = _libraryPath();
  final FushiCompute lib;
  try {
    lib = FushiCompute.load(libraryPath: path);
  } on FushiComputeUnavailableError catch (e) {
    test('fushi_compute native library is required', () {
      fail('native library not usable at $path: $e');
    });
    return;
  }
  final FushiComputeText text = FushiComputeText.forLibrary(lib);

  test('精确命中 / 未命中 / 空 cue，按窗口分块输出', () {
    const String base = 'あいうえおかきくけこさしすせそたちつてと';
    final List<CueMatchWindowResult> r = text.match(
      base: base,
      sectionStarts: Int32List.fromList(<int>[0, 10]),
      cueTexts: <String>['あいうえおか', 'きくけこさしすせ', 'ぬぬぬぬぬぬ', ''],
      cueFlags: Uint8List(4),
      windows: <int>[200, 50],
      intParams: _params(),
      threshold: 0.8,
      startMinRemainingRatio: 0.5,
    );
    expect(r, hasLength(2));
    for (final CueMatchWindowResult w in r) {
      expect(w.section, <int>[0, 0, -1, -1]);
      expect(w.start, <int>[0, 6, -1, -1]);
      expect(w.end, <int>[6, 14, -1, -1]);
      expect(w.score, <double>[1, 1, 0, 0]);
      expect(w.matched, 2);
      expect(w.startCursor, 0);
      expect(w.finalCursor, 14);
      expect(w.recoveries, isEmpty);
    }
  });

  test('读音轨精确命中换算回基底轨', () {
    // 归一化后的两轨：基底「は素敵な子です」，ruby 素敵→すてき 的读音轨
    // 「はすてきな子です」。
    const String base = 'は素敵な子です';
    const String reading = 'はすてきな子です';
    // 读音轨位置 → 基底：は(0) すてき(1..4 → 基底 [1,3)) な(4→3) 子(5→4) で(6→5) す(7→6)
    final Int32List toStart = Int32List.fromList(<int>[
      0,
      1,
      1,
      1,
      3,
      4,
      5,
      6,
      7,
    ]);
    final Int32List toEnd = Int32List.fromList(<int>[
      0,
      1,
      3,
      3,
      3,
      4,
      5,
      6,
      7,
    ]);
    final Int32List atomStart = Int32List.fromList(<int>[
      0,
      1,
      1,
      1,
      4,
      5,
      6,
      7,
      8,
    ]);
    final Int32List atomEnd = Int32List.fromList(<int>[
      1,
      4,
      4,
      4,
      5,
      6,
      7,
      8,
      8,
    ]);
    final Int32List fromBase = Int32List.fromList(<int>[
      0,
      1,
      1,
      4,
      5,
      6,
      7,
      8,
    ]);
    final List<CueMatchWindowResult> r = text.match(
      base: base,
      sectionStarts: Int32List.fromList(<int>[0]),
      reading: CueMatchReadingTrack(
        text: reading,
        toBaseStart: toStart,
        toBaseEnd: toEnd,
        atomReadStart: atomStart,
        atomReadEnd: atomEnd,
        fromBase: fromBase,
      ),
      cueTexts: <String>['はすてきな子'],
      cueFlags: Uint8List(1),
      windows: <int>[200],
      intParams: _params(),
      threshold: 0.8,
      startMinRemainingRatio: 0.5,
    );
    expect(r.single.section, <int>[0]);
    expect(r.single.start, <int>[0]);
    expect(r.single.end, <int>[5]);
    expect(r.single.score, <double>[1]);
  });

  test('非法输入返回错误码 → StateError（不崩）', () {
    expect(
      () => text.match(
        base: 'あいう',
        // 首节起点必须是 0。
        sectionStarts: Int32List.fromList(<int>[1]),
        cueTexts: <String>['あい'],
        cueFlags: Uint8List(1),
        windows: <int>[200],
        intParams: _params(),
        threshold: 0.8,
        startMinRemainingRatio: 0.5,
      ),
      throwsStateError,
    );
  });
}
