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

/// [_listDirEntries] 的异步版：书架刷新（`ReaderFushiSource._resolveCoverUrl`）
/// 跑在 UI isolate 上，同步 `listSync` 会把整段目录枚举压在帧里（实测切页时
/// 7 ms+），异步枚举交给 IO 线程，UI 只等结果。语义同上：不存在 / 读不了返回空。
Future<List<String>> _listDirEntriesAsync(String dir) async {
  final Directory d = Directory(dir);
  if (!await d.exists()) return const <String>[];
  try {
    return await d
        .list(followLinks: false)
        .map((FileSystemEntity e) => e.path)
        .toList();
  } on FileSystemException {
    return const <String>[];
  }
}

/// [rel] 拆成逐段待匹配的路径段；空串 / 绝对路径 / 拆完为空时返回 null（跳过）。
List<String>? _relSegments(String rel) {
  if (rel.isEmpty || p.isAbsolute(rel)) return null;
  final List<String> segs = p
      .split(rel)
      .where((String s) => s.isNotEmpty && s != '.' && s != '/')
      .toList();
  return segs.isEmpty ? null : segs;
}

/// 在 [children] 里找名为 [seg] 的子项：先精确大小写，再大小写不敏感。
String? _matchSegment(List<String> children, String seg) {
  for (final String child in children) {
    if (p.basename(child) == seg) return child;
  }
  final String segLower = seg.toLowerCase();
  for (final String child in children) {
    if (p.basename(child).toLowerCase() == segLower) return child;
  }
  return null;
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
    final List<String>? segs = _relSegments(rel);
    if (segs == null) continue;
    String? current = extractDir;
    for (final String seg in segs) {
      final String dir = current!;
      current = _matchSegment(listed.putIfAbsent(dir, () => listDir(dir)), seg);
      if (current == null) break;
    }
    if (current != null) return current;
  }
  return null;
}

/// [resolveBookCoverCaseInsensitive] 的异步版：逐段匹配规则与「一次调用内同一
/// 目录只列一次」完全相同（共用 [_relSegments] / [_matchSegment]），只是目录枚举
/// [listDir] 是异步的，供 UI isolate 上的书架刷新用，不在帧里同步列目录。
Future<String?> resolveBookCoverCaseInsensitiveAsync({
  required String extractDir,
  required List<String> relPaths,
  required Future<List<String>> Function(String dir) listDir,
}) async {
  final Map<String, List<String>> listed = <String, List<String>>{};
  for (final String rel in relPaths) {
    final List<String>? segs = _relSegments(rel);
    if (segs == null) continue;
    String? current = extractDir;
    for (final String seg in segs) {
      final String dir = current!;
      final List<String> children =
          listed[dir] ?? (listed[dir] = await listDir(dir));
      current = _matchSegment(children, seg);
      if (current == null) break;
    }
    if (current != null) return current;
  }
  return null;
}

/// [resolveBookCoverFilePath] 的候选顺序：声明封面优先，再 `cover.jpg/jpeg/png`。
List<String> _bookCoverRelCandidates(String? coverPath) => <String>[
  if (coverPath != null && coverPath.isNotEmpty) coverPath,
  'cover.jpg',
  'cover.jpeg',
  'cover.png',
];

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
    relPaths: _bookCoverRelCandidates(coverPath),
    listDir: _listDirEntries,
  );
  if (resolved != null && File(resolved).existsSync()) return resolved;
  return null;
}

/// [resolveBookCoverFilePath] 的异步版，结果与同步版逐字一致（同一候选顺序、
/// 同一逐段解析、同样只认真实文件）。UI isolate 上的调用方（书架
/// `ReaderFushiSource._resolveCoverUrl`，本就在 async 加载里）用它：目录枚举与
/// 存在性探测都走异步 IO，不阻塞帧。
Future<String?> resolveBookCoverFilePathAsync({
  required String extractDir,
  String? coverPath,
}) async {
  final String? resolved = await resolveBookCoverCaseInsensitiveAsync(
    extractDir: extractDir,
    relPaths: _bookCoverRelCandidates(coverPath),
    listDir: _listDirEntriesAsync,
  );
  if (resolved != null && await File(resolved).exists()) return resolved;
  return null;
}

/// 阅读器里「这本书的封面文件」（BUG-5045）：制卡 `{book-cover}`、迷你播放条、
/// 歌词页、快捷设置、TTS 通知、伴屏共用这一处，与书架字幕书 / 有声书卡
/// （`reader_history/books.part.dart` 的 `_buildSrtCover`）同序：
///
/// 1. 配对 `srt_books.cover_path`（[pairedSrtCoverPath]）——字幕 + 音频导入的书
///    （乐曲、独立字幕书）封面只落在这里：导入时选的图或从音频抽出的内嵌封面，
///    正文是字幕行生成的 EPUB，OPF 里根本没有 cover-image；
/// 2. 正文 EPUB 的封面（[extractDir] + [coverHref]，大小写不敏感，见
///    [resolveBookCoverFilePath]）。
///
/// 只认真实存在的文件；都没有返回 null。
String? resolveReaderBookCoverFilePath({
  String? pairedSrtCoverPath,
  String? extractDir,
  String? coverHref,
}) {
  final String? own = pairedSrtCoverPath;
  if (own != null && own.isNotEmpty && File(own).existsSync()) return own;
  if (extractDir == null) return null;
  return resolveBookCoverFilePath(extractDir: extractDir, coverPath: coverHref);
}
