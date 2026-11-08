/// TODO-1961-d：库里「路径类」列的重映射规则（纯函数，无 IO）。
///
/// 背景：视频入库是**纯引用绝对路径**（`VideoBooks.videoPath`，字幕 sidecar 走
/// `subtitleSource` / `secondarySubtitleSource`）。引擎侧改名 / 移动
/// （TODO-1961-c）之后，磁盘上的东西换地方了，这些列就成了死路径 —— 做种保住了、
/// 库条目却断了。两件事必须**成对**完成，缺一即断，所以引擎成功后立刻用这里的
/// 规则把库改过来。
///
/// 判据是「**这个文件是否真的被引擎搬走了**」，而不是「这个路径是否落在旧目录
/// 下」：引擎（libtorrent `move_storage` / qBittorrent `setLocation`）只搬种子
/// 自己的文件，Fushi 下载后放在视频旁边的字幕 sidecar 不在种子里、原地不动。
/// 按目录前缀整体重映射会把这些字幕改到一个根本没有文件的新位置（BUG-3538）。
///
/// 为什么单独抽成纯函数：这里全是「什么该改、什么绝不能改」的判断，是最容易
/// 出错也最该被单测钉死的部分。IO 留给仓库层。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/subtitle_text_override_keys.dart';

/// 内嵌字幕轨哨兵前缀（`embedded:<n>`）——不是路径，绝不能当路径重写。
const String kEmbeddedSubtitlePrefix = 'embedded:';

/// 「用户显式关闭字幕」哨兵前缀（`off:`）——同样不是路径。
const String kOffSubtitlePrefix = 'off:';

/// 一个值是否是本地绝对路径（而不是哨兵 / 流媒体 URL / 相对路径）。
///
/// 字幕源列是四态编码（绝对路径 / `embedded:<n>` / `off:` / null），
/// `videoPath` 还可能是 http(s) 流媒体。只有真·本地绝对路径才参与重映射。
bool isRemappableMediaPath(String? value) {
  if (value == null) return false;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith(kEmbeddedSubtitlePrefix)) return false;
  if (trimmed.startsWith(kOffSubtitlePrefix)) return false;
  // 流媒体书：videoPath 是 http/https，磁盘上没有对应文件。
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return false;
  }
  return p.isAbsolute(trimmed);
}

/// 一次改名 / 移动里**真实被引擎搬动**的文件集合（本机坐标，旧路径 → 新路径）。
///
/// 只有逐文件全等命中才算「被搬走」；落在同一目录下但不在集合里的文件（字幕
/// sidecar、用户自己放的附件）一律原样保留。路径比较走 `p.canonicalize`
/// （Windows 大小写不敏感、`/` `\` 混用由它负责）。
class MovedMediaFiles {
  MovedMediaFiles(Map<String, String> moves)
    : _byKey = <String, String>{
        for (final MapEntry<String, String> move in moves.entries)
          if (isRemappableMediaPath(move.key) &&
              isRemappableMediaPath(move.value))
            _key(move.key): p.normalize(move.value.trim()),
      },
      _originals = <String, String>{
        for (final MapEntry<String, String> move in moves.entries)
          if (isRemappableMediaPath(move.key) &&
              isRemappableMediaPath(move.value))
            _key(move.key): p.normalize(move.key.trim()),
      };

  final Map<String, String> _byKey;

  /// 规范化键 → 调用方给的旧路径原样（保留大小写）：按文件名派生的键
  /// （字幕覆盖层 `file:<文件名>`）必须用原始文件名，不能用 canonicalize 后的小写。
  final Map<String, String> _originals;

  /// 全部「旧路径 → 新路径」（旧路径保留原始大小写，均已 normalize）。
  Iterable<(String, String)> get moves sync* {
    for (final MapEntry<String, String> entry in _byKey.entries) {
      yield (_originals[entry.key]!, entry.value);
    }
  }

  /// [a] 与 [b] 是否同一目录（与 [newPathFor] 同一套比较口径）。
  static bool sameDirectory(String a, String b) =>
      _key(p.dirname(a.trim())) == _key(p.dirname(b.trim()));

