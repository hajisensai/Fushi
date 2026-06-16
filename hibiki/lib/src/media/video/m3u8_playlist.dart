import 'dart:convert';

import 'package:path/path.dart' as p;

/// **纯函数**：从 `VideoBooks.playlistJson` 解析出集数；空 / 非播放列表 / 解析失败
/// 返回 0。供视频库卡片角标与「单视频 vs 播放列表」区分用——返回 ≥2 即播放列表。
int playlistEpisodeCount(String? playlistJson) {
  if (playlistJson == null || playlistJson.isEmpty) return 0;
  try {
    final dynamic decoded = jsonDecode(playlistJson);
    if (decoded is List) return decoded.length;
  } catch (_) {
    // 坏 JSON：当单视频处理（返回 0），不抛。
  }
  return 0;
}

/// 播放列表中的一集：标题 + 视频绝对路径 + 本集自己的播放进度。
///
/// [path] 始终是绝对路径（由 [parseM3u8] 用 baseDir 解析 m3u8 中的相对路径得到，
/// Windows `\` 已归一化为平台分隔符）。
///
/// [positionMs] 记本集自己的播放进度（毫秒，默认 0）；换集时各集互不干扰，下次
/// 打开播放列表回到 currentEpisode 那集的该位置（取代旧的「整个 VideoBook 一个
/// lastPositionMs、换集归零」语义）。
class PlaylistEntry {
  const PlaylistEntry({
    required this.title,
    required this.path,
    this.positionMs = 0,
  });

  final String title;
  final String path;
  final int positionMs;

  /// 返回一个仅 [positionMs] 改变的副本（不可变更新）。
  PlaylistEntry copyWith({int? positionMs}) => PlaylistEntry(
        title: title,
        path: path,
        positionMs: positionMs ?? this.positionMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'path': path,
        'positionMs': positionMs,
      };

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) => PlaylistEntry(
        title: json['title'] as String,
        path: json['path'] as String,
        // 兼容旧 playlistJson（无 positionMs 字段）：缺省回退 0。
        positionMs: (json['positionMs'] as int?) ?? 0,
      );
}

/// 把 [entries] 中第 [index] 集的播放进度更新为 [positionMs]，返回新列表
/// （不可变更新；越界或负位置安全处理）。纯函数，便于单测「切集保存+恢复各集
/// position」逻辑。
List<PlaylistEntry> updateEntryPosition(
  List<PlaylistEntry> entries,
  int index,
  int positionMs,
) {
  if (index < 0 || index >= entries.length) return entries;
  final int clamped = positionMs < 0 ? 0 : positionMs;
  final List<PlaylistEntry> next = List<PlaylistEntry>.of(entries);
  next[index] = next[index].copyWith(positionMs: clamped);
  return next;
}

/// 视频播到 EOF 后播放列表应切到的下一集；没有下一集时返回 null。
///
/// 单集列表 / 越界下标 / 最后一集都不推进，调用方据此保持当前位置。
int? nextPlaylistIndexAfterCompletion(
  List<PlaylistEntry> entries,
  int currentIndex,
) {
  if (entries.length <= 1) return null;
  if (currentIndex < 0 || currentIndex >= entries.length - 1) return null;
  return currentIndex + 1;
}

/// 当前集 load 成功后可后台预热的下一集视频路径。
///
/// [lastPrewarmedPath] 是调用方保存的去重位：同一下一集已经预热过时返回 null，
/// 避免每次 setState / reload 都重复触发整容器 ffmpeg 预抽。
String? nextPlaylistPathToPrewarm({
  required List<PlaylistEntry> entries,
  required int currentIndex,
  required String? lastPrewarmedPath,
}) {
  final int? nextIndex =
      nextPlaylistIndexAfterCompletion(entries, currentIndex);
  if (nextIndex == null) return null;
  final String path = entries[nextIndex].path;
  return path == lastPrewarmedPath ? null : path;
}

/// 解析扩展 M3U（m3u8）播放列表为 [PlaylistEntry] 列表（纯函数，无 IO）。
///
/// 语义：
/// - `#EXTINF:-1,<title>` 记下一条目的标题；逗号后整段为标题（含中文、括号）。
/// - 紧随其后的第一条非空、非注释行视为该集的相对路径，用 [baseDir] 解析成绝对
///   路径。Windows 反斜杠 `\` 先统一成 `/` 再 `p.join` + `p.normalize`，得到当前
///   平台的分隔符表示。
/// - 没有前置 `#EXTINF` 的裸路径行也作为一集，标题回退为该文件的 basename。
/// - 空行、`#EXTM3U` 及其它 `#` 注释行跳过（仅 `#EXTINF` 携带标题）。
List<PlaylistEntry> parseM3u8({
  required String content,
  required String baseDir,
}) {
  final List<PlaylistEntry> entries = <PlaylistEntry>[];
  String? pendingTitle;

  for (final String rawLine in content.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXTINF:')) {
        final int comma = line.indexOf(',');
        // 逗号后整段是标题（保留其中的中文/括号/逗号以外字符）。
        pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : null;
      }
      // 其它注释（#EXTM3U 等）忽略。
      continue;
    }

    // 非注释非空行 = 视频相对/绝对路径。
    final String relWithSlash = line.replaceAll('\\', '/');
    final String absPath = p.normalize(p.join(baseDir, relWithSlash));
    final String title = (pendingTitle != null && pendingTitle.isNotEmpty)
        ? pendingTitle
        : p.basename(absPath);
    entries.add(PlaylistEntry(title: title, path: absPath));
    pendingTitle = null;
  }

  return entries;
}
