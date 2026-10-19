import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart' show AudioTextFoldNative;

/// 日文正文归一化工具（有声书 / 阅读器匹配坐标系）。
///
/// 白名单规则：只保留假名/汉字/CJK 扩展/字母数字，其余剥掉；值折叠（全角→ASCII /
/// 大写→小写 / 半角片假名→全角 / 片假名→平假名）。`audiobook_bridge.dart` 的 JS
/// `__fushiIsSkippable` 与阅读器 JS `foldCodePoint` 必须与此严格镜像。
///
/// 实现只有一份：Rust 计算内核 `native/fushi_compute/src/parse/fold.rs`（经
/// fushi_compute 的 [AudioTextFoldNative]，整段一次 FFI，不逐码点跨边界）。没有 Dart
/// 回退：原生库缺失时抛 `FushiComputeUnavailableError`。逐码点口径由
/// `test/matching/audio_text_normalizer_native_test.dart` 钉住旧 Dart 实现的摘要。
class AudioTextNormalizer {
  AudioTextNormalizer._();

  /// 归一化文本：剥掉非白名单字符，大小写统一，片假名转平假名。
  ///
  /// 单条一次 FFI：一批文本（token / 句子 / cue）要归一化时用 [normalizeBatch] 或
  /// [normalizeConcat]，不要在循环里逐条调本函数。
  static String normalize(String s) => AudioTextFoldNative.instance.fold(s);

  /// [pieces] 各自归一化（第 k 项等于 `normalize(pieces[k])`），整批一次 FFI。
  static List<String> normalizeBatch(List<String> pieces) =>
      AudioTextFoldNative.instance.foldBatch(pieces);

  /// 将 [s] 归一化后追加到 [buf]，用于拼接多段文本后统一处理。逐段调用时每段多一次
  /// 字符串拷贝；整批拼接用 [normalizeConcat]。
  static void appendNormalized(StringBuffer buf, String s) {
    buf.write(normalize(s));
  }

  /// [pieces] 各自归一化后首尾相接（等于逐段 [appendNormalized] 进同一个 buffer），以及每段
  /// 在结果里的起点（`starts[k]` = 第 k 段之前所有段归一化后的总长）。整批一次 FFI。
  static ({String text, List<int> starts}) normalizeConcat(
    List<String> pieces,
  ) {
    final ({String text, Uint32List pieceStarts}) r = AudioTextFoldNative
        .instance
        .foldConcat(pieces);
    return (text: r.text, starts: r.pieceStarts);
  }

  /// 归一化并记下每个归一化字符在原文里的 **UTF-16 码元区间**，用于把匹配器
  /// 给出的归一化偏移换回原文子串（带标点、换行等被剥掉的字符）。
  ///
  /// 偏移按 **UTF-16 码元** 计，与匹配器用 `String.length` / `indexOf` 得到的
  /// 归一化偏移同一口径：`text.length == starts.length == ends.length`；CJK 扩展 B
  /// 及以后的星光面码点在归一化文本里也占两个码元，两个码元映到同一原文区间。
  /// 原文 `s.substring(starts[a], ends[b - 1])` 就是归一化区间 `[a, b)` 对应的原文。
  static NormalizedTextWithOffsets normalizeWithOffsets(String s) {
    final ({String text, Uint32List starts}) folded = AudioTextFoldNative
        .instance
        .foldWithStarts(s);
    final String text = folded.text;
    final Uint32List starts = folded.starts;
    final Uint32List ends = Uint32List(starts.length);
    for (int i = 0; i < starts.length; i++) {
      // 被保留的码点输出宽度等于输入宽度：输出码元是代理 ⇔ 输入是补充平面码点。
      final int unit = text.codeUnitAt(i);
      ends[i] = starts[i] + (unit >= 0xD800 && unit <= 0xDFFF ? 2 : 1);
    }
    return NormalizedTextWithOffsets(text, starts, ends);
  }
}

/// [AudioTextNormalizer.normalizeWithOffsets] 的结果。
class NormalizedTextWithOffsets {
  const NormalizedTextWithOffsets(this.text, this.starts, this.ends);

  /// 归一化文本。
  final String text;

  /// `text[i]` 对应原文码元区间 `[starts[i], ends[i])`。
  final List<int> starts;
  final List<int> ends;

  /// 归一化区间 `[from, to)` 对应的原文子串（[original] 必须是当初传入的原文）。
  /// 空区间返回空串。
  String originalSlice(String original, int from, int to) {
    if (to <= from || from < 0 || to > text.length) return '';
    return original.substring(starts[from], ends[to - 1]);
  }
}
