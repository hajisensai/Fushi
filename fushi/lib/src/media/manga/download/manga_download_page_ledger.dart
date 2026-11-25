/// 在线漫画章下载的续跑页账本（拍板台 audit-035）。
///
/// 续跑（暂停后恢复、失败重试、进程重启、桌面 sidecar 重启后重解析页表）以前只按
/// 页序认磁盘上已落地的页：源端在两次解析之间同页数换了 / 重排了页，旧版的页会和
/// 新版的页混进同一章，已有页图与之后的 OCR 坐标也对不上。
///
/// 账本记「章目录里每个已落地的页文件是源端哪一页」——页文件名 + 那一页的源端稳定
/// 身份 `OnlineMangaPageRef.pageKey`。续跑时拿新解析的页表逐页对身份
/// （[planMangaDownloadResume]）：身份对得上的文件保留，页表重排了就把文件挪到新
/// 页序上，对不上 / 认不出身份 / 账本里没有的一律删掉重下。于是一章里所有的页都
/// 出自同一份页表，而不必因为一页变了整章重下。
///
/// 账本还记下这些页所属的**整份页表**（每页身份，HBK-AUDIT-206）：身份只在
/// 那份页表里唯一时才能单凭身份认页。Mihon 懒解析的源会给几页报同一个页地址，
/// 只落了其中一页时，单看账本里的那一条看不出它的身份原本是重复的。
///
/// **不变式：账本只列真实成立的（文件名, 身份）对，且每一对都是账本页表里的那一页。**
/// 页先落盘、再进账本；删 / 挪文件前先把它从账本里拿掉。中途被杀最坏是「盘上有
/// 文件、账本里没有」，下次续跑把它当来历不明删掉重下——慢一点，绝不会认错页。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/manga/mihon/manga_page_files.dart'
    show mangaPageFileStem;
import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;

/// 账本文件名，放在章目录里（与 `manga.json` 同级，不进 `images/`）。章下完、
/// `manga.json` 写好后删掉；用户取消时随章目录一起删。
const String kMangaDownloadPageLedgerFileName = '.fushi-download-pages.json';

/// 账本格式版本。读到别的版本按空账本处理（盘上的页全部重下）。
///
/// v2 起多记整份页表 `table`（HBK-AUDIT-206）。v1 账本没有它，判不出身份当时是否
/// 唯一，按空账本处理：升级后那一次续跑整章重下，宁可重下，不认错页。
const int _kLedgerVersion = 2;

/// 账本里的一页：`images/` 下的文件名、它当时的页序、源端身份。
class MangaDownloadLedgerEntry {
  const MangaDownloadLedgerEntry({
    required this.file,
    required this.index,
    required this.key,
  });

  /// `images/` 下的文件名（不带目录，形如 `page-000001.png`）。
  final String file;

  /// 落盘时所在的 0 基页序。
  final int index;

  /// 源端稳定页身份（`OnlineMangaPageRef.pageKey`，非空）。
  final String key;

  Map<String, Object?> toJson() => <String, Object?>{
    'file': file,
    'index': index,
    'key': key,
  };

  static MangaDownloadLedgerEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? file = json['file'];
    final Object? index = json['index'];
    final Object? key = json['key'];
    if (file is! String || index is! int || key is! String) return null;
    // 文件名只许是 `images/` 下的一层名字：账本是盘上数据，不让它把删 / 挪指到
    // 目录外。
    if (file.isEmpty ||
        file != p.basename(file) ||
        file == '.' ||
        file == '..' ||
        file.contains('/') ||
        file.contains(r'\')) {
      return null;
    }
    if (index < 0 || key.isEmpty) return null;
    return MangaDownloadLedgerEntry(file: file, index: index, key: key);
  }

  @override
  bool operator ==(Object other) =>
      other is MangaDownloadLedgerEntry &&
      other.file == file &&
      other.index == index &&
      other.key == key;

  @override
  int get hashCode => Object.hash(file, index, key);

  @override
  String toString() => 'MangaDownloadLedgerEntry($file, $index, $key)';
}

