/// 拖进音乐页的文件怎么分（拍板台 left3568：音乐页收拖放，口径与音乐来源扫描一致）。
///
/// - 目录 → 登记成常驻音乐来源并扫描（与「添加音乐文件夹」同一条路径）；
/// - 曲目文件（纯音频 + MV 视频容器，[isMusicLibraryMediaPath]）→ 交给
///   `MusicAudioIntake.importMusicFiles`：已被音乐来源覆盖的重扫那个来源，其余「仅此一次」
///   导入；
/// - 其余（书、字幕、图片 …）不收，落点给「本页收什么」的提示。
///
/// 只在音乐页这个落点放开视频容器：视频页拖放与 video→music 存量迁移仍只把纯音频交给
/// 音乐库（`importAudioFiles`），视频不会被分流进曲库。
library;

import 'package:fushi_engine/media/media_extensions.dart'
    show isMusicLibraryMediaPath;

/// 一次拖放分好的三组路径（保持拖入顺序）。
class MusicDropPlan {
  const MusicDropPlan({
    required this.folders,
    required this.files,
    required this.unsupported,
  });

  /// 要登记成音乐来源的目录。
  final List<String> folders;

  /// 要导入曲库的曲目文件（纯音频 / MV）。
  final List<String> files;

  /// 音乐页不收的路径。
  final List<String> unsupported;

  /// 有没有音乐页能收的东西。
  bool get hasAny => folders.isNotEmpty || files.isNotEmpty;
}

/// 纯函数：按 [isDirectory]（真 app = `FileSystemEntity.isDirectorySync`，测试注入）把
/// 拖入的 [paths] 分组。
MusicDropPlan planMusicDrop(
  Iterable<String> paths, {
  required bool Function(String path) isDirectory,
}) {
  final List<String> folders = <String>[];
  final List<String> files = <String>[];
  final List<String> unsupported = <String>[];
  for (final String path in paths) {
    if (path.trim().isEmpty) continue;
    if (isDirectory(path)) {
      folders.add(path);
    } else if (isMusicLibraryMediaPath(path)) {
      files.add(path);
    } else {
      unsupported.add(path);
    }
  }
  return MusicDropPlan(
    folders: folders,
    files: files,
    unsupported: unsupported,
  );
}
