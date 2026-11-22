/// 字幕候选「属于第几季」的**来源事实**（HBK-AUDIT-049）。
///
/// 检索请求里的季号是调用方的**意图**（「我要第二季」），不是字幕的事实。Jimaku /
/// AJATT 曾把请求季号原样抄成每个候选的季号：文本回退搜到的第一季条目、文件名写着
/// `S01E01` 的字幕，都被标成第二季，批量再优先信这份标签，第一季字幕就被写进第二季。
///
/// 这里只认来源自己能证明的季号：文件名里的季号，或来源条目的身份（AniList id 已与
/// 请求的作品对上 = 这个条目就是请求的那一季；条目名写着唯一季号）。都证明不了就是
/// null，交给批量按「季号未知」处理，而不是拿意图冒充事实。
library;

import 'package:fushi_engine/media/video/jimaku_client.dart'
    show detectSubtitleLanguage;
import 'package:fushi_engine/media/video/season_marker_parser.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:path/path.dart' as p;

const Set<String> _kStrippedSubtitleExtensions = <String>{
  'srt',
  'ass',
  'ssa',
  'vtt',
  'zip',
  'rar',
  '7z',
};

/// 字幕文件名（含整季包名）里写明的季号：`Show S02E01.ja.srt` → 2；没写为 null。
/// 先剥扩展名与语言后缀，免得 `.ja` 之类干扰解析。纯函数。
int? subtitleFileNameSeason(String fileName) {
  String stem = p.basename(fileName.trim());
  if (stem.isEmpty) return null;
  final int dot = stem.lastIndexOf('.');
  if (dot > 0) {
    final String ext = stem.substring(dot + 1).toLowerCase();
    if (_kStrippedSubtitleExtensions.contains(ext)) {
      stem = stem.substring(0, dot);
    }
  }
  final int dot2 = stem.lastIndexOf('.');
  if (dot2 > 0) {
    final String tail = stem.substring(dot2 + 1);
    if (detectSubtitleLanguage('_.$tail.srt') != null) {
      stem = stem.substring(0, dot2);
    }
  }
  final int? season = parseVideoFilename(stem).season;
  return season != null && season > 0 ? season : null;
}

/// 来源条目（Jimaku / AJATT 一个条目 = 一部作品的一季）层面的季号事实。纯函数。
///
/// - [identityConfirmed]：条目的 AniList id 与请求作品的 AniList id 相等。AniList 与
///   Jimaku 都按季各登记一个条目，id 对上即「这个条目就是请求的那一季」，此时
///   [requestedSeason] 才能当事实用。
/// - 否则看条目名（[entryNames]）里**唯一**的季度记号（「2nd Season」「第2期」）。
/// - 都没有 → null（季号未知）。
int? subtitleSourceEntrySeason({
  required bool identityConfirmed,
  required int? requestedSeason,
  Iterable<String?> entryNames = const <String?>[],
}) {
  if (identityConfirmed && requestedSeason != null && requestedSeason > 0) {
    return requestedSeason;
  }
  final Set<int> marked = <int>{
    for (final String? name in entryNames)
      if (name != null && name.trim().isNotEmpty)
        ...detectVideoSeasonsInText(name),
  };
  return marked.length == 1 ? marked.single : null;
}

/// 单个字幕文件的季号事实：文件名写明的季号优先（比条目更具体），否则用条目层面的
/// 季号（[subtitleSourceEntrySeason]）。纯函数。
int? subtitleSourceFileSeason({
  required String fileName,
  required int? entrySeason,
}) => subtitleFileNameSeason(fileName) ?? entrySeason;
