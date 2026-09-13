import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Full-file identity for card sources. The library UID alone is name-derived.
class VideoSourceFingerprint {
  VideoSourceFingerprint({this.maxCachedFiles = 128})
      : assert(maxCachedFiles > 0);

  static final VideoSourceFingerprint instance = VideoSourceFingerprint();
  final int maxCachedFiles;
  final LinkedHashMap<String, (FileStat, String)> _cache =
      LinkedHashMap<String, (FileStat, String)>();

  static bool isLocalPath(String? path) =>
      path != null &&
      path.isNotEmpty &&
      !RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path);

  Future<String> fingerprint(String path) async {
    if (!isLocalPath(path)) {
      throw const FileSystemException(
        'Card sources require a local video file',
      );
    }
    final String absolutePath = File(path).absolute.path;
    final FileStat stat = await File(absolutePath).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Card source video is missing', path);
    }
    final (FileStat, String)? cached = _cache.remove(absolutePath);
    if (cached != null && _sameFileState(stat, cached.$1)) {
      _cache[absolutePath] = cached;
      return cached.$2;
    }
    final String digest = await Isolate.run<String>(() async {
      final File file = File(absolutePath);
      final String hash = (await sha256.bind(file.openRead()).first).toString();
      if (!_sameFileState(stat, await file.stat())) {
        throw FileSystemException(
          'Video changed while calculating identity',
          absolutePath,
        );
      }
      return hash;
    });
    _cache[absolutePath] = (stat, digest);
    while (_cache.length > maxCachedFiles) {
      _cache.remove(_cache.keys.first);
    }
    return digest;
  }

  Future<bool> matches(String path, String expected) async =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) &&
      await fingerprint(path) == expected;

  static bool _sameFileState(FileStat a, FileStat b) =>
      a.type == FileSystemEntityType.file &&
      b.type == FileSystemEntityType.file &&
      a.size == b.size &&
      a.modified == b.modified &&
      a.changed == b.changed;
}
