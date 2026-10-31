/// 标题归一化（刮削流水线第③层）。
///
/// 把来自文件名解析层与各数据源的标题拉到同一比较平面：
/// 全角→半角、繁（含日文旧字体/新字体变体）→简、小写化、
/// 去装饰符号、连续空白折叠；并提供分词与相似度计算。
///
/// 算法在 Rust 计算内核里（native/fushi_compute/src/parse/title_score.rs，繁简映射与
/// 装饰符号表在 native/fushi_compute/tool/gen_title_tables.dart），这里只是经
/// `fushi_compute` FFI 调过去的外壳——**没有 Dart 回退实现**，原生库缺失时抛
/// `FushiComputeUnavailableError`。结果与原 Dart 实现逐位一致（迁移时用旧实现冻结的
/// 向量对拍，见 packages/fushi_compute/test/title_score_test.dart）。
///
/// 纯静态工具类，无状态、无 IO、无用户可见字符串。
library;

import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart' show TitleScoreNative;

/// 标题归一化与相似度工具。
class TitleNormalizer {
  const TitleNormalizer._();

  /// 归一化：全角→半角 → 繁→简 → 去装饰符号（替换为空格）→ 小写 → 空白折叠。
  ///
  /// 装饰符号替换为空格而不是直接删除，避免把本不相邻的两段文字
  /// 粘连成一个假词（如 `A～B` 变 `ab`）；随后统一折叠空白。
  static String normalize(String title) => TitleScoreNative.normalize(title);

  /// 批量 [normalize]（一次 FFI 调用），与输入同序。
  static List<String> normalizeAll(List<String> titles) =>
      TitleScoreNative.normalizeAll(titles);

  /// 分词（输入应为 [normalize] 的输出）：
  /// - ASCII/其它字母数字连续段整体为一个 token（按空白与分隔天然切开）；
  /// - CJK（汉字/假名）连续段按 2-gram 切——中文日文无空格分界，
  ///   bigram 是无词典条件下最稳的相似度基元；
  /// - 长度为 1 的 CJK 段保留原字。
  static List<String> tokens(String normalized) =>
      TitleScoreNative.tokens(normalized);

  /// 相似度 [0,1]：先各自 [normalize]，再取
  /// token 集 Dice 系数与归一化 Levenshtein 相似度（1 - dist/maxLen）的较大者。
  ///
  /// Dice 抗子串/词序差异，Levenshtein 抗少量错字；取 max 兼顾两类失真。
  static double similarity(String a, String b) =>
      TitleScoreNative.similarity(a, b);

  /// [similarity] 的已归一化输入版：两个参数都必须是 [normalize] 的输出。
  ///
  /// 对同一个查询打一批候选时用 [similarityNormalizedBatch]（一次 FFI 调用）。
  static double similarityNormalized(String na, String nb) =>
      TitleScoreNative.similarityNormalized(na, nb);

  /// 已归一化查询 [query] 对一批已归一化候选逐个打分（一次 FFI 调用），
  /// 结果与逐个调 [similarityNormalized] 逐位一致。
  static Float64List similarityNormalizedBatch(
    String query,
    List<String> candidates,
  ) => TitleScoreNative.similarityNormalizedBatch(query, candidates);

  /// 已归一化的 [queries] × [candidates] 相似度矩阵（一次 FFI 调用）：第
  /// `q * candidates.length + c` 项 = `similarityNormalized(queries[q], candidates[c])`。
  static Float64List similarityNormalizedMatrix(
    List<String> queries,
    List<String> candidates,
  ) => TitleScoreNative.similarityNormalizedMatrix(queries, candidates);
}
