/// 视频条目的「本机原始文件」判据与删除（删除确认框「同时删除本地文件」的落地）。
///
/// 纯函数部分零 IO，供弹窗决定要不要摆勾选框；[deleteLocalVideoFiles] 是唯一动
/// 磁盘的入口，只删**文件**、绝不递归删目录，且仍被其它库行引用的路径一律保留。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi/src/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi/src/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 纯函数：[path] 形如本机文件路径（裸路径 / 盘符路径），而不是 http(s)、content、
/// file 等带 scheme 的 URI。远端互联直传、WebDAV、Jellyfin 的 `videoPath` 都是
/// `http(s)://…`，磁盘上没有文件可删。
///
/// scheme 长度 ≤1 视为盘符（`D:\…` 解析出的 scheme 是 `d`），不算 URI。
bool isLocalVideoFilePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return false;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme.length > 1) return false;
  return true;
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
/// 保留形如本地路径的。空表 = 没有任何本地文件可删（远端流 / 空路径）。
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
    final String key = normalizeVideoPath(raw.trim());
    if (seen.add(key)) out.add(raw.trim());
  }
  return out;
}

/// 纯函数：这一行有没有本机可删的原始文件——删除确认框据此决定摆不摆
/// 「同时删除本地文件」勾选框。
bool videoBookHasLocalFiles(VideoBookRow row) => localVideoFileCandidates(
  videoPath: row.videoPath,
  playlistJson: row.playlistJson,
).isNotEmpty;

/// 纯函数：[rows] 引用的全部本地文件路径（归一化后），用作删除护栏。
Set<String> referencedLocalVideoPaths(Iterable<VideoBookRow> rows) => <String>{
  for (final VideoBookRow row in rows)
    for (final String path in localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    ))
      normalizeVideoPath(path),
};

/// 删除 [candidates] 中真实存在、且不在 [stillReferenced]（归一化路径集）里的
/// 文件；返回**真的从磁盘消失**的路径（原样，未归一）。
///
/// - 只删 `File`（含符号链接），目录一律跳过——`videoPath` 不该是目录，真遇到
///   也绝不递归删；
/// - 单个失败（Windows 句柄占用等）记 ErrorLog 后继续，不翻转其它文件的结果。
Future<Set<String>> deleteLocalVideoFiles({
  required Iterable<String> candidates,
  required Set<String> stillReferenced,
}) async {
  final Set<String> removed = <String>{};
  for (final String path in candidates) {
    if (stillReferenced.contains(normalizeVideoPath(path))) continue;
    try {
      final FileSystemEntityType type = await FileSystemEntity.type(
        path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        continue;
      }
      removed.add(path);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'VideoLocalFileDelete',
        'Failed to delete $path: $error',
        stack,
      );
    }
  }
  return removed;
}
