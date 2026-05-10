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
}
