import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

/// `ffc_text_cue_match` 的 int 参数顺序（与 native/fushi_compute/src/text.rs 的
/// `int_param` 模块一致）。
abstract final class CueMatchIntParam {
  static const int probeCount = 0;
  static const int recoverMinSupport = 1;
  static const int recoverScanLimit = 2;
  static const int recoverMaxFuzzyProbes = 3;
  static const int recoverFuzzyBudgetTotal = 4;
  static const int startClusterSpan = 5;
  static const int probeMinLen = 6;
  static const int shortCueMaxLen = 7;
  static const int shortCueMaxAdvance = 8;
  static const int cueTailOverlap = 9;
  static const int maxExactHits = 10;
  static const int maxConsecutiveMisses = 11;
  static const int count = 12;
}

/// cue 标志位：原文以 `＊` / `*` 开头（旁白 / 标题），不参与聚簇探测。
const int kCueMatchFlagSkipProbe = 1;

/// 读音轨（偏移映射语义见 fushi_audio `_ReadingTrack`）。各映射长度：前四个
/// `text.length + 1`，[fromBase] 为基底轨长度 + 1。
final class CueMatchReadingTrack {
  const CueMatchReadingTrack({
    required this.text,
    required this.toBaseStart,
    required this.toBaseEnd,
    required this.atomReadStart,
    required this.atomReadEnd,
    required this.fromBase,
  });

  final String text;
  final Int32List toBaseStart;
  final Int32List toBaseEnd;
  final Int32List atomReadStart;
  final Int32List atomReadEnd;
  final Int32List fromBase;
}

/// 一档窗口的匹配输出。四个数组按 cue 下标；未命中 `section == -1`、`score == 0`。
/// [start] / [end] 是节内归一化偏移。
final class CueMatchWindowResult {
  const CueMatchWindowResult({
    required this.section,
    required this.start,
    required this.end,
    required this.score,
    required this.matched,
    required this.startCursor,
    required this.finalCursor,
    required this.recoveries,
  });

  final Int32List section;
  final Int32List start;
  final Int32List end;
  final Float64List score;
  final int matched;
  final int startCursor;
  final int finalCursor;

  /// 每次恢复扫描搬动游标：(cue 下标, 原游标, 新游标, 佐证条数)。
  final List<(int, int, int, int)> recoveries;
}

/// native/fushi_compute 文本域：有声书 cue ↔ EPUB 匹配。
///
/// 原生库是硬依赖：库或符号缺失时 [instance] 抛 [FushiComputeUnavailableError]，
/// 不退回任何 Dart 实现（这套算法只有 Rust 一份）。
final class FushiComputeText {
  FushiComputeText._(this._compute, this._cueMatch, this._alignPositions);

  static const String cueMatchSymbol = 'ffc_text_cue_match';
  static const String alignPositionsSymbol = 'ffc_text_align_positions';

  final FushiCompute _compute;
  final _CueMatchDart _cueMatch;
  final _AlignPositionsDart _alignPositions;

  static FushiComputeText? _instance;

  /// 按 [FushiCompute.require] 加载；不可用时抛 [FushiComputeUnavailableError]。
  static FushiComputeText get instance =>
      _instance ??= forLibrary(FushiCompute.require());

  /// 绑定指定的已加载库（测试用）；缺符号时抛 [FushiComputeUnavailableError]。
  static FushiComputeText forLibrary(FushiCompute compute) {
    for (final String symbol in <String>[
      cueMatchSymbol,
      alignPositionsSymbol,
    ]) {
      if (!compute.providesSymbol(symbol)) {
        throw compute.missingSymbols('text', 'missing $symbol');
      }
    }
    return FushiComputeText._(
      compute,
      compute.library.lookupFunction<_CueMatchC, _CueMatchDart>(cueMatchSymbol),
      compute.library.lookupFunction<_AlignPositionsC, _AlignPositionsDart>(
        alignPositionsSymbol,
      ),
    );
  }

  /// 编辑距离位置对齐（有声书 cue 重切的前置步骤），整批一次调用。
  ///
  /// 第 k 对：[a] 是 cue 的归一化听写，[b] 是它命中的正文切片（都按 UTF-16 码元）。
  /// 返回同序的映射，第 k 个长 `a[k].length + 1`：`map[i]` = `a[k][i]` 在 `b[k]` 里对应的
  /// 位置（删除的字符指向下一个对应位置），`map[a.length] = b.length`，单调不减。
  /// `a.length * b.length > maxCells` 的那一对退化为按比例线性映射。原生侧返回非 0
  /// 状态码时抛 [StateError]。
  List<Int32List> alignPositions(
    List<String> a,
    List<String> b, {
    required int maxCells,
  }) {
    if (a.length != b.length) {
      throw ArgumentError.value(b.length, 'b.length', 'must equal a.length');
    }
    final int count = a.length;
    if (count == 0) return const <Int32List>[];
    return using((Arena arena) {
      final (Pointer<Uint16> aUnits, int aLen, Pointer<Int32> aOff) = _packed(
        arena,
        a,
      );
      final (Pointer<Uint16> bUnits, int bLen, Pointer<Int32> bOff) = _packed(
        arena,
        b,
      );
      final int outLen = aLen + count;
      final Pointer<Int32> out = arena<Int32>(outLen);
      final int code = _alignPositions(
        aUnits,
        aLen,
        aOff,
        bUnits,
        bLen,
        bOff,
        count,
        maxCells,
        out,
        outLen,
      );
      if (code != FfcStatus.ok) {
        throw StateError('$alignPositionsSymbol failed with status $code');
      }
      final Int32List all = out.asTypedListOutOfLine(outLen);
      final Int32List offsets = aOff.asTypedListOutOfLine(count + 1);
      return <Int32List>[
        for (int k = 0; k < count; k++)
          Int32List.fromList(
            all.sublist(offsets[k] + k, offsets[k + 1] + k + 1),
          ),
      ];
    });
  }