/// 读回来的账本：页表 [table] + 已落地的页 [pages]（每项都是 [table] 里那一页）。
class MangaDownloadLedger {
  const MangaDownloadLedger({required this.table, required this.pages});

  static const MangaDownloadLedger empty = MangaDownloadLedger(
    table: <String?>[],
    pages: <MangaDownloadLedgerEntry>[],
  );

  /// 这些页落盘时所依据的整份页表：第 i 项 = 第 i 页的源端身份，认不出为 null。
  final List<String?> table;

  final List<MangaDownloadLedgerEntry> pages;
}

/// 章目录 [chapterDir] 里的账本文件。
File mangaDownloadPageLedgerFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, kMangaDownloadPageLedgerFileName));

/// 读账本。文件不在、读不了、格式不对、旧版本都按空账本（宁可重下，不认错页）。
Future<MangaDownloadLedger> readMangaDownloadPageLedger(
  Directory chapterDir,
) async {
  final File file = mangaDownloadPageLedgerFile(chapterDir);
  final String source;
  try {
    if (!await file.exists()) return MangaDownloadLedger.empty;
    source = await readAtomicallyWrittenTextFile(file);
  } on FileSystemException {
    return MangaDownloadLedger.empty;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return MangaDownloadLedger.empty;
  }
  if (decoded is! Map || decoded['version'] != _kLedgerVersion) {
    return MangaDownloadLedger.empty;
  }
  final Object? table = decoded['table'];
  final Object? pages = decoded['pages'];
  if (table is! List || pages is! List) return MangaDownloadLedger.empty;
  final List<String?> keys = <String?>[];
  for (final Object? key in table) {
    if (key != null && (key is! String || key.isEmpty)) {
      return MangaDownloadLedger.empty;
    }
    keys.add(key as String?);
  }
  return MangaDownloadLedger(
    table: List<String?>.unmodifiable(keys),
    pages: <MangaDownloadLedgerEntry>[
      for (final Object? page in pages)
        ?MangaDownloadLedgerEntry.fromJson(page),
    ],
  );
}

/// 原子写账本（整份覆盖）：[table] 是 [entries] 所属的整份页表。
Future<void> writeMangaDownloadPageLedger(
  Directory chapterDir, {
  required List<String?> table,
  required Iterable<MangaDownloadLedgerEntry> entries,
}) => writeTextFileAtomically(
  mangaDownloadPageLedgerFile(chapterDir),
  jsonEncode(<String, Object?>{
    'version': _kLedgerVersion,
    'table': table,
    'pages': <Object?>[
      for (final MangaDownloadLedgerEntry entry in entries) entry.toJson(),
    ],
  }),
);

/// 续跑计划：哪些已落地的文件留给新页表的哪一页、要挪的、要删的。
class MangaDownloadResumePlan {
  const MangaDownloadResumePlan({required this.keep, required this.discard});

  /// 新页序 → 留用的账本项。`entry.index == 新页序` 的原地留用，其余要挪过去。
  final Map<int, MangaDownloadLedgerEntry> keep;

  /// 要删的 `images/` 下文件名：身份对不上、认不出、账本里没有（来历不明，含
  /// 半截暂存）的都在这里。
  final Set<String> discard;

  /// 留用但页序变了、要挪文件的项（新页序 → 账本项）。
  Map<int, MangaDownloadLedgerEntry> get moves =>
      <int, MangaDownloadLedgerEntry>{
        for (final MapEntry<int, MangaDownloadLedgerEntry> kept in keep.entries)
          if (kept.value.index != kept.key) kept.key: kept.value,
      };
}