  bool get isEmpty => _byKey.isEmpty;

  /// [value] 被搬到的新路径；不是被搬走的文件（含哨兵 / URL / null）返回 null。
  String? newPathFor(String? value) {
    if (!isRemappableMediaPath(value)) return null;
    return _byKey[_key(value!)];
  }

  static String _key(String path) => p.canonicalize(path.trim());
}

/// 一行视频书在一次重映射里要改的列（全 null = 这行不受影响，别写库）。
class VideoPathRemap {
  const VideoPathRemap({
    this.videoPath,
    this.subtitleSource,
    this.secondarySubtitleSource,
  });

  final String? videoPath;
  final String? subtitleSource;
  final String? secondarySubtitleSource;

  /// 这行是否真有列要改（避免为没变化的行发无谓的 UPDATE）。
  bool get isEmpty =>
      videoPath == null &&
      subtitleSource == null &&
      secondarySubtitleSource == null;
}

/// 算出一行视频书在 [moved] 下要改的列。
///
/// 三列各自独立判断：视频被移走了但字幕是内嵌轨（`embedded:0`）或没被引擎搬动
/// 的 sidecar 时，只改 videoPath、不碰字幕列；种子里自带的字幕文件被一起搬走时
/// 字幕列跟着改。
VideoPathRemap remapVideoBookPaths({
  required String? videoPath,
  required String? subtitleSource,
  required String? secondarySubtitleSource,
  required MovedMediaFiles moved,
}) {
  return VideoPathRemap(
    videoPath: moved.newPathFor(videoPath),
    subtitleSource: moved.newPathFor(subtitleSource),
    secondarySubtitleSource: moved.newPathFor(secondarySubtitleSource),
  );
}

/// 多集播放列表书（`playlistJson` = `[{title,path,positionMs}]`）在 [moved] 下的
/// 新 JSON；没有任何一集被搬走（或 JSON 读不懂）返回 null = 这列不动。
///
/// 只改命中集的 `path`，其余键（`positionMs` 各集进度、将来新增的字段）原样
/// 保留——播放列表的进度就存在这里，重写整条会把它们抹掉。
String? remapPlaylistJson(String? playlistJson, MovedMediaFiles moved) {
  if (playlistJson == null || playlistJson.trim().isEmpty || moved.isEmpty) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(playlistJson);
  } on FormatException {
    return null;
  }
  if (decoded is! List<Object?>) return null;
  bool changed = false;
  final List<Object?> next = <Object?>[];
  for (final Object? entry in decoded) {
    final Object? path = entry is Map<String, Object?> ? entry['path'] : null;
    final String? newPath = path is String ? moved.newPathFor(path) : null;
    if (newPath == null) {
      next.add(entry);
      continue;
    }
    changed = true;
    next.add(<String, Object?>{
      ...entry! as Map<String, Object?>,
      'path': newPath,
    });
  }
  return changed ? jsonEncode(next) : null;
}

