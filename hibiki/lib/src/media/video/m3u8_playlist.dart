import 'package:path/path.dart' as p;

/// 播放列表中的一集：标题 + 视频绝对路径。
///
/// [path] 始终是绝对路径（由 [parseM3u8] 用 baseDir 解析 m3u8 中的相对路径得到，
/// Windows `\` 已归一化为平台分隔符）。
class PlaylistEntry {
  const PlaylistEntry({required this.title, required this.path});

  final String title;
  final String path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'path': path,
      };

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) => PlaylistEntry(
        title: json['title'] as String,
        path: json['path'] as String,
      );
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
