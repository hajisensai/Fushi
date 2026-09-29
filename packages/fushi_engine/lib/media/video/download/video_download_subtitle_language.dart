/// 下载任务的**按作品**字幕语言：注入点契约 + 合集名 / 系列键的唯一算法。
///
/// 管线的 `preferredSubtitleLanguages` 是构造期的全局值（设置里的默认字幕语言），
/// 表达不了「这部番要中文字幕、那部番要日文字幕」。app 侧早有「每系列字幕语言
/// 记忆」（偏好 `jimaku_pref_langs`，键 = 合集名小写 trim，字幕工作台在读写），
/// 但管线从来不读它。这里给管线开一个 [VideoDownloadSubtitleLanguageResolver]
/// 注入点：字幕阶段先问它，拿到语言就当作用户对**这部作品**的显式选择（硬过滤 +
/// 排序首选），拿到 null 就走原来的全局链。
///
/// 系列键必须与导入阶段落库的合集名**同源**——否则 AI 下载 / 工作台写的记忆与
/// 管线读的键错位，一个字都对不上。所以合集名的拼法从管线里抽到
/// [videoDownloadCollectionName]，所有读写方只许经 [videoDownloadSeriesKey]。
///
/// 纯 Dart：app 与无头服务端共用；服务端当前没接字幕 registry，注入点留空即可。
library;

import 'dart:async';

/// 字幕阶段向解析器提出的查询：任务身份 + 落库合集名所需的字段。
class VideoDownloadSubtitleLanguageQuery {
  const VideoDownloadSubtitleLanguageQuery({
    required this.jobId,
    required this.title,
    this.year,
    this.metadataProvider,
    this.externalId,
  });

  final String jobId;

  /// 任务标题（= 导入时的合集名主体）。
  final String title;

  /// 任务年份；非空时合集名带 ` (year)` 后缀。
  final int? year;

  /// 作品强身份（`mal` / `tmdb` / …），供想按身份而不是按名字记忆的解析器用。
  final String? metadataProvider;
  final String? externalId;

  /// 与导入阶段合集名同源的记忆键。
  String get seriesKey => videoDownloadSeriesKey(title: title, year: year);
}

/// 返回该作品的显式字幕语言码（`ja` / `zh` / …）；null = 不表态，走全局链。
///
/// 异常由管线吞掉（记日志、按 null 处理）：解析器出错不能让字幕阶段炸。
typedef VideoDownloadSubtitleLanguageResolver = FutureOr<String?> Function(
  VideoDownloadSubtitleLanguageQuery query,
);

/// 下载导入时落库的合集名。legacy 策略与无年份时是裸标题，否则 `Title (2026)`。
///
/// 这是管线 import 阶段的原拼法，抽出来只为让记忆键与它同源；改这里等于改
/// 已入库合集的命名，别随手动。
String videoDownloadCollectionName({
  required String title,
  int? year,
  bool legacy = false,
}) =>
    legacy || year == null ? title : '$title ($year)';

/// 每系列字幕语言记忆的键：合集名小写 trim（与字幕工作台的 `seriesKey` 同构）。
String videoDownloadSeriesKey({required String title, int? year}) =>
    videoDownloadCollectionName(title: title, year: year).trim().toLowerCase();