/// 字幕文本覆盖层（`video_subtitle_text_overrides`）在 [moved] 下要换的源键：
/// 返回 `videoKey → {旧 sourceKey → 新 sourceKey}`，只含真变了的键。
///
/// 外挂字幕的源键只取文件名（`file:<文件名>`，见
/// [subtitleTextOverrideSourceKey]），所以**改名**会让播放时算出的键变掉，
/// 旧行全部对不上、手改的字幕静默失效；只搬目录不改名的移动键不变，不出现在结果里。
///
/// 范围按「这一集」限定：视频键 `bookUid`（第 0 集 / 单视频）与 `bookUid#<n>`
/// （播放列表第 n 集）各自只认 ① 与该集视频**同目录**被搬走的文件（播放器自动挂
/// 的 sidecar 字幕都在视频旁边，同目录内文件名唯一，不会歧义）；② 本行
/// `subtitleSource` / `secondarySubtitleSource` 指着的被搬走文件（用户从别处挑的
/// 字幕）。①优先于②。视频路径一律取**旧**值（[moved] 之前的库值）。
Map<String, Map<String, String>> remapSubtitleOverrideSourceKeys({
  required String bookUid,
  required String? videoPath,
  required String? playlistJson,
  required String? subtitleSource,
  required String? secondarySubtitleSource,
  required MovedMediaFiles moved,
}) {
  final Map<String, Map<String, String>> result =
      <String, Map<String, String>>{};
  if (moved.isEmpty) return result;
  // 集下标 → 这一集视频的（旧）路径；第 0 集 videoPath 与 playlist[0] 共用视频键。
  final Map<int, List<String>> episodeVideos = <int, List<String>>{
    0: <String>[if (isRemappableMediaPath(videoPath)) videoPath!],
  };
  if (playlistJson != null && playlistJson.trim().isNotEmpty) {
    Object? decoded;
    try {
      decoded = jsonDecode(playlistJson);
    } on FormatException {
      decoded = null;
    }
    if (decoded is List<Object?>) {
      for (int i = 0; i < decoded.length; i++) {
        final Object? entry = decoded[i];
        final Object? path = entry is Map<String, Object?>
            ? entry['path']
            : null;
        if (path is String && isRemappableMediaPath(path)) {
          (episodeVideos[i] ??= <String>[]).add(path);
        }
      }
    }
  }
  final Set<String> pickedSources = <String>{
    for (final String? source in <String?>[
      subtitleSource,
      secondarySubtitleSource,
    ])
      if (moved.newPathFor(source) != null) p.canonicalize(source!.trim()),
  };
  for (final MapEntry<int, List<String>> episode in episodeVideos.entries) {
    final String videoKey = subtitleTextOverrideVideoKey(bookUid, episode.key);
    final Map<String, String> picked = <String, String>{};
    final Map<String, String> sameDir = <String, String>{};
    for (final (String oldPath, String newPath) in moved.moves) {
      final String from = subtitleTextOverrideSourceKey(oldPath);
      final String to = subtitleTextOverrideSourceKey(newPath);
      if (from == to) continue;
      if (episode.value.any(
        (String video) => MovedMediaFiles.sameDirectory(video, oldPath),
      )) {
        sameDir[from] = to;
      } else if (pickedSources.contains(p.canonicalize(oldPath))) {
        picked[from] = to;
      }
    }
    final Map<String, String> keys = <String, String>{...picked, ...sameDir};
    if (keys.isNotEmpty) result[videoKey] = keys;
  }
  return result;
}

/// 下载后端里一个文件的改名回执（种子 [infoHash] 的第 [fileIndex] 个文件，新的
/// 种子内相对路径 [newRelativePath]，POSIX `/`）。库侧据此改任务文件行的
/// `current_relative_path`，否则任务删除 / 打开位置会拼出旧名。
class TorrentFileRenameRecord {
  const TorrentFileRenameRecord({
    required this.infoHash,
    required this.fileIndex,
    required this.newRelativePath,
  });

  final String infoHash;
  final int fileIndex;
  final String newRelativePath;
}

/// 一次下载改名 / 移动在引擎侧**已经成功**之后，库与下载任务表要落的全部变化。
class DownloadRelocation {
  const DownloadRelocation({
    required this.infoHash,
    required this.movedFiles,
    this.newBackendSavePath,
    this.renamedFileIndex,
    this.renamedRelativePath,
  });

  /// 被改名 / 移动的种子（任务行 `backendTaskId` / `torrentHash`）。
  final String infoHash;

  /// 引擎真实搬动的文件（本机坐标）。
  final MovedMediaFiles movedFiles;

  /// 移动后种子在**后端坐标**里的新保存位置（任务行 `observedSavePath`）；
  /// 改名时为 null。
  final String? newBackendSavePath;

  /// 改名的种子内文件下标与新的种子内相对路径（POSIX `/`，任务文件行
  /// `currentRelativePath`）；移动时为 null。
  final int? renamedFileIndex;
  final String? renamedRelativePath;
}
