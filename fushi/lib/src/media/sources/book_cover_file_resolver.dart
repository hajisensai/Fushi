/// 书封面落盘路径解析（TODO-1319 / BUG-612 / TODO-1388 / BUG-703）。
///
/// 叶子文件：书架网格、制卡、书图刮削共用同一份解析；从 `ReaderFushiSource`
/// 拆出来，是为了让刮削服务不必为一个纯函数把整个阅读器源拉进导入图。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Real-filesystem child lister for [resolveBookCoverCaseInsensitive]. Returns the
/// child entity paths of [dir], or an empty list if it is missing/unreadable.
List<String> _listDirEntries(String dir) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return const <String>[];
  try {
    return d
        .listSync(followLinks: false)
        .map((FileSystemEntity e) => e.path)
        .toList();
  } catch (_) {
    return const <String>[];
  }
}

/// Case-insensitive on-disk resolution of a book cover (TODO-1319 / BUG-612).
///
/// Walks each relative candidate in [relPaths] segment by segment under
/// [extractDir], matching each segment against the real directory entries
/// from [listDir] -- exact case first, then case-insensitively. Returns the
/// first candidate that fully resolves to an on-disk path, or null. This lets
/// a coverPath whose case was mangled by a case-insensitive host still find
/// the case-preserved extracted file on a case-sensitive device.
///
/// Pure + injectable ([listDir]) so it is unit-testable with a mock
/// filesystem; the instance path wires in [_listDirEntries].
String? resolveBookCoverCaseInsensitive({
  required String extractDir,
  required List<String> relPaths,
  required List<String> Function(String dir) listDir,
}) {
  // 一次调用内同一目录只列一次（novel-9）：候选 `cover.jpg` / `cover.jpeg` /
  // `cover.png` 与声明封面的首段都从 extractDir 起走，之前每个候选各
  // `listSync` 一遍同一个目录，书架上每本无封面书一次刷新要列 4 次。
  final Map<String, List<String>> listed = <String, List<String>>{};
  for (final String rel in relPaths) {
    if (rel.isEmpty || p.isAbsolute(rel)) continue;
    final List<String> segs = p
        .split(rel)
        .where((String s) => s.isNotEmpty && s != '.' && s != '/')
        .toList();
    if (segs.isEmpty) continue;
    String current = extractDir;
    bool resolvedAll = true;
    for (final String seg in segs) {
      final List<String> children = listed.putIfAbsent(
        current,
        () => listDir(current),
      );
      String? match;
      for (final String child in children) {
        if (p.basename(child) == seg) {
          match = child;
          break;
        }
      }
      if (match == null) {
        final String segLower = seg.toLowerCase();
        for (final String child in children) {
          if (p.basename(child).toLowerCase() == segLower) {
            match = child;
            break;
          }
        }
      }
      if (match == null) {
        resolvedAll = false;
        break;
      }
      current = match;
    }
    if (resolvedAll) return current;
  }
  return null;
}

/// Resolve a book cover to its on-disk **file path** (not a `file://` URL),
/// reusing the exact same case-insensitive resolution the library grid uses
/// (`_resolveCoverUrl`) so card mining and shelf display agree on which cover
/// file to use (TODO-1388 / BUG-703). The declared [coverPath] wins over the
/// conventional `cover.jpg/jpeg/png` fallbacks; each candidate is matched
/// exact-case-first then case-insensitively against the real extracted files,
/// so a coverPath whose case was mangled by a case-insensitive import host
/// (Windows/macOS `p.canonicalize` lower-casing, epub_parser _itemRelHref)
/// still finds the case-preserved file on a case-sensitive device
/// (Android/Linux). Returns null when no candidate resolves to a real file.
///
/// Static + wiring the real [_listDirEntries] lister so mining (which only
/// had a naive `File(join(extractDir, coverHref)).existsSync()` probe --
/// blind to case, hence the missing cover on Android) shares one resolution
/// with the grid instead of drifting.
///
/// Not `@visibleForTesting`: this is genuine production API consumed by both
/// the shelf grid (`_resolveCoverUrl`) and card mining (`mining.part.dart`).
String? resolveBookCoverFilePath({
  required String extractDir,
  String? coverPath,
}) {
  final String? resolved = resolveBookCoverCaseInsensitive(
    extractDir: extractDir,
    relPaths: <String>[
      if (coverPath != null && coverPath.isNotEmpty) coverPath,
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
    ],
    listDir: _listDirEntries,
  );
  if (resolved != null && File(resolved).existsSync()) return resolved;
  return null;
}
