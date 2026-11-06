/// 视频海报刮削流水线 ② 文件名/目录名解析层（anitomy 式规则引擎）。
///
/// 输入是一个文件名或目录名（可含扩展名），输出 [ParsedMediaName]：
/// 按序剥离括号块（字幕组/分辨率/校验码/语言标签/来源/年份/集数）、
/// 集数模式、季度模式、电影提示、副标题，剩余部分清理后即主标题。
///
/// 规则引擎本体在 Rust（`native/fushi_compute/src/parse/media_name.rs`，原 Dart 实现的
/// 逐条照搬，删 Dart 前用旧实现冻结了输入 → 输出向量）；本类只是批量 FFI 适配，
/// 原生库是硬依赖（缺失时抛 `FushiComputeUnavailableError`）。批量调用一次 FFI 解析一组
/// 名字，逐个解析大量文件名时优先用 [parseAll]。
///
/// G10 第二步起这是**仓内唯一**的视频文件名规则引擎：导入/分组/种子侧的
/// `parseVideoFilename`（video_filename_parser.dart）是本类的窄化适配——
/// 此前两套引擎对同一文件名可能解出不同集数（分组显示第 5 集、刮削按第 3 集查）。
/// 原第二套引擎独有的识别规则（无「第」的 `12話/12集` 简写、`EP 3` 空格集数、
/// `第N巻`）已并入，勿再另起副本。
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';

/// [FilenameParser.takeTrailingNumericSeason] 的结果：剥出的季号 + 去掉季号后的标题。
class TrailingSeason {
  const TrailingSeason({required this.season, required this.title});

  final int season;
  final String title;
}

/// anitomy 式文件名解析器：从发布组命名中恢复标题/集数/季度等结构化信息。
class FilenameParser {
  FilenameParser._();

  /// 解析单个文件名或目录名（自动剥离 [kVideoExtensions] 里的扩展名）。
  static ParsedMediaName parse(String rawName) =>
      parseAll(<String>[rawName]).single;

  /// 批量 [parse]：一次 FFI 调用，结果与 [rawNames] 一一对应。
  static List<ParsedMediaName> parseAll(List<String> rawNames) =>
      MediaNameNative.instance
          .parseNames(
            rawNames,
            extensions: kVideoExtensions,
            currentYear: DateTime.now().year,
          )
          .map(_toParsed)
          .toList(growable: false);

  /// 给一个视频文件完整路径，返回有序解析候选：
  /// 父目录名解析结果优先（目录名通常更干净、一季只需匹配一次），文件名其次。
  ///
  /// - 父目录名明显不是标题（Downloads / 新建文件夹 / 盘符根 / 单字母 /
  ///   纯数字日期）或解析出空标题时跳过；
  /// - 文件名候选在标题为空且连集数都没有时跳过（如纯设备命名）；
  ///   标题为空但有集数的文件名候选仍保留（供上层做集数一致性校验）。
  static List<ParsedMediaName> candidatesForPath(String filePath) =>
      MediaNameNative.instance
          .candidatesForPaths(
            <String>[filePath],
            extensions: kVideoExtensions,
            currentYear: DateTime.now().year,
          )
          .map(_toParsed)
          .toList(growable: false);

  /// 「标题尾部裸数字季号」的**单一真相源**（BUG-1543）：`Hibike! Euphonium 2`
  /// → `(season: 2, title: 'Hibike! Euphonium')`；尾部不是季号则返回 null。
  ///
  /// 只在**已知这是剧集**的上下文调用（解析时的「已解出集号」门、季目录名回落
  /// `parseVideoPath`）——脱离该上下文，`Ip Man 2` 的 `2` 是片名的一部分而非季号。
  /// 判据收窄到单个 2–9 且左边是空白，另要求剩余头部含文字（纯数字名 `2` 不是「第 2 季」）。
  static TrailingSeason? takeTrailingNumericSeason(String text) {
    final FfcTrailingSeason? hit = MediaNameNative.instance.trailingSeasons(
      <String>[text],
    ).single;
    if (hit == null) return null;
    return TrailingSeason(
      season: hit.season,
      title: text.substring(hit.titleStart, hit.titleEnd),
    );
  }

  static ParsedMediaName _toParsed(FfcParsedName r) => ParsedMediaName(
    title: r.title,
    secondaryTitle: r.secondaryTitle,
    episode: r.episode,
    season: r.season,
    year: r.year,
    titleWithTrailingYear: r.titleWithTrailingYear,
    releaseGroup: r.releaseGroup,
    resolution: r.resolution,
    isMovieHint: r.isMovieHint,
  );
}
