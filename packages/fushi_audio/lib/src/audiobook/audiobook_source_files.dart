/// 有声书 / 字幕书登记的**原始音频文件**（用户自己导入的原件，不是 app 复制进
/// 持久目录的副本）：判据、解析与删除。
///
/// 两张表（`audiobooks` / `srt_books`）都用同一对列编码原件位置：
/// - `audioPathsJson`：显式文件列表（优先）；
/// - `audioRoot`：旧式「目录 + 按名排序」记录，文件列表要现场枚举。
///
/// 删除只在用户在删除确认框明确勾选「同时删除本地文件」时发生；本文件只删
/// **文件**、绝不递归删目录——`audioRoot` 可能就是用户的音乐文件夹。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'audio_file_sort.dart';
import 'audiobook_storage.dart';

/// 纯函数：这条记录有没有登记原始音频（显式路径列表非空，或有 audioRoot）。
bool hasAudiobookSourceFiles({
  required List<String>? audioPaths,
  required String? audioRoot,
}) =>
    (audioPaths != null && audioPaths.isNotEmpty) ||
    (audioRoot != null && audioRoot.trim().isNotEmpty);

/// 解析原始音频文件列表：[audioPaths] 非空取其中真实存在的；否则枚举 [audioRoot]
/// 直接子文件里的音频文件（不递归），按 [compareAudioFilePath] 排序——与播放会话
/// 装载时的口径完全一致（这就是它播的那些文件）。
Future<List<File>> resolveAudiobookSourceFiles({
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

/// 删除 [resolveAudiobookSourceFiles] 解析出的原件；返回真删掉的路径。
/// 单文件失败（句柄占用等）只打日志并继续，不抛。
Future<Set<String>> deleteAudiobookSourceFiles({
  required List<String>? audioPaths,
  required String? audioRoot,
}) async {
  final Set<String> removed = <String>{};
  for (final File file in await resolveAudiobookSourceFiles(
    audioPaths: audioPaths,
    audioRoot: audioRoot,
  )) {
    try {
      await file.delete();
      removed.add(file.path);
    } catch (e) {
      debugPrint('[fushi-audio] delete source file failed: ${file.path}: $e');
    }
  }
  return removed;
}
