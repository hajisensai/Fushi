/// 视频条目的「本机原始文件」判据与删除（删除确认框「同时删除本地文件」的落地）。
///
/// 纯函数部分零 IO，供弹窗决定要不要摆勾选框；[deleteLocalVideoFiles] 是唯一动
/// 磁盘的入口，只删**文件**、绝不递归删目录，且仍被其它库行引用的路径一律保留。
///
/// 路径同一性一律走 [platformPathKey]（绝对化 + Windows 折大小写），**不用**
/// `normalizeVideoPath`：后者不绝对化也不折大小写，Windows 上 `D:\a\b.mkv` 与
/// `d:\a\b.mkv` 会被判成两个文件，「仍被引用」的护栏就会漏命中、把用户还在用的
/// 文件删掉。`normalizeVideoPath` 的语义已固化进 `externalVideoBookUid` 派生的
/// uid，不能改，也不该被借来当删除判据。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, VideoBookRow, deleteLocalFiles, platformPathKey;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/m3u8_playlist.dart' show PlaylistEntry;

/// 删除本机原件的前后挂钩，由上层（`video_library_delete.dart`）接线。
///
/// 分成前后两步不是为了对称，而是顺序本身就是正确性的一部分：**先让引用方放手，
/// 再销毁实体**。还在做种的文件必须先在下载后端标 skip，文件才可以消失；反过来
/// 做，中间任何一次种子校验都会撞上「文件缺失」把整个种子停掉，别的集跟着断。
class LocalVideoFileDeleteHooks {
  const LocalVideoFileDeleteHooks({this.beforeDelete, this.afterDelete});

  /// 磁盘删除**之前**，入参是护栏过滤后真正要删的候选路径。
  final Future<void> Function(List<String> candidates)? beforeDelete;

  /// 磁盘删除**之后**，入参是逐条删除结果（含失败）。
  final Future<void> Function(LocalFileDeleteReport report)? afterDelete;
}

/// 纯函数：[path] 是不是一条可以拿去 `File(path).delete()` 的本机**绝对**路径。
///
/// 两条判据：
/// - 不能是带 scheme 的 URI：远端互联直传、WebDAV、Jellyfin 的 `videoPath` 都是
///   `http(s)://…`，磁盘上没有文件可删。scheme 长度 ≤1 视为盘符（`D:\…` 解析出
///   的 scheme 是 `d`），不算 URI；
/// - 必须绝对：`File('relative/ep01.mkv').delete()` 按**进程当前工作目录**解析，
///   删掉哪个文件取决于 app 启动时的 cwd。删除路径上不接受这种不确定性。
bool isLocalVideoFilePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return false;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme.length > 1) return false;
  return p.isAbsolute(trimmed);
}

/// 纯函数：从 `playlistJson`（`[{title,path}]`）解出各集路径；空 / 坏 JSON → 空表。
List<String> playlistEntryPaths(String? playlistJson) {
  if (playlistJson == null || playlistJson.isEmpty) return const <String>[];
  try {
    final dynamic decoded = jsonDecode(playlistJson);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final dynamic item in decoded)
        if (item is Map<String, dynamic>) PlaylistEntry.fromJson(item).path,
    ];
  } catch (_) {
    return const <String>[];
  }
}

/// 纯函数：这一行视频在本机拥有的原始文件候选（`videoPath` + 播放列表各集），只
/// 保留形如本地绝对路径的。空表 = 没有任何本地文件可删（远端流 / 相对 / 空路径）。
List<String> localVideoFileCandidates({
  required String videoPath,
  String? playlistJson,
}) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String raw in <String>[
    videoPath,
    ...playlistEntryPaths(playlistJson),
  ]) {
    if (!isLocalVideoFilePath(raw)) continue;
    if (seen.add(platformPathKey(raw))) out.add(raw.trim());
  }
  return out;
}

/// 纯函数：这一行有没有本机可删的原始文件——删除确认框据此决定摆不摆
/// 「同时删除本地文件」勾选框。
bool videoBookHasLocalFiles(VideoBookRow row) => localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    ).isNotEmpty;

/// 纯函数：[rows] 引用的全部本地文件路径（按 [platformPathKey] 归一），用作删除
/// 护栏——出现在这个集合里的文件仍被库里某一行引用，绝不删。
Set<String> referencedLocalVideoPaths(Iterable<VideoBookRow> rows) => <String>{
      for (final VideoBookRow row in rows)
        for (final String path in localVideoFileCandidates(
          videoPath: row.videoPath,
          playlistJson: row.playlistJson,
        ))
          platformPathKey(path),
    };

/// 删除 [candidates] 中真实存在、且不在 [stillReferenced]（[platformPathKey] 归一
/// 的路径集）里的文件；逐条结果原样回传，失败不吞。
///
/// 只删 `File`（含符号链接），目录一律跳过——`videoPath` 不该是目录，真遇到也绝不
/// 递归删。单个失败（Windows 句柄占用等）不翻转其它文件的结果。
Future<LocalFileDeleteReport> deleteLocalVideoFiles({
  required Iterable<String> candidates,
  required Set<String> stillReferenced,
}) =>
    deleteLocalFiles(<String>[
      for (final String path in candidates)
        if (!stillReferenced.contains(platformPathKey(path))) path,
    ]);