  /// 把 [texts] 的码元首尾相接拷进原生内存，另给 `texts.length + 1` 项的起点偏移。
  static (Pointer<Uint16>, int, Pointer<Int32>) _packed(
    Arena arena,
    List<String> texts,
  ) {
    int total = 0;
    for (final String t in texts) {
      total += t.length;
    }
    final Pointer<Uint16> units = arena<Uint16>(total == 0 ? 1 : total);
    final Pointer<Int32> offsets = arena<Int32>(texts.length + 1);
    final Uint16List u = units.asTypedListOutOfLine(total);
    final Int32List o = offsets.asTypedListOutOfLine(texts.length + 1);
    int at = 0;
    for (int i = 0; i < texts.length; i++) {
      o[i] = at;
      final String t = texts[i];
      u.setRange(at, at + t.length, t.codeUnits);
      at += t.length;
    }
    o[texts.length] = at;
    return (units, total, offsets);
  }

  /// 对 [windows] 各档搜索窗口跑一遍整本匹配（原生侧按线程并行），一次调用。
  ///
  /// [base] 是归一化后的全书基底轨，[sectionStarts] 各节起点（首项 0、单调不减、
  /// 至少一节）；[cueTexts] 是归一化后的 cue 文本，[cueFlags] 同序标志位。
  /// [intParams] 按 [CueMatchIntParam] 顺序。原生侧返回非 0 状态码时抛 [StateError]。
  List<CueMatchWindowResult> match({
    required String base,
    required Int32List sectionStarts,
    CueMatchReadingTrack? reading,
    required List<String> cueTexts,
    required Uint8List cueFlags,
    required List<int> windows,
    required Int32List intParams,
    required double threshold,
    required double startMinRemainingRatio,
  }) {
    final int cueCount = cueTexts.length;
    final int windowCount = windows.length;
    if (cueFlags.length != cueCount) {
      throw ArgumentError.value(cueFlags.length, 'cueFlags.length');
    }
    if (intParams.length != CueMatchIntParam.count) {
      throw ArgumentError.value(intParams.length, 'intParams.length');
    }
    int cueUnits = 0;
    for (final String t in cueTexts) {
      cueUnits += t.length;
    }
    final int outLen = windowCount * cueCount;
    return using((Arena arena) {
      final Pointer<Uint16> basePtr = _units(arena, base);
      final Pointer<Int32> startsPtr = _ints(arena, sectionStarts);
      Pointer<Uint16> readingPtr = nullptr;
      Pointer<Int32> mapsPtr = nullptr;
      int readingLen = 0;
      if (reading != null) {
        readingLen = reading.text.length;
        readingPtr = _units(arena, reading.text);
        final int r1 = readingLen + 1;
        final int mapsLen = r1 * 4 + base.length + 1;
        mapsPtr = arena<Int32>(mapsLen);
        final Int32List maps = mapsPtr.asTypedListOutOfLine(mapsLen);
        maps.setRange(0, r1, reading.toBaseStart);
        maps.setRange(r1, 2 * r1, reading.toBaseEnd);
        maps.setRange(2 * r1, 3 * r1, reading.atomReadStart);
        maps.setRange(3 * r1, 4 * r1, reading.atomReadEnd);
        maps.setRange(4 * r1, mapsLen, reading.fromBase);
      }
      final Pointer<Uint16> unitsPtr = arena<Uint16>(
        cueUnits == 0 ? 1 : cueUnits,
      );
      final Pointer<Int32> offsetsPtr = arena<Int32>(cueCount + 1);
      final Uint16List units = unitsPtr.asTypedListOutOfLine(cueUnits);
      final Int32List offsets = offsetsPtr.asTypedListOutOfLine(cueCount + 1);
      int at = 0;
      for (int i = 0; i < cueCount; i++) {
        offsets[i] = at;
        final String t = cueTexts[i];
        // 整段拷贝，不逐码元下标写：Dart 3.13.5 JIT 下逐个 `units[at + k] = …`
        // 在「先跑过上百次小匹配、再匹配一整本书」时稳定访问冲突（AOT 不复现）。
        units.setRange(at, at + t.length, t.codeUnits);
        at += t.length;
      }
      offsets[cueCount] = at;
      final Pointer<Uint8> flagsPtr = arena<Uint8>(
        cueCount == 0 ? 1 : cueCount,
      );
      flagsPtr.asTypedListOutOfLine(cueCount).setAll(0, cueFlags);
      final Pointer<Int32> windowsPtr = arena<Int32>(
        windowCount == 0 ? 1 : windowCount,
      );
      windowsPtr.asTypedListOutOfLine(windowCount).setAll(0, windows);
      final Pointer<Int32> paramsPtr = _ints(arena, intParams);

      final int outAlloc = outLen == 0 ? 1 : outLen;
      final Pointer<Int32> outSection = arena<Int32>(outAlloc);
      final Pointer<Int32> outStart = arena<Int32>(outAlloc);
      final Pointer<Int32> outEnd = arena<Int32>(outAlloc);
      final Pointer<Double> outScore = arena<Double>(outAlloc);
      final Pointer<Int32> outStats = arena<Int32>(windowCount * 3 + 1);
      final Pointer<Int32> outRecover = arena<Int32>(outLen * 4 + 1);
      final Pointer<Int32> outRecoverCount = arena<Int32>(windowCount + 1);

      final int code = _cueMatch(
        basePtr,
        base.length,
        startsPtr,
        sectionStarts.length,
        readingPtr,
        readingLen,
        mapsPtr,
        unitsPtr,
        cueUnits,
        offsetsPtr,
        flagsPtr,
        cueCount,
        windowsPtr,
        windowCount,
        paramsPtr,
        intParams.length,
        threshold,
        startMinRemainingRatio,
        outSection,
        outStart,
        outEnd,
        outScore,
        outStats,
        outRecover,
        outRecoverCount,
      );
      if (code != FfcStatus.ok) {
        throw StateError('$cueMatchSymbol failed with status $code');
      }

      final Int32List stats = outStats.asTypedListOutOfLine(windowCount * 3);
      final Int32List recoverCounts = outRecoverCount.asTypedListOutOfLine(
        windowCount,
      );
      final Int32List recover = outRecover.asTypedListOutOfLine(outLen * 4);
      return <CueMatchWindowResult>[
        for (int w = 0; w < windowCount; w++)
          CueMatchWindowResult(
            section: Int32List.fromList(
              outSection
                  .asTypedListOutOfLine(outAlloc)
                  .sublist(w * cueCount, (w + 1) * cueCount),
            ),
            start: Int32List.fromList(
              outStart
                  .asTypedListOutOfLine(outAlloc)
                  .sublist(w * cueCount, (w + 1) * cueCount),
            ),
            end: Int32List.fromList(
              outEnd
                  .asTypedListOutOfLine(outAlloc)
                  .sublist(w * cueCount, (w + 1) * cueCount),
            ),
            score: Float64List.fromList(
              outScore
                  .asTypedListOutOfLine(outAlloc)
                  .sublist(w * cueCount, (w + 1) * cueCount),
            ),
            matched: stats[w * 3],
            startCursor: stats[w * 3 + 1],
            finalCursor: stats[w * 3 + 2],
            recoveries: <(int, int, int, int)>[
              for (int k = 0; k < recoverCounts[w]; k++)
                (
                  recover[w * cueCount * 4 + k * 4],
                  recover[w * cueCount * 4 + k * 4 + 1],
                  recover[w * cueCount * 4 + k * 4 + 2],
                  recover[w * cueCount * 4 + k * 4 + 3],
                ),
            ],
          ),
      ];
    });
  }