/// 按新页表 [keys]（第 i 项 = 新页表第 i 页的源端身份，认不出为 null）给盘上的
/// 页定去留。
///
/// - [ledger]：读回来的账本；[filesOnDisk]：`images/` 下现有的非空文件名。账本里
///   有、盘上没有的项、与账本页表对不上的项直接忽略；盘上有、账本里没有的文件一律删。
/// - 新页表与账本页表**整份**相同（页数相同、每页身份都在且相等，与
///   `OnlineMangaChapterPageRefs.sameSourcePages` 同一判据）：每页原地留用。
/// - 否则只认「身份在账本页表里唯一、在新页表里也唯一」的页：文件留给新页表里那
///   一页（页序变了就挪）。身份重复的页（有的源给几页报同一个页地址、靠页序取图）
///   在页表变了之后就认不出是哪一页——页序相同也不行（旧 [A,B] 同身份、新表删了
///   A 只剩 B 时，第 0 页的旧文件是 A 不是 B，HBK-AUDIT-206），一律删掉重下。
/// - 新页表里认不出身份（null）的页一个都不复用。
MangaDownloadResumePlan planMangaDownloadResume({
  required List<String?> keys,
  required MangaDownloadLedger ledger,
  required Set<String> filesOnDisk,
}) {
  final List<String?> table = ledger.table;
  final Map<String, int> newCounts = _counts(keys);
  final Map<String, int> oldCounts = _counts(table);
  final Map<String, int> newIndexOf = <String, int>{
    for (int index = 0; index < keys.length; index++)
      if (keys[index] case final String key) key: index,
  };
  final bool sameTable = _sameTable(table, keys);
  final Map<int, MangaDownloadLedgerEntry> keep =
      <int, MangaDownloadLedgerEntry>{};
  final Set<String> seenFiles = <String>{};
  final Set<String> kept = <String>{};
  for (final MangaDownloadLedgerEntry entry in ledger.pages) {
    // 同一个文件在账本里出现两次是坏账本：只认第一条，后面的当没有。
    if (!filesOnDisk.contains(entry.file) || !seenFiles.add(entry.file)) {
      continue;
    }
    // 账本里的页必须真是账本页表里的那一页；对不上是坏账本，不认。
    if (entry.index >= table.length || table[entry.index] != entry.key) {
      continue;
    }
    final int? target = sameTable
        ? entry.index
        : (oldCounts[entry.key] == 1 && newCounts[entry.key] == 1)
        ? newIndexOf[entry.key]
        : null;
    if (target == null || keep.containsKey(target)) continue;
    keep[target] = entry;
    kept.add(entry.file);
  }
  return MangaDownloadResumePlan(
    keep: keep,
    discard: <String>{
      for (final String file in filesOnDisk)
        if (!kept.contains(file)) file,
    },
  );
}

