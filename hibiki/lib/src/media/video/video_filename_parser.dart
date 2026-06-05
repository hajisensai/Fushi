import 'dart:io';

import 'package:path/path.dart' as p;

/// 从视频文件名解析出的元信息：系列名 + 季 + 集号（Jellyfin / anitomy 式轻量实现）。
///
/// [series] 永不为空（识别不出集号时整名作系列，按单片处理）。[season] / [episode]
/// 识别不出为 null。纯数据，便于单测。
class VideoNameInfo {
  const VideoNameInfo({
    required this.series,
    this.season,
    this.episode,
  });

  /// 系列/番剧名（去字幕组 tag / 画质 / 集号后的可读主干）。
  final String series;

  /// 季号（1-based）；未识别为 null。
  final int? season;

  /// 集号；未识别为 null（此时分组按单片处理）。
  final int? episode;

  @override
  String toString() =>
      'VideoNameInfo(series: $series, season: $season, episode: $episode)';
}

/// 成对括号块（字幕组 / 画质 / 编码 tag）：`[...]` `(...)` `（...）` `【...】`。
final RegExp _bracketBlock = RegExp(r'[\[(（【][^\])）】]*[\])）】]');

/// `S01E02` / `s1.e2` / `S01 E02` —— 季 + 集。
final RegExp _seasonEpisode = RegExp(r'[sS](\d{1,2})[\s._-]*[eE](\d{1,4})');

/// CJK 集号：`第12話` / `第 12 话` / `第12集` / `12話`。
final RegExp _cjkEpisodePrefixed = RegExp(r'第\s*(\d{1,4})\s*[話话集巻]?');
final RegExp _cjkEpisodeSuffixed = RegExp(r'(\d{1,4})\s*[話话集]');

/// `EP05` / `E12` / `Ep 3`（词边界，避免吃进系列名里的字母数字）。
final RegExp _epPrefixed = RegExp(r'\b[eE][pP]?\s*(\d{1,4})\b');

/// 字幕组常见 `Title - 12`（破折号 + 集号）。
final RegExp _dashNumber = RegExp(r'-\s*(\d{1,4})(?=\s|$)');

/// 结尾裸集号 `Title 12`。
final RegExp _trailingNumber = RegExp(r'^(.*?\S)\s+(\d{1,4})\s*$');

/// 视频文件扩展名（小写，含点）。
const Set<String> kVideoExtensions = <String>{
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.m4v',
  '.ts',
  '.flv',
  '.wmv',
  '.mpg',
  '.mpeg',
  '.ogv',
  '.rmvb',
  '.rm',
};

/// 解析视频文件名（可带或不带扩展名）→ [VideoNameInfo]。纯函数，无 IO。
///
/// 识别优先级（越靠前越强）：① `SxxEyy` ② CJK `第N話/话/集` ③ `EP/E` 前缀
/// ④ `- N` 破折号集号 ⑤ 结尾裸数字。都没命中则整名作系列、按单片处理。
VideoNameInfo parseVideoFilename(String filename) {
  final String stem = _stripVideoExtension(filename);

  // ① SxxEyy 在**原始 stem**（保留点/括号）上抓，季+集一次拿到。
  final Match? se = _seasonEpisode.firstMatch(stem);
  if (se != null) {
    final int season = int.parse(se.group(1)!);
    final int episode = int.parse(se.group(2)!);
    final String series = _cleanSeries(stem.substring(0, se.start));
    return VideoNameInfo(
      series: series.isEmpty ? _cleanSeries(stem) : series,
      season: season,
      episode: episode,
    );
  }

  // 其余模式在「去括号 + 分隔符归一」后的可读串上找。
  final String norm = _normalize(stem);

  for (final RegExp re in <RegExp>[
    _cjkEpisodePrefixed,
    _cjkEpisodeSuffixed,
    _epPrefixed,
    _dashNumber,
  ]) {
    final Match? m = re.firstMatch(norm);
    if (m != null) {
      final int episode = int.parse(m.group(1)!);
      final String series = _cleanSeries(norm.substring(0, m.start));
      return VideoNameInfo(
        series: series.isEmpty ? norm : series,
        episode: episode,
      );
    }
  }

  // ⑤ 结尾裸数字：要求数字前有非空白主干，避免把纯数字文件名整个吃成集号。
  final Match? tn = _trailingNumber.firstMatch(norm);
  if (tn != null) {
    final String series = _cleanSeries(tn.group(1)!);
    if (series.isNotEmpty) {
      return VideoNameInfo(series: series, episode: int.parse(tn.group(2)!));
    }
  }

  final String series = _cleanSeries(norm);
  return VideoNameInfo(series: series.isEmpty ? norm.trim() : series);
}

