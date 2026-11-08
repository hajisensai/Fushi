/// 本地歌单的身份、播放列表文件（`.m3u` / `.m3u8`）导入与导出。
///
/// 导入的歌单是**独立副本**（用户 2026-11-07 拍板）：导入后在 Fushi 里怎么改都不写回文件，
/// 文件之后的改动也不同步进来。同一个文件只导入一次：歌单 uid 由文件路径派生
/// （[importedMusicPlaylistUid]），已有这个 uid（哪怕被用户删了、软删行还在）就不再导入。
///
/// 条目对曲库：先按路径键精确对（[musicTrackPathKey]），对不上的再按路径尾段对（别的机器
/// 写的列表，音乐库挪过盘符 / 目录）。指向 CUE 整轨文件的条目展开成该文件的全部虚拟
/// 曲目。网络地址不导入。
library;

import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// 新建歌单的 uid（随机，跨设备不撞）。
String newMusicPlaylistUid([Random? random]) {
  final Random r = random ?? Random.secure();
  final StringBuffer b = StringBuffer('pl-');
  for (int i = 0; i < 16; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 从播放列表文件导入的歌单 uid：按文件的路径键派生（同一个文件 = 同一个 uid，换设备
/// 也一样，备份合并不会出两份）。
String importedMusicPlaylistUid(String playlistFilePath, {p.Context? context}) {
  final String key = musicTrackPathKey(playlistFilePath, context: context);
  return 'pl-file-${sha1.convert(key.codeUnits)}';
}

/// 列表文件的显示名：`#PLAYLIST:` 优先，否则文件名（去扩展名）。
String musicPlaylistFileTitle(
  String playlistFilePath,
  MusicPlaylistFile file, {
  p.Context? context,
}) {
  final String? name = file.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  return (context ?? p.context).basenameWithoutExtension(playlistFilePath);
}

/// 条目是不是网络地址（`scheme://`，不含 Windows 盘符）。
bool _isUrl(String entry) {
  final int i = entry.indexOf('://');
  return i >= 2;
}

/// 路径尾段对曲库时最多看几段（`艺人/专辑/文件`）。
const int _kMaxSuffixSegments = 3;

List<String> _segments(String path) => path
    .split(RegExp(r'[\\/]+'))
    .where((String s) => s.isNotEmpty)
    .map((String s) => s.toLowerCase())
    .toList();

/// 把列表条目对成曲库曲目 uid（列表顺序，可重复；对不上的条目丢掉）。[tracks] 是在库
/// 曲目（软删的不要传进来）。
List<String> matchMusicPlaylistEntries(
  List<String> entries,
  List<MusicTrackRow> tracks, {
  p.Context? context,
}) {
  int byCue(MusicTrackRow a, MusicTrackRow b) =>
      (a.cueStartMs ?? 0).compareTo(b.cueStartMs ?? 0);
  final Map<String, List<MusicTrackRow>> byPath =
      <String, List<MusicTrackRow>>{};
  for (final MusicTrackRow t in tracks) {
    byPath
        .putIfAbsent(
          musicTrackPathKey(t.path, context: context),
          () => <MusicTrackRow>[],
        )
        .add(t);
  }
  for (final List<MusicTrackRow> l in byPath.values) {
    l.sort(byCue);
  }

  // 尾段索引（懒建：大多数列表靠精确路径就对齐了）。同一尾段对应多个不同文件时不认
  // （猜错比漏掉更糟）。
  List<Map<String, String?>>? suffixIndex;
  List<Map<String, String?>> buildSuffixIndex() {
    final List<Map<String, String?>> idx = <Map<String, String?>>[
      for (int k = 0; k < _kMaxSuffixSegments; k++) <String, String?>{},
    ];
    for (final String path in byPath.keys) {
      final List<String> segs = _segments(path);
      for (int k = 1; k <= _kMaxSuffixSegments && k <= segs.length; k++) {
        final String key = segs.sublist(segs.length - k).join('/');
        final Map<String, String?> m = idx[k - 1];
        m[key] = m.containsKey(key) && m[key] != path ? null : path;
      }
    }
    return idx;
  }

  List<MusicTrackRow>? bySuffix(String entry) {
    final List<String> segs = _segments(entry);
    final List<Map<String, String?>> idx = suffixIndex ??= buildSuffixIndex();
    for (int k = min(_kMaxSuffixSegments, segs.length); k >= 1; k--) {
      final String key = segs.sublist(segs.length - k).join('/');
      final String? path = idx[k - 1][key];
      if (path != null) return byPath[path];
      if (idx[k - 1].containsKey(key)) return null; // 有歧义：不再退到更短的尾段。
    }
    return null;
  }

  final List<String> out = <String>[];
  for (final String entry in entries) {
    if (_isUrl(entry)) continue;
    final String key = musicTrackPathKey(entry, context: context);
    final List<MusicTrackRow>? hit = byPath[key] ?? bySuffix(entry);
    if (hit == null) continue;
    for (final MusicTrackRow t in hit) {
      out.add(t.trackUid);
    }
  }
  return out;
}

/// 一次导入的结果。
enum MusicPlaylistImportOutcome {
  /// 新建了歌单。
  imported,

  /// 这个文件导入过（歌单还在或被用户删了）：什么都没做。
  alreadyImported,

  /// 一条都没对上曲库：没建歌单（之后曲库扫到对应文件时再试）。
  noMatches,
}

/// 导入一份解析好的列表文件。[libraryTracks] 是在库曲目（一次扫描导入多份列表时由调用方
/// 查一次传进来）；不传则现查。[forceNewCopy] 用于用户手动导入：文件导入过、但那份歌单
/// 已被删掉时，用新 uid 再建一份（自动导入不这么做）。
Future<({MusicPlaylistImportOutcome outcome, String playlistUid, int matched})>
importMusicPlaylistFile(
  FushiDatabase db, {
  required String path,
  required MusicPlaylistFile file,
  required int now,
  List<MusicTrackRow>? libraryTracks,
  bool forceNewCopy = false,
  p.Context? context,
}) async {
  String uid = importedMusicPlaylistUid(path, context: context);
  final MusicPlaylistRow? existing = await db.getMusicPlaylist(uid);
  if (existing != null) {
    if (!forceNewCopy || existing.deletedAt == null) {
      return (
        outcome: MusicPlaylistImportOutcome.alreadyImported,
        playlistUid: uid,
        matched: 0,
      );
    }
    uid = newMusicPlaylistUid();
  }
  final List<String> trackUids = matchMusicPlaylistEntries(
    file.entries,
    libraryTracks ?? await db.listMusicTracks(),
    context: context,
  );
  if (trackUids.isEmpty) {
    return (
      outcome: MusicPlaylistImportOutcome.noMatches,
      playlistUid: uid,
      matched: 0,
    );
  }
  final bool created = await db.createMusicPlaylist(
    playlistUid: uid,
    name: musicPlaylistFileTitle(path, file, context: context),
    trackUids: trackUids,
    now: now,
  );
  return (
    outcome: created
        ? MusicPlaylistImportOutcome.imported
        : MusicPlaylistImportOutcome.alreadyImported,
    playlistUid: uid,
    matched: trackUids.length,
  );
}

/// 远程来源（SFTP / WebDAV / AList）里的列表：Rust 不拼相对路径（远程路径是 `/` 分隔的
/// 不透明串，不能按本机路径规则拼），这里按 URL 风格拼到列表所在目录。
MusicPlaylistFile resolveRemoteMusicPlaylistEntries(
  String playlistPath,
  MusicPlaylistFile file,
) {
  final int slash = playlistPath.lastIndexOf('/');
  final String dir = slash < 0 ? '' : playlistPath.substring(0, slash);
  // `..` 不越过根：`scheme://host` 是 3 段（`scheme:`、空、`host`），普通路径是首段。
  final int floor = dir.contains('://') ? 3 : 1;
  String resolve(String entry) {
    if (_isUrl(entry) || entry.startsWith('/')) return entry;
    final List<String> parts = dir.split('/');
    for (final String seg in entry.replaceAll(r'\', '/').split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.length > floor) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }

  return MusicPlaylistFile(
    name: file.name,
    entries: <String>[for (final String e in file.entries) resolve(e)],
  );
}

/// 导出到 `.m3u8` 的一条。
class MusicPlaylistExportItem {
  const MusicPlaylistExportItem({
    required this.location,
    this.title,
    this.artist,
    this.durationMs,
  });

  /// 文件路径（本地曲库：绝对路径；服务器：服务器报的文件路径）。
  final String location;
  final String? title;
  final String? artist;
  final int? durationMs;
}

/// 生成 `.m3u8` 文本（UTF-8、扩展 M3U）。[relativeTo] 是输出文件所在目录：与它同一个根
/// 的本地路径写成相对路径（整个音乐目录挪走后列表仍可用），其余写绝对路径。
String encodeMusicPlaylistM3u8({
  required String name,
  required List<MusicPlaylistExportItem> items,
  String? relativeTo,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  String location(String path) {
    if (relativeTo == null || _isUrl(path) || !ctx.isAbsolute(path)) {
      return path;
    }
    if (ctx.rootPrefix(path).toLowerCase() !=
        ctx.rootPrefix(relativeTo).toLowerCase()) {
      return path;
    }
    return ctx.relative(path, from: relativeTo);
  }

  String oneLine(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  final StringBuffer b = StringBuffer('#EXTM3U\n');
  if (name.trim().isNotEmpty) b.write('#PLAYLIST:${oneLine(name)}\n');
  for (final MusicPlaylistExportItem it in items) {
    final int secs = it.durationMs == null
        ? -1
        : (it.durationMs! / 1000).round();
    final String label = <String>[
      if (it.artist != null && it.artist!.trim().isNotEmpty)
        oneLine(it.artist!),
      if (it.title != null && it.title!.trim().isNotEmpty) oneLine(it.title!),
    ].join(' - ');
    b
      ..write('#EXTINF:$secs,$label\n')
      ..write('${location(it.location)}\n');
  }
  return b.toString();
}
