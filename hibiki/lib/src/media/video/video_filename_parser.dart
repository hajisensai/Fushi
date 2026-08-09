import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/media_extensions.dart';
import 'package:hibiki/src/media/video/scraper/filename_parser.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';

/// 视频扩展名表已收敛到共享真相源 [kVideoExtensions]（media_extensions.dart，
/// 与刮削端 `FilenameParser` 同表）；此处 re-export 维持既有引用面（导入对话框 /
/// 目录扫描 / torrent 选片 / 拖放同步守卫测试）。
export 'package:hibiki/src/media/media_extensions.dart' show kVideoExtensions;

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

/// 解析视频文件名（可带或不带扩展名）→ [VideoNameInfo]。纯函数，无 IO。
///
/// G10 第二步：本函数是刮削端规则引擎 [FilenameParser.parse] 的**窄化适配**——
/// 此前这里另持一套完整规则引擎，同一文件名两边可能解出不同集数（分组显示第 5
/// 集、刮削按第 3 集查）。现在单引擎单真相：[ParsedMediaName.title] 作系列名
/// （引擎解不出标题时退回整个 stem，保持「series 永不为空」契约），
/// season / episode 原样映射；副标题装饰（`～xxx～` / ` - xxx`）与电影关键词
/// （`Movie` / `剧场版`）由引擎剥离，不再留在系列名里。
VideoNameInfo parseVideoFilename(String filename) {
  final RegExp explicitBlock = RegExp(r'\{\[([^\]]+)\]\}');
  final RegExpMatch? explicit = explicitBlock.firstMatch(filename);
  int? explicitNumber(String shortName, String longName) {
    final String? body = explicit?.group(1);
    if (body == null) return null;
    return int.tryParse(
      RegExp(
            '(?:^|;)\\s*(?:$shortName|$longName)\\s*=\\s*(\\d+)',
            caseSensitive: false,
          ).firstMatch(body)?.group(1) ??
          '',
    );
  }

  // MoviePilot/Emby style identity blocks are matching directives, not part
  // of the display title. Keep the original path for the metadata resolver,
  // but strip the block before filename parsing and honor explicit S/E values.
  final String parsedFilename = filename.replaceAll(explicitBlock, ' ');
  final ParsedMediaName parsed = FilenameParser.parse(parsedFilename);
  return VideoNameInfo(
    series: parsed.title.isNotEmpty
        ? parsed.title
        : _fallbackSeries(parsedFilename),
    season: explicitNumber('s', 'season') ?? parsed.season,
    episode: explicitNumber('e', 'episode') ?? parsed.episode,
  );
}

/// 引擎解不出标题（纯日期/设备命名、全括号无标题块、纯集数名等）时的系列名
/// 兜底：剥视频扩展名后的原始 stem（下划线转空格、折叠空白），保证「series
/// 永不为空、按单片分组」的既有契约。
String _fallbackSeries(String filename) {
  String stem = filename;
  final String ext = p.extension(filename).toLowerCase();
  if (kVideoExtensions.contains(ext)) {
    stem = filename.substring(0, filename.length - ext.length);
  }
  stem = stem.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return stem.isEmpty ? filename.trim() : stem;
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

/// 递归扫描 [directory] 及其所有子目录里的视频文件，返回绝对路径列表
/// （按名称排序）。仅此函数碰磁盘。
///
/// 「导入文件夹」的用户心智模型是「找出这个文件夹里的所有视频」，而视频通常
/// 按 `番剧名/Season X/E01.mkv`、`电影合集/某电影/movie.mkv` 这类结构组织——
/// 顶层只有文件夹、没有视频文件。早期只扫顶层（非递归）会让这类目录恒返回空
/// 列表，导入对话框据此误报「无视频」。改递归遍历后任意嵌套深度的视频都能找到。
///
/// [followLinks] 关闭，避免符号链接成环导致无限递归；listSync 自身对无法
/// 访问的子目录会抛 [FileSystemException]，逐项跳过而非整体失败。
List<String> listVideoFilesInDirectory(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity entity
      in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final String ext = p.extension(entity.path).toLowerCase();
    if (kVideoExtensions.contains(ext)) out.add(entity.path);
  }
  out.sort();
  return out;
}
