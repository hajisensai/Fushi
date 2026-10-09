/// library 域控制通道的纯函数层：条目键、种类、进度文案、`--at` 解析、筛选与
/// 最近打开流合并。不碰数据库与 UI，路由层（`ctl_library_routes.dart`）把各仓库
/// 读出的行换成 [LibraryCtlEntry] 后交给这里。
library;

import 'package:fushi_core/fushi_core.dart' show BookFormat;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/models/module_id.dart';

/// CLI 面向用户的条目种类（`--kind` 的值域）。
///
/// 与库内各域枚举（`MediaKind` / `BookFormat` / `SourceLibraryKind`）互不通用：
/// 它只服务于命令行的筛选与展示，落库一律走各域自己的枚举。
enum LibraryCtlKind {
  /// EPUB / 文本转 EPUB 的书（`EpubBooks.format = epub`，且没有配对字幕书）。
  book,

  /// PDF 书（`EpubBooks.format = pdf`）。
  pdf,

  /// 漫画（`EpubBooks.format = manga`，含在线漫画条目）。
  manga,

  /// 有声书 / 字幕书（`SrtBooks` 行；EPUB 配对的有声书在书架上也只以它出现）。
  audiobook,

  /// 视频（`VideoBooks` 行）。
  video,

  /// galgame（`galgames` 行）。
  game;

  /// 线上名（`--kind` 的值）。
  String get wireName => name;

  /// 可见性由哪个模块开关决定。书 / PDF / 有声书都在书架上，归 [ModuleId.books]。
  ModuleId get module => switch (this) {
    LibraryCtlKind.book ||
    LibraryCtlKind.pdf ||
    LibraryCtlKind.audiobook => ModuleId.books,
    LibraryCtlKind.manga => ModuleId.manga,
    LibraryCtlKind.video => ModuleId.video,
    LibraryCtlKind.game => ModuleId.games,
  };

  /// 严格解析；空串 / null 返回 null，未知值也返回 null（由调用方报 400）。
  static LibraryCtlKind? tryParse(String? raw) {
    final String text = (raw ?? '').trim().toLowerCase();
    for (final LibraryCtlKind kind in values) {
      if (kind.wireName == text) return kind;
    }
    return null;
  }

  /// `EpubBooks.format` → CLI 种类。
  static LibraryCtlKind forBookFormat(BookFormat format) => switch (format) {
    BookFormat.epub => LibraryCtlKind.book,
    BookFormat.pdf => LibraryCtlKind.pdf,
    BookFormat.manga => LibraryCtlKind.manga,
  };
}

/// 条目所在的存储（决定键前缀与读写走哪个仓库）。
enum LibraryCtlStore {
  /// `EpubBooks` 行，id = bookKey（书 / PDF / 漫画）。
  book('book'),

  /// `SrtBooks` 行，id = uid（有声书 / 字幕书）。
  srt('srt'),

  /// `VideoBooks` 行，id = bookUid。
  video('video'),

  /// `galgames` 行，id = 游戏 id。
  game('game');

  const LibraryCtlStore(this.prefix);

  final String prefix;
}

/// 条目键：`<store>:<id>`，如 `book:猫の本`、`video:video/ext/1a2b…`。
///
/// id 原样保留（bookKey / bookUid 可能含 `/`、`%`），CLI 拼路径时整体
/// `Uri.encodeComponent`，服务端按段解码，往返无损。
class LibraryCtlKey {
  const LibraryCtlKey(this.store, this.id);

  final LibraryCtlStore store;
  final String id;

  String get wire => '${store.prefix}:$id';