Map<String, int> _counts(List<String?> keys) {
  final Map<String, int> counts = <String, int>{};
  for (final String? key in keys) {
    if (key != null) counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

/// [a] 与 [b] 是否同一份页表：页数相同，逐页身份都非 null 且相等。
bool _sameTable(List<String?> a, List<String?> b) {
  if (a.length != b.length) return false;
  for (int index = 0; index < a.length; index++) {
    final String? key = a[index];
    if (key == null || key != b[index]) return false;
  }
  return true;
}

/// 按新页表 [keys] 收拾章目录 [chapterDir] 里已落地的页（[planMangaDownloadResume]
/// 的计划落到盘上），返回新页序 → 留用的 `images/` 下文件名，以及接着记账的
/// [MangaDownloadPageLedgerWriter]。
///
/// 顺序守住账本不变式：先把账本缩成「原地留用」的那些，再删、再挪（两段改名，
/// 先挪到暂存名再挪到目标名，免得目标名正被另一个待挪的文件占着），最后把挪好的
/// 记回账本。删不掉 / 挪不动就抛（任务按失败退避重试），不带着认不清的文件往下走。
Future<({Map<int, String> kept, MangaDownloadPageLedgerWriter ledger})>
reconcileMangaDownloadPages({
  required Directory chapterDir,
  required Directory images,
  required List<String?> keys,
}) async {
  await images.create(recursive: true);
  final Set<String> allFiles = <String>{};
  final Set<String> nonEmpty = <String>{};
  await for (final FileSystemEntity entity in images.list(followLinks: false)) {
    if (entity is! File) continue;
    final String name = p.basename(entity.path);
    allFiles.add(name);
    if (await entity.length() > 0) nonEmpty.add(name);
  }
  final MangaDownloadResumePlan plan = planMangaDownloadResume(
    keys: keys,
    ledger: await readMangaDownloadPageLedger(chapterDir),
    filesOnDisk: nonEmpty,
  );
  final Map<int, MangaDownloadLedgerEntry> moves = plan.moves;
  final Map<int, MangaDownloadLedgerEntry> staying =
      <int, MangaDownloadLedgerEntry>{
        for (final MapEntry<int, MangaDownloadLedgerEntry> kept
            in plan.keep.entries)
          if (!moves.containsKey(kept.key)) kept.key: kept.value,
      };
  final List<String?> table = List<String?>.unmodifiable(keys);
  // 原地留用的页在新旧两份页表里是同一页，先把账本整份换成新页表 + 它们。
  await writeMangaDownloadPageLedger(
    chapterDir,
    table: table,
    entries: staying.values,
  );
  for (final String name in <String>{
    ...plan.discard,
    ...allFiles.difference(nonEmpty),
  }) {
    final File file = File(p.join(images.path, name));
    if (await file.exists()) await file.delete();
  }
  final Map<int, MangaDownloadLedgerEntry> entries =
      <int, MangaDownloadLedgerEntry>{...staying};
  if (moves.isNotEmpty) {
    final Map<int, File> parked = <int, File>{};
    int sequence = 0;
    for (final MapEntry<int, MangaDownloadLedgerEntry> move in moves.entries) {
      parked[move.key] = await File(
        p.join(images.path, move.value.file),
      ).rename(p.join(images.path, '.resume-${sequence++}.part'));
    }
    for (final MapEntry<int, File> park in parked.entries) {
      final MangaDownloadLedgerEntry from = moves[park.key]!;
      final String name =
          '${mangaPageFileStem(park.key)}${p.extension(from.file)}';
      await park.value.rename(p.join(images.path, name));
      entries[park.key] = MangaDownloadLedgerEntry(
        file: name,
        index: park.key,
        key: from.key,
      );
    }
    await writeMangaDownloadPageLedger(
      chapterDir,
      table: table,
      entries: _ordered(entries),
    );
  }
  return (
    kept: <int, String>{
      for (final MapEntry<int, MangaDownloadLedgerEntry> entry
          in entries.entries)
        entry.key: entry.value.file,
    },
    ledger: MangaDownloadPageLedgerWriter._(chapterDir, table, entries),
  );
}

Iterable<MangaDownloadLedgerEntry> _ordered(
  Map<int, MangaDownloadLedgerEntry> entries,
) {
  final List<int> indices = entries.keys.toList()..sort();
  return <MangaDownloadLedgerEntry>[
    for (final int index in indices) entries[index]!,
  ];
}

/// 下载途中逐页记账：页文件落盘**之后**调 [record]。并发的记账排队整份重写，
/// 账本始终是某一时刻的完整快照。
class MangaDownloadPageLedgerWriter {
  MangaDownloadPageLedgerWriter._(this._chapterDir, this._table, this._entries);

  final Directory _chapterDir;

  /// 本轮取页所依据的页表（记进账本，续跑时判身份是否唯一）。
  final List<String?> _table;
  final Map<int, MangaDownloadLedgerEntry> _entries;
  Future<void> _tail = Future<void>.value();

  /// 记下第 [index] 页落成了 `images/` 下的 [file]，源端身份 [key]。认不出身份
  /// （null）的页不记：下次续跑本来也不会复用它。
  Future<void> record({
    required int index,
    required String file,
    required String? key,
  }) {
    if (key == null) {
      // 同页序以前记过（不同身份）的那条已不再成立。
      if (_entries.remove(index) == null) return Future<void>.value();
    } else {
      _entries[index] = MangaDownloadLedgerEntry(
        file: file,
        index: index,
        key: key,
      );
    }
    final Future<void> write = _tail.then(
      (void _) => writeMangaDownloadPageLedger(
        _chapterDir,
        table: _table,
        entries: _ordered(_entries),
      ),
    );
    // 一次写失败不卡住后面的记账；失败由这次调用方收到。
    _tail = write.catchError((Object _) {});
    return write;
  }

  /// 章下完（`manga.json` 已写）后删掉账本。
  Future<void> discard() async {
    await _tail;
    final File file = mangaDownloadPageLedgerFile(_chapterDir);
    if (await file.exists()) await file.delete();
  }
}
