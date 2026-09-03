/// 播放会话装载有声书 / 字幕书音频时的文件解析——**只服务「要读哪些文件」**。
///
/// 读的口径故意宽松：`audioPaths` 没登记时枚举 `audioRoot` 里的音频文件按名排序，
/// 多认出一个文件顶多多一条轨，用户听到不对可以重新导入。
///
/// **这个口径绝不能拿去当删除判据。** 删除走
/// `audiobook_local_files.dart` 的 [audiobookLocalFilePaths]，那里只认显式登记
/// 的路径——「这个目录里有什么」不等于「这条记录拥有什么」。
library;

import 'dart:io';

import 'audio_file_sort.dart';
import 'audiobook_storage.dart';

/// 播放装载用的音频文件列表：[audioPaths] 非空取其中真实存在的；否则枚举
/// [audioRoot] 的直接子音频文件（不递归），按 [compareAudioFilePath] 排序——
/// 排序结果的下标就是 `AudioCue.audioFileIndex` 的含义。
Future<List<File>> resolveAudiobookPlaybackFiles({
  required List<String>? audioPaths,
  required String? audioRoot,
}) async {
  if (audioPaths != null && audioPaths.isNotEmpty) {
    final List<File> files = <File>[];
    for (final String path in audioPaths) {
      final File f = File(path);
      if (await f.exists()) files.add(f);
    }
    return files;
  }
  if (audioRoot != null && audioRoot.trim().isNotEmpty) {
    final Directory dir = Directory(audioRoot);
    if (!await dir.exists()) return <File>[];
    final List<FileSystemEntity> entries = await dir.list().toList();
    return entries
        .whereType<File>()
        .where((File f) => AudiobookStorage.isAudioFile(f.path))
        .toList()
      ..sort((File a, File b) => compareAudioFilePath(a.path, b.path));
  }
  return <File>[];
}
