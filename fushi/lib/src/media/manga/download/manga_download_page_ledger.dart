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
/// **不变式：账本只列真实成立的（文件名, 身份）对。** 页先落盘、再进账本；删 / 挪
/// 文件前先把它从账本里拿掉。中途被杀最坏是「盘上有文件、账本里没有」，下次续跑
/// 把它当来历不明删掉重下——慢一点，绝不会认错页。
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
const int _kLedgerVersion = 1;

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

/// 章目录 [chapterDir] 里的账本文件。
File mangaDownloadPageLedgerFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, kMangaDownloadPageLedgerFileName));

/// 读账本。文件不在、读不了、格式不对都按空账本（宁可重下，不认错页）。
Future<List<MangaDownloadLedgerEntry>> readMangaDownloadPageLedger(
  Directory chapterDir,
) async {
  final File file = mangaDownloadPageLedgerFile(chapterDir);
  final String source;
  try {
    if (!await file.exists()) return const <MangaDownloadLedgerEntry>[];
    source = await readAtomicallyWrittenTextFile(file);
  } on FileSystemException {
    return const <MangaDownloadLedgerEntry>[];
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return const <MangaDownloadLedgerEntry>[];
  }
  if (decoded is! Map || decoded['version'] != _kLedgerVersion) {
    return const <MangaDownloadLedgerEntry>[];
  }
  final Object? pages = decoded['pages'];
  if (pages is! List) return const <MangaDownloadLedgerEntry>[];
  return <MangaDownloadLedgerEntry>[
    for (final Object? page in pages) ?MangaDownloadLedgerEntry.fromJson(page),
  ];
}

/// 原子写账本（整份覆盖）。
Future<void> writeMangaDownloadPageLedger(
  Directory chapterDir,
  Iterable<MangaDownloadLedgerEntry> entries,
) => writeTextFileAtomically(
  mangaDownloadPageLedgerFile(chapterDir),
  jsonEncode(<String, Object?>{
    'version': _kLedgerVersion,
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
///   有、盘上没有的项直接忽略；盘上有、账本里没有的文件一律删。
/// - 一个身份在新页表里只出现一次、在账本里也只出现一次，它就认得出是哪一页：
///   文件留给新页表里那一页（页序变了就挪）。
/// - 身份在新页表或账本里重复（有的源给每页报同一个页地址、靠页序取图），身份
///   就不足以认页：只有页序和身份都对得上才原地留用。
/// - 新页表里认不出身份（null）的页一个都不复用。
MangaDownloadResumePlan planMangaDownloadResume({
  required List<String?> keys,
  required List<MangaDownloadLedgerEntry> ledger,
  required Set<String> filesOnDisk,
}) {
  final Map<String, int> newCounts = <String, int>{};
  final Map<String, int> newIndexOf = <String, int>{};
  for (int index = 0; index < keys.length; index++) {
    final String? key = keys[index];
    if (key == null) continue;
    newCounts[key] = (newCounts[key] ?? 0) + 1;
    newIndexOf[key] = index;
  }
  final List<MangaDownloadLedgerEntry> present = <MangaDownloadLedgerEntry>[];
  final Set<String> seenFiles = <String>{};
  for (final MangaDownloadLedgerEntry entry in ledger) {
    // 同一个文件在账本里出现两次是坏账本：只认第一条，后面的当没有。
    if (!filesOnDisk.contains(entry.file) || !seenFiles.add(entry.file)) {
      continue;
    }
    present.add(entry);
  }
  final Map<String, int> ledgerCounts = <String, int>{};
  for (final MangaDownloadLedgerEntry entry in present) {
    ledgerCounts[entry.key] = (ledgerCounts[entry.key] ?? 0) + 1;
  }
  final Map<int, MangaDownloadLedgerEntry> keep =
      <int, MangaDownloadLedgerEntry>{};
  final Set<String> kept = <String>{};
  for (final MangaDownloadLedgerEntry entry in present) {
    int? target;
    if (newCounts[entry.key] == 1 && ledgerCounts[entry.key] == 1) {
      target = newIndexOf[entry.key];
    } else if (entry.index < keys.length && keys[entry.index] == entry.key) {
      target = entry.index;
    }
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
  await writeMangaDownloadPageLedger(chapterDir, staying.values);
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
    await writeMangaDownloadPageLedger(chapterDir, _ordered(entries));
  }
  return (
    kept: <int, String>{
      for (final MapEntry<int, MangaDownloadLedgerEntry> entry
          in entries.entries)
        entry.key: entry.value.file,
    },
    ledger: MangaDownloadPageLedgerWriter._(chapterDir, entries),
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
  MangaDownloadPageLedgerWriter._(this._chapterDir, this._entries);

  final Directory _chapterDir;
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
      (void _) => writeMangaDownloadPageLedger(_chapterDir, _ordered(_entries)),
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