  /// 保留对库对象的引用，防止它先于绑定被回收。
  FushiCompute get library => _compute;

  static Pointer<Uint16> _units(Arena arena, String s) {
    final Pointer<Uint16> p = arena<Uint16>(s.isEmpty ? 1 : s.length);
    p.asTypedListOutOfLine(s.length).setRange(0, s.length, s.codeUnits);
    return p;
  }

  static Pointer<Int32> _ints(Arena arena, Int32List xs) {
    final Pointer<Int32> p = arena<Int32>(xs.isEmpty ? 1 : xs.length);
    p.asTypedListOutOfLine(xs.length).setAll(0, xs);
    return p;
  }
}

typedef _CueMatchC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Int32>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Int32>,
      Pointer<Uint16>,
      Size,
      Pointer<Int32>,
      Pointer<Uint8>,
      Size,
      Pointer<Int32>,
      Size,
      Pointer<Int32>,
      Size,
      Double,
      Double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _CueMatchDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Int32>,
      Pointer<Uint16>,
      int,
      Pointer<Int32>,
      Pointer<Uint8>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
      double,
      double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );

typedef _AlignPositionsC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Int32>,
      Pointer<Uint16>,
      Size,
      Pointer<Int32>,
      Size,
      Int64,
      Pointer<Int32>,
      Size,
    );
typedef _AlignPositionsDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Int32>,
      Pointer<Uint16>,
      int,
      Pointer<Int32>,
      int,
      int,
      Pointer<Int32>,
      int,
    );
