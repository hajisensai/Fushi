import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

abstract final class AudiobookStorage {
  static const Set<String> audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.ogg',
    '.opus',
    '.flac',
    '.wav',
    '.wma',
    '.ac3',
    '.eac3',
    '.mp4',
  };

  static bool isAudioFile(String path) =>
      audioExtensions.contains(p.extension(path).toLowerCase());

  /// TODO-811: 逐个探测音频文件时长（毫秒），下标与 [paths] 对齐。某个文件探测失败
  /// （损坏/解码不支持）返回 0（调用方据此判定无法可靠分文件）。多文件单时间轴有声书
  /// 导入时用这些边界给 cue 重新分配 [AudioCue.audioFileIndex]（见
  /// [reindexCuesByFileBoundaries]）。每个文件用一次性 [AudioPlayer]，探完即释放。
  static Future<List<int>> probeAudioDurationsMs(List<String> paths) async {
    final List<int> out = <int>[];
    for (final String path in paths) {
      final AudioPlayer player = AudioPlayer();
      try {
        final Duration? dur = await player.setFilePath(path);
        out.add(dur?.inMilliseconds ?? 0);
      } catch (_) {
        out.add(0);
      } finally {
        await player.dispose();
      }
    }
    return out;
  }

  static String _stableHash(String input) {
    final List<int> bytes = utf8.encode(input);
    int h = 0x811c9dc5;
    for (final int b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static Future<Directory> ensurePersistDir(String bookUid) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String hash = _stableHash(bookUid);
    final Directory oldDir = Directory(
        p.join(docs.path, 'audiobooks', bookUid.hashCode.toRadixString(16)));
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (!dir.existsSync() && oldDir.existsSync()) {
      oldDir.renameSync(dir.path);
    }
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static Future<String> persistFile(
    File src,
    Directory persistDir, {
    int? dedupeIndex,
  }) async {
    if (p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(src.path))) {
      return src.path;
    }
    String baseName = p.basename(src.path);
    if (baseName.contains('..')) {
      throw ArgumentError('Invalid filename: $baseName');
    }
    if (dedupeIndex != null) {
      final String ext = p.extension(baseName);
      final String stem = p.basenameWithoutExtension(baseName);
      baseName = '$stem _$dedupeIndex$ext';
    }
    final String dest = p.join(persistDir.path, baseName);
    if (!p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(dest))) {
      throw ArgumentError('Path traversal detected: $dest');
    }
    await src.copy(dest);
    debugPrint('[hibiki-import] persisted ${src.path} → $dest');
    return dest;
  }

  static Future<String> persistFileWithProgress(
    File src,
    Directory persistDir, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(src.path))) {
      return src.path;
    }
    final String baseName = p.basename(src.path);
    if (baseName.contains('..')) {
      throw ArgumentError('Invalid filename: $baseName');
    }
    String dest = p.join(persistDir.path, baseName);
    if (!p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(dest))) {
      throw ArgumentError('Path traversal detected: $dest');
    }
    // Avoid silently overwriting a same-basename file already persisted in
    // this batch (e.g. disc1/01.m4a vs disc2/01.m4a from a split audiobook).
    // Append a counter on collision so the positional audioFileIndex maps to
    // distinct files instead of both entries pointing at the last writer.
    if (File(dest).existsSync()) {
      final String ext = p.extension(baseName);
      final String stem = p.basenameWithoutExtension(baseName);
      int counter = 1;
      do {
        dest = p.join(persistDir.path, '$stem _$counter$ext');
        counter++;
      } while (File(dest).existsSync());
    }
    final int totalBytes = await src.length();

    IOSink? sink;
    try {
      sink = File(dest).openWrite();
      int copied = 0;
      await for (final List<int> chunk in src.openRead()) {
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, totalBytes);
      }
      await sink.flush();
    } catch (e) {
      final File destFile = File(dest);
      if (destFile.existsSync()) destFile.deleteSync();
      rethrow;
    } finally {
      await sink?.close();
    }

    final int destLen = await File(dest).length();
    if (destLen != totalBytes) {
      File(dest).deleteSync();
      throw StateError(
        'Copy verification failed: expected $totalBytes bytes, got $destLen',
      );
    }

    debugPrint('[hibiki-import] persisted ${src.path} → $dest '
        '(${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)');
    return dest;
  }

  /// TODO-935 ①A：判断 [filePath] 是否「引用原文件」(reference)，即**不在** app
  /// 内部有声书持久目录 `<appDoc>/audiobooks/` 之下。
  ///
  /// 复制导入的文件恒落 [ensurePersistDir] 派生的 `<appDoc>/audiobooks/<hash>/`，
  /// 故「引用 vs 已复制」无需额外持久化标记，纯由路径与持久根的从属关系派生
  /// （消除特殊情况、零 schema 改动、旧已复制书自动判为已复制）。
  ///
  /// [persistRoot] 为 `<appDoc>/audiobooks` 绝对路径；测试可注入假根。生产取
  /// [audiobooksRootDir]。空路径返回 false（无法判定时按「已复制」保守处理，
  /// 避免误触发删源守卫）。
  static bool isReferencedPath({
    required String filePath,
    required String persistRoot,
  }) {
    if (filePath.isEmpty || persistRoot.isEmpty) return false;
    final String canonicalFile = p.canonicalize(filePath);
    final String canonicalRoot = p.canonicalize(persistRoot);
    if (p.equals(canonicalFile, canonicalRoot)) return false;
    return !p.isWithin(canonicalRoot, canonicalFile);
  }

  /// `<appDoc>/audiobooks` 的绝对路径（复制导入的统一持久根）。
  static Future<String> audiobooksRootDir() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'audiobooks');
  }

  /// 任一 [paths] 落在持久根之外即视为「引用导入」。空列表返回 false。
  static bool anyReferenced({
    required List<String> paths,
    required String persistRoot,
  }) =>
      paths.any(
        (String path) => isReferencedPath(
          filePath: path,
          persistRoot: persistRoot,
        ),
      );

  /// TODO-935 ①A 断链检测：返回 [paths] 中在磁盘上不存在的路径子集（保持原序）。
  /// [exists] 默认查真实文件系统，测试可注入假谓词。空列表返回空列表。
  static List<String> missingPaths(
    List<String> paths, {
    bool Function(String path)? exists,
  }) {
    final bool Function(String) probe =
        exists ?? (String path) => File(path).existsSync();
    return paths.where((String path) => !probe(path)).toList();
  }

  /// [paths] 中是否存在任一断链文件（引用导入后原文件被移动/删除）。
  static bool hasMissingPaths(
    List<String> paths, {
    bool Function(String path)? exists,
  }) =>
      missingPaths(paths, exists: exists).isNotEmpty;

  static Future<void> cleanAudioFiles(Directory persistDir) async {
    if (!persistDir.existsSync()) return;
    for (final FileSystemEntity f in persistDir.listSync()) {
      if (f is File && isAudioFile(f.path)) {
        await f.delete();
      }
    }
  }

  static Future<void> deletePersistDir(String bookUid) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String hash = _stableHash(bookUid);
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      debugPrint('[hibiki-import] deleted persist dir: ${dir.path}');
    }
    final Directory oldDir = Directory(
        p.join(docs.path, 'audiobooks', bookUid.hashCode.toRadixString(16)));
    if (oldDir.existsSync()) {
      await oldDir.delete(recursive: true);
      debugPrint('[hibiki-import] deleted legacy persist dir: ${oldDir.path}');
    }
  }
}
