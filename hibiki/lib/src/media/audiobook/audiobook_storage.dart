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

  static Future<String> persistFile(
    File src,
    Directory persistDir, {
    int? dedupeIndex,
  }) async {
    if (src.path.startsWith(persistDir.path)) return src.path;
    String baseName = p.basename(src.path);
    if (dedupeIndex != null) {
      final String ext = p.extension(baseName);
      final String stem = p.basenameWithoutExtension(baseName);
      baseName = '$stem _$dedupeIndex$ext';
    }
    final String dest = p.join(persistDir.path, baseName);
    await src.copy(dest);
    debugPrint('[hibiki-import] persisted ${src.path} → $dest');
    return dest;
  }

  static Future<void> cleanAudioFiles(Directory persistDir) async {
    if (!persistDir.existsSync()) return;
    final List<String> audioExts = [
      '.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.flac', '.wav', '.wma',
    ];
    for (final FileSystemEntity f in persistDir.listSync()) {
      if (f is File &&
          audioExts.contains(p.extension(f.path).toLowerCase())) {
        await f.delete();
      }
    }
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
