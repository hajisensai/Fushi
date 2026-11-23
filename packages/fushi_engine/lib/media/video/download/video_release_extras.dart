/// 发布（种子标题）层面的「只有特典」判据。
///
/// 与下载整理器的文件级判据（`isVideoDownloadExtraFile`）分工：那边看种子里
/// 每个文件的目录/文件名，这里只看一条发布的标题，用来在还没拿到文件列表之前
/// 就把「整条发布只有 PV / NCOP / 菜单」的候选挑出来。
///
/// 刻意**不**复用 `classifyLocalVideoExtra`：它按 `basenameWithoutExtension`
/// 切扩展名，发布标题里的 `AAC2.0` / `DDP5.1` 会被当成扩展名截断，后半截标题
/// 直接丢掉。标记词表本身与它共用 [videoExtraMarkerKind]（同一份词，BUG-5260）。
library;

import 'package:fushi_engine/media/video/metadata/video_extra_markers.dart';

/// 正片迹象：命中任意一条就说明这条发布里有正片，哪怕它顺带打包了特典
/// （`01-12 + NCOP/NCED`、`S01 Complete`）——「含特典」不等于「只有特典」。
final List<RegExp> _mainContentSignals = <RegExp>[
  // S01 / S01E05
  RegExp(r'(?<![a-z0-9])s\d{1,2}(?:e\d{1,4})?(?![a-z0-9])'),
  // E05 / EP05 / Episode
  RegExp(r'(?<![a-z0-9])ep?\d{1,4}(?:v\d)?(?![a-z0-9])'),
  RegExp(r'(?<![a-z])(?:episodes?|batch|complete)(?![a-z])'),
  // `Show - 05` / `Show - 05v2`
  RegExp(r'\s-\s*\d{1,4}(?:v\d)?(?![\d.])'),
  // `[05]` / `[05v2]`
  RegExp(r'\[\d{1,4}(?:v\d)?\]'),
  // `01-12` / `01~12`：要求前后是空白或括号，免得 `x264-10bit` 被当集数区间。
  RegExp(r'(?:^|[\s\[(])\d{1,3}\s*[-~～]\s*\d{1,3}(?=$|[\s\])])'),
  // 第05話 / 全12話 / 全集 / 合集
  RegExp(r'[第全]\s*\d+\s*[話话集巻卷]'),
  RegExp(r'全集|合集'),
];

/// 这条发布（种子标题）是不是「只有特典」的发布：PV / CM / 予告 / Trailer /
/// NCOP / NCED / creditless / Menu / 特典 / 映像特典 / Bonus 等，且没有正片迹象。
///
/// 判据偏保守：拿不准时返回 false（当正片），因为误判「只有特典」的代价是用户
/// 想要的正片被跳过，而漏判只是多下几个特典。
bool looksLikeExtrasOnlyRelease(String title) {
  if (videoExtraMarkerKind(title) == null) return false;
  final String lower = title.toLowerCase();
  return !_mainContentSignals.any((RegExp signal) => signal.hasMatch(lower));
}