  /// 解析 `<store>:<id>`；前缀未知或 id 为空返回 null。
  static LibraryCtlKey? tryParse(String raw) {
    final int colon = raw.indexOf(':');
    if (colon <= 0) return null;
    final String prefix = raw.substring(0, colon);
    final String id = raw.substring(colon + 1);
    if (id.isEmpty) return null;
    for (final LibraryCtlStore store in LibraryCtlStore.values) {
      if (store.prefix == prefix) return LibraryCtlKey(store, id);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryCtlKey && other.store == store && other.id == id;

  @override
  int get hashCode => Object.hash(store, id);

  @override
  String toString() => wire;
}

/// 列表里的一条（`library ls` / `library history` 共用的形状）。
class LibraryCtlEntry {
  const LibraryCtlEntry({
    required this.key,
    required this.kind,
    required this.title,
    this.rawTitle,
    this.author,
    this.percent,
    this.positionMs,
    this.playSeconds,
    this.completed = false,
    this.importedAt,
    this.recentAt,
  });

  final LibraryCtlKey key;
  final LibraryCtlKind kind;

  /// 展示标题（含用户改名覆盖）。
  final String title;

  /// 库里的原始标题（与 [title] 不同时才有值，搜索两个都认）。
  final String? rawTitle;
  final String? author;

  /// 书类进度百分比（0–100）。
  final int? percent;

  /// 视频断点（毫秒）。
  final int? positionMs;

  /// 游戏累计游玩秒数。
  final int? playSeconds;
  final bool completed;

  /// 导入时刻（毫秒）。
  final int? importedAt;

  /// 最近一次打开 / 播放 / 游玩的时刻（毫秒）；从未打开为 null。
  final int? recentAt;

  /// 全部可搜标题。
  Iterable<String> get searchTitles => <String>[
    title,
    if (rawTitle != null && rawTitle != title) rawTitle!,
    if (author != null) author!,
  ];

  LibraryCtlEntry withRecentAt(int? value) => LibraryCtlEntry(
    key: key,
    kind: kind,
    title: title,
    rawTitle: rawTitle,
    author: author,
    percent: percent,
    positionMs: positionMs,
    playSeconds: playSeconds,
    completed: completed,
    importedAt: importedAt,
    recentAt: value,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key.wire,
    'kind': kind.wireName,
    'title': title,
    if (rawTitle != null && rawTitle != title) 'rawTitle': rawTitle,
    if (author != null && author!.isNotEmpty) 'author': author,
    if (percent != null) 'percent': percent,
    if (positionMs != null) 'positionMs': positionMs,
    if (playSeconds != null) 'playSeconds': playSeconds,
    'completed': completed,
    'progress': libraryCtlProgressLabel(this),
    if (importedAt != null) 'importedAt': importedAt,
    if (recentAt != null) 'recentAt': recentAt,
  };
}

/// 表格里的「进度」列：书 `37%`、视频 `12:34`、游戏 `3.5h`，读完 / 看完一律 `完成`。
String libraryCtlProgressLabel(LibraryCtlEntry entry) {
  if (entry.completed) return '完成';
  final int? percent = entry.percent;
  if (percent != null) return '$percent%';
  final int? positionMs = entry.positionMs;
  if (positionMs != null) {
    return positionMs > 0 ? formatCtlTimestamp(positionMs) : '';
  }
  final int? seconds = entry.playSeconds;
  if (seconds != null && seconds > 0) {
    return '${(seconds / 3600).toStringAsFixed(1)}h';
  }
  return '';
}

/// 书类进度两数 → 百分比（与书架 / 首页同口径：position ÷ duration，夹到 0–100）。
int libraryCtlPercent({required int position, required int duration}) {
  if (duration <= 0) return 0;
  return ((position / duration) * 100).clamp(0, 100).round();
}

/// 毫秒 → `m:ss` / `h:mm:ss`。
String formatCtlTimestamp(int ms) {
  final int totalSeconds = ms ~/ 1000;
  final int h = totalSeconds ~/ 3600;
  final int m = (totalSeconds % 3600) ~/ 60;
  final int s = totalSeconds % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// `--at` 的视频时间点：`90` / `90.5`（秒）、`1:30`、`1:02:03`。非法返回 null。
int? parseCtlTimestampMs(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return null;
  final List<String> parts = text.split(':');
  if (parts.length > 3) return null;
  double seconds = 0;
  for (int i = 0; i < parts.length; i++) {
    final String part = parts[i].trim();
    final bool last = i == parts.length - 1;
    // 只有最后一段允许小数；前面的时 / 分段必须是整数。
    final num? value = last ? double.tryParse(part) : int.tryParse(part);
    if (value == null || value < 0) return null;
    // 非首段的分 / 秒不得 ≥ 60（`1:75` 多半是笔误，不静默进位）。
    if (i > 0 && value >= 60) return null;
    seconds = seconds * 60 + value;
  }
  return (seconds * 1000).round();
}

/// `--at` 的书章号：1 起计的章序号 → 0 起计的 sectionIndex。非法返回 null。
int? parseCtlChapterIndex(String raw) {
  final int? chapter = int.tryParse(raw.trim());
  if (chapter == null || chapter < 1) return null;
  return chapter - 1;
}

/// 按种类与搜索词筛选（搜索走 [filterByMediaSearch]，与库页同一归一化口径）。
List<LibraryCtlEntry> filterLibraryCtlEntries(
  List<LibraryCtlEntry> entries, {
  Set<LibraryCtlKind>? kinds,
  String? search,
}) {
  final List<LibraryCtlEntry> byKind = kinds == null
      ? entries
      : entries
            .where((LibraryCtlEntry e) => kinds.contains(e.kind))
            .toList(growable: false);
  return filterByMediaSearch<LibraryCtlEntry>(
    byKind,
    search ?? '',
    (LibraryCtlEntry e) => e.searchTitles,
  );
}

/// 最近打开流：只留打开过的（[LibraryCtlEntry.recentAt] 非空且 > 0），同键只留
/// 最近一条，按时刻倒序取前 [limit] 条。
List<LibraryCtlEntry> mergeLibraryCtlHistory(
  Iterable<LibraryCtlEntry> entries, {
  required int limit,
}) {
  final Map<LibraryCtlKey, LibraryCtlEntry> latest =
      <LibraryCtlKey, LibraryCtlEntry>{};
  for (final LibraryCtlEntry entry in entries) {
    final int at = entry.recentAt ?? 0;
    if (at <= 0) continue;
    final LibraryCtlEntry? seen = latest[entry.key];
    if (seen == null || (seen.recentAt ?? 0) < at) latest[entry.key] = entry;
  }
  final List<LibraryCtlEntry> sorted = latest.values.toList()
    ..sort(
      (LibraryCtlEntry a, LibraryCtlEntry b) =>
          (b.recentAt ?? 0).compareTo(a.recentAt ?? 0),
    );
  return sorted.take(limit < 0 ? 0 : limit).toList(growable: false);
}

/// `library import` 单个路径的结局。
enum LibraryCtlImportStatus {
  /// 新入库。
  imported,

  /// 同名条目已在库，按 `--duplicate skip` 跳过。
  skipped,

  /// 目录登记成来源库并扫描（视频 / 书目录）。
  sourceAdded,

  /// 同一目录已是来源库，未做任何写入。
  sourceExists,

  /// 本命令导不了这种东西（附带原因与替代办法）。
  unsupported,

  /// 导入过程中出错。
  failed;

  String get wireName => switch (this) {
    LibraryCtlImportStatus.imported => 'imported',
    LibraryCtlImportStatus.skipped => 'skipped',
    LibraryCtlImportStatus.sourceAdded => 'source_added',
    LibraryCtlImportStatus.sourceExists => 'source_exists',
    LibraryCtlImportStatus.unsupported => 'unsupported',
    LibraryCtlImportStatus.failed => 'failed',
  };

  /// 算不算「这一条没办成」（决定整体 `ok`）。
  bool get isFailure =>
      this == LibraryCtlImportStatus.unsupported ||
      this == LibraryCtlImportStatus.failed;
}

/// 一个路径的导入结果。
class LibraryCtlImportResult {
  const LibraryCtlImportResult({
    required this.path,
    required this.status,
    this.kind,
    this.keys = const <String>[],
    this.message,
  });

  final String path;
  final LibraryCtlImportStatus status;
  final LibraryCtlKind? kind;

  /// 新入库条目的键（批量目录可能多条）。
  final List<String> keys;
  final String? message;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'status': status.wireName,
    if (kind != null) 'kind': kind!.wireName,
    if (keys.isNotEmpty) 'keys': keys,
    if (message != null) 'message': message,
  };
}