String _stripVideoExtension(String filename) {
  final String ext = p.extension(filename).toLowerCase();
  if (kVideoExtensions.contains(ext)) {
    return filename.substring(0, filename.length - ext.length);
  }
  return filename;
}

/// 去括号块 + 把 `.` `_` 转空格 + 折叠空白。
String _normalize(String s) {
  String r = s.replaceAll(_bracketBlock, ' ');
  r = r.replaceAll(RegExp(r'[._]'), ' ');
  r = r.replaceAll(RegExp(r'\s+'), ' ').trim();
  return r;
}

/// 清洗系列名：去括号块、分隔符归一、去首尾破折号/下划线/空白。
String _cleanSeries(String s) {
  String r = _normalize(s);
  r = r.replaceAll(RegExp(r'^[-–—_\s]+'), '');
  r = r.replaceAll(RegExp(r'[-–—_\s]+$'), '');
  return r.trim();
}

/// 分组里的一集：源文件绝对路径 + 显示标题 + 季/集（用于排序）。
class VideoEpisode {
  const VideoEpisode({
    required this.path,
    required this.title,
    this.season,
    this.episode,
  });

  final String path;
  final String title;
  final int? season;
  final int? episode;
}

/// 同系列的一组（≥1 集）。[episodes] 已按 季→集→标题 升序排好。
class VideoGroup {
  const VideoGroup({required this.series, required this.episodes});

  final String series;
  final List<VideoEpisode> episodes;

  /// 多集 → 作为播放列表导入；单集 → 作为单片导入。
  bool get isPlaylist => episodes.length > 1;
}

/// 把一批视频文件路径按解析出的系列名分组成 [VideoGroup]，组内按 季→集→标题 排序，
/// 组间按系列名（不区分大小写）稳定排序。纯函数（只读文件名，不碰磁盘），便于单测。
List<VideoGroup> groupVideosIntoPlaylists(List<String> paths) {
  final Map<String, List<VideoEpisode>> byKey = <String, List<VideoEpisode>>{};
  final Map<String, String> displaySeries = <String, String>{};

  for (final String path in paths) {
    final VideoNameInfo info = parseVideoFilename(p.basename(path));
    final String key = info.series.toLowerCase();
    displaySeries.putIfAbsent(key, () => info.series);
    byKey.putIfAbsent(key, () => <VideoEpisode>[]).add(VideoEpisode(
          path: path,
          title: p.basenameWithoutExtension(path),
          season: info.season,
          episode: info.episode,
        ));
  }

  final List<VideoGroup> groups = <VideoGroup>[];
  for (final MapEntry<String, List<VideoEpisode>> e in byKey.entries) {
    final List<VideoEpisode> eps = e.value..sort(_compareEpisodes);
    groups.add(VideoGroup(series: displaySeries[e.key]!, episodes: eps));
  }
  groups.sort((VideoGroup a, VideoGroup b) =>
      a.series.toLowerCase().compareTo(b.series.toLowerCase()));
  return groups;
}

/// 排序：季升序（null 视作 1）→ 集升序（null 排末尾）→ 标题。
int _compareEpisodes(VideoEpisode a, VideoEpisode b) {
  final int sa = a.season ?? 1;
  final int sb = b.season ?? 1;
  if (sa != sb) return sa.compareTo(sb);
  final int ea = a.episode ?? (1 << 30);
  final int eb = b.episode ?? (1 << 30);
  if (ea != eb) return ea.compareTo(eb);
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// 扫描目录顶层（非递归）里的视频文件，返回绝对路径列表（按名称排序）。仅此函数碰磁盘。
List<String> listVideoFilesInDirectory(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final String ext = p.extension(entity.path).toLowerCase();
    if (kVideoExtensions.contains(ext)) out.add(entity.path);
  }
  out.sort();
  return out;
}
