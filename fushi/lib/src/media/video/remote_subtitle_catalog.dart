import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource, sameExternalSubtitlePathForMenu, sameSubtitleFilePath;

/// 远端视频的「后端默认外挂字幕」从哪个后端来（Xt3RCTPKhX）。
///
/// 远端（`_isRemote`）覆盖互联、Jellyfin / Emby / Plex、在线源扩展、直链流，
/// 不只是互联：行文案按它给，不再一律写「Fushi 互联服务端字幕」。
enum RemoteDefaultSubtitleOrigin {
  interconnect,
  mediaServer,
  onlineSource,
  stream,
}

/// 远端字幕**文件**行的种类。
enum RemoteSubtitleFileKind {
  /// 后端下发的默认外挂字幕（下载到临时目录）：不可删除。
  backendDefault,

  /// 本机落盘的字幕档（在线下载 / 手动导入，`video_subtitles/`）：可长按删除。
  localFile,
}

/// 远端字幕文件的一行：主字幕菜单、副字幕菜单、手机遥控字幕列表共用。
@immutable
class RemoteSubtitleFileEntry {
  const RemoteSubtitleFileEntry._({
    required this.path,
    required this.label,
    required this.kind,
    this.local,
  });

  final String path;

  /// 文件名（行副标题 / 遥控列表标签）。
  final String label;
  final RemoteSubtitleFileKind kind;

  /// [RemoteSubtitleFileKind.localFile] 时是它的 [SubtitleSource]（删除菜单用）。
  final SubtitleSource? local;

  bool get deletable => kind == RemoteSubtitleFileKind.localFile;
}

/// 远端字幕文件行的**唯一**拼法（Xt3RCTPKhX）。
///
/// 两份互不覆盖的真相：
/// - [backendDefaultPath]：后端下发的默认外挂字幕（`_remoteSubtitlePath`，只放这一种）；
/// - [localFiles]：本机落盘的字幕档（按集持久化，重进 / 换集回来据此重建）。
///
/// 本机档总是成行且可删；后端默认与某条本机档是同一路径时只留本机那行（此前
/// 反过来——留下不可删的「服务端字幕」行、把可删的本机行藏掉，用户就删不掉了）。
List<RemoteSubtitleFileEntry> remoteSubtitleFileEntries({
  required String? backendDefaultPath,
  required List<SubtitleSource> localFiles,
}) {
  final List<RemoteSubtitleFileEntry> entries = <RemoteSubtitleFileEntry>[];
  final String? backend = backendDefaultPath;
  if (backend != null &&
      !localFiles.any(
        (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, backend),
      )) {
    entries.add(
      RemoteSubtitleFileEntry._(
        path: backend,
        label: p.basename(backend),
        kind: RemoteSubtitleFileKind.backendDefault,
      ),
    );
  }
  for (final SubtitleSource source in localFiles) {
    final String? path = source.externalPath;
    if (path == null) continue;
    entries.add(
      RemoteSubtitleFileEntry._(
        path: path,
        label: source.label,
        kind: RemoteSubtitleFileKind.localFile,
        local: source,
      ),
    );
  }
  return entries;
}

/// 纯函数：持久化的本机档路径列表 → 字幕轨列表里的本机档（只留磁盘上还在的）。
/// [exists] 由调用方注入（真实 IO / 测试桩）。顺序保持持久化顺序。
List<SubtitleSource> restoreRemoteLocalSubtitleFiles(
  List<String> persistedPaths, {
  required bool Function(String path) exists,
}) {
  final List<SubtitleSource> restored = <SubtitleSource>[];
  for (final String path in persistedPaths) {
    if (path.isEmpty || !exists(path)) continue;
    if (restored.any(
      (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, path),
    )) {
      continue;
    }
    restored.add(
      SubtitleSource.external(externalPath: path, label: p.basename(path)),
    );
  }
  return restored;
}

/// 纯函数：本机档登记进按集持久化列表（新的在前，按路径去重）。
List<String> addRemoteLocalSubtitleFile(List<String> paths, String path) =>
    <String>[
      path,
      ...paths.where((String e) => !sameSubtitleFilePath(e, path)),
    ];

/// 纯函数：从按集持久化列表移除一个本机档。
List<String> removeRemoteLocalSubtitleFile(List<String> paths, String path) =>
    paths
        .where((String e) => !sameSubtitleFilePath(e, path))
        .toList(growable: false);
