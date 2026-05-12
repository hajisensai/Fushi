import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract final class AudiobookStorage {
  static Future<Directory> ensurePersistDir(String bookUid) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String hash = bookUid.hashCode.toRadixString(16);
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static Future<String> persistFile(File src, Directory persistDir) async {
    if (src.path.startsWith(persistDir.path)) return src.path;
    final String dest = p.join(persistDir.path, p.basename(src.path));
    await src.copy(dest);
    debugPrint('[hibiki-import] persisted ${src.path} → $dest');
    return dest;
  }

  static Future<String> persistFileWithProgress(
    File src,
    Directory persistDir, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (src.path.startsWith(persistDir.path)) return src.path;
    final String dest = p.join(persistDir.path, p.basename(src.path));
    final int totalBytes = await src.length();

    final IOSink sink = File(dest).openWrite();
    int copied = 0;
    try {
      await for (final List<int> chunk in src.openRead()) {
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, totalBytes);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close();
      final File destFile = File(dest);
      if (destFile.existsSync()) destFile.deleteSync();
      rethrow;
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

  static Future<void> deletePersistDir(String bookUid) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final String hash = bookUid.hashCode.toRadixString(16);
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      debugPrint('[hibiki-import] deleted persist dir: ${dir.path}');
    }
  }
}
