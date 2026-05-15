import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract final class AudiobookStorage {
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
    final String dest = p.join(persistDir.path, baseName);
    if (!p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(dest))) {
      throw ArgumentError('Path traversal detected: $dest');
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

  static Future<void> cleanAudioFiles(Directory persistDir) async {
    if (!persistDir.existsSync()) return;
    final List<String> audioExts = [
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
    ];
    for (final FileSystemEntity f in persistDir.listSync()) {
      if (f is File && audioExts.contains(p.extension(f.path).toLowerCase())) {
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
  }
}
