/// 「等你决定的笔记」（字段并发修改）的两种整批处理：
///
/// 1. **媒体引用的伪冲突自动消解**（[srsReconcileMediaRefConflicts]，BUG-5551，反馈 mvf7Wfz8Q-）。同一份 Anki 数据
///    在两台设备上各导入一次：笔记 ID 由 Anki 来源决定、两边相同；导入时字段里的媒体引用只有读到了文件才改写成
///    内容寻址名（`SrsMediaStore.contentName`，sha1 + 扩展名），读不到就保留原名（srs_apkg_import.dart
///    `_storeMedia`）。一台读到了、一台没读到，同一条笔记的同一个字段就成了 `[sound:<sha1>.mp3]` 与
///    `[sound:原名.mp3]` 两个并发值——不是谁改过内容，是一边的引用指向一个本机根本没有的文件。
///
///    判据（[srsMediaRefsSubsume]）：两个值除了媒体引用的文件名之外一字不差，每处不同的引用都是
///    「原名、本机没有这个文件」对「这个原名存进来后应有的内容寻址名、本机有这个文件」，同一原名只对应一个
///    内容寻址名。这时有文件的那一边严格包含另一边的全部信息，按它写一条新记录（因果上覆盖两边），冲突消失。
///    两台设备各自消解时写下的是同一个值，合并后不再冲突。真改过内容的（文字不同、或两边都是内容寻址名但
///    不是同一个文件）一律不动，留给用户。
///
/// 2. **整批采用某一台设备的版本**（[srsAdoptNoteConflictSide]）：冲突中心「批量处理」的一项，用户点名一台
///    设备，每条待裁决笔记的每个冲突字段都取那台设备写的值（那台设备在这个字段上没有候选的保持原样）。
library;

import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';

/// 每批读 / 写的笔记数：一批一次物化、一次批量写（一个事务）。
const int kSrsNoteConflictBatch = 500;

/// [resolved] 是不是把 [dangling] 里断掉的媒体引用接上之后的同一个值（判据见文件头）。[exists] = 本机媒体目录里
/// 有没有这个文件名。
bool srsMediaRefsSubsume({
  required String resolved,
  required String dangling,
  required bool Function(String name) exists,
}) {
  if (resolved == dangling) return false;
  final ({String skeleton, List<String> refs}) r = srsMediaRefSkeleton(
    resolved,
  );
  final ({String skeleton, List<String> refs}) d = srsMediaRefSkeleton(
    dangling,
  );
  if (r.skeleton != d.skeleton || r.refs.length != d.refs.length) return false;
  final Map<String, String> mapped = <String, String>{};
  bool differs = false;
  for (int i = 0; i < d.refs.length; i++) {
    final String from = d.refs[i];
    final String to = r.refs[i];
    if (from == to) continue;
    differs = true;
    final String? seen = mapped[from];
    if (seen != null) {
      if (seen != to) return false;
      continue;
    }
    // 两边都是内容寻址名 = 两个不同的文件（不是同一份媒体的两种写法），哪怕一边此刻还没同步下来。
    if (SrsMediaStore.isContentName(from)) return false;
    if (!SrsMediaStore.isContentNameFor(to, from)) return false;
    if (exists(from) || !exists(to)) return false;
    mapped[from] = to;
  }
  return differs;
}

/// 一个冲突寄存器的候选值里，能消解掉其余全部候选的那个值；没有就是 null。
String? srsMediaRefResolution(
  List<Object?> candidates, {
  required bool Function(String name) exists,
}) {
  final List<String> distinct = <String>[];
  for (final Object? v in candidates) {
    if (v is! String) return null;
    if (!distinct.contains(v)) distinct.add(v);
  }
  if (distinct.length < 2) return null;
  for (final String w in distinct) {
    if (distinct.every(
      (String v) =>
          v == w ||
          srsMediaRefsSubsume(resolved: w, dangling: v, exists: exists),
    )) {
      return w;
    }
  }
  return null;
}

/// 笔记上要处理的冲突寄存器：内容冲突（删除另有冲突中心的「扣住的删除」处理，不在这里）。
Iterable<SrsRegister> _conflictedFields(SrsNoteView note) => note
    .edits
    .conflicted
    .where((SrsRegister r) => r.key != SrsFieldKeys.deleted);

/// 本机媒体目录里有没有这些文件（逐个异步 stat，结果记进 [cache]）。
Future<void> _probeMedia(
  SrsMediaStore media,
  Iterable<String> names,
  Map<String, bool> cache,
) async {
  final List<String> todo = <String>[
    for (final String n in names.toSet())
      if (!cache.containsKey(n)) n,
  ];
  for (int at = 0; at < todo.length; at += 64) {
    final List<String> part = todo.sublist(
      at,
      at + 64 > todo.length ? todo.length : at + 64,
    );
    final List<bool> found = await Future.wait(<Future<bool>>[
      for (final String n in part)
        media.resolve(n)?.exists() ?? Future<bool>.value(false),
    ]);
    for (int i = 0; i < part.length; i++) {
      cache[part[i]] = found[i];
    }
  }
}

/// 消解全部待裁决笔记里媒体引用的伪冲突（见文件头），返回写下的字段数。真冲突不动。
Future<int> srsReconcileMediaRefConflicts(
  SrsDbStore store,
  SrsMediaStore media,
) async {
  final List<SrsNoteCacheRow> pending = await store.notesPendingDecision();
  if (pending.isEmpty) return 0;
  final Map<String, bool> exists = <String, bool>{};
  int written = 0;
  for (int at = 0; at < pending.length; at += kSrsNoteConflictBatch) {
    final int end = at + kSrsNoteConflictBatch > pending.length
        ? pending.length
        : at + kSrsNoteConflictBatch;
    final Map<String, SrsNoteView?> notes = await store.notes(<String>[
      for (int i = at; i < end; i++) pending[i].id,
    ]);
    final List<(String, SrsRegister)> regs = <(String, SrsRegister)>[
      for (final SrsNoteView? n in notes.values)
        if (n != null)
          for (final SrsRegister r in _conflictedFields(n)) (n.id, r),
    ];
    await _probeMedia(media, <String>[
      for (final (String _, SrsRegister r) in regs)
        for (final SrsFieldEdit e in r.live)
          if (e.value case final String v) ...srsMediaRefSkeleton(v).refs,
    ], exists);
    final List<SrsFieldChange> changes = <SrsFieldChange>[
      for (final (String id, SrsRegister r) in regs)
        if (srsMediaRefResolution(<Object?>[
              for (final SrsFieldEdit e in r.live) e.value,
            ], exists: (String n) => exists[n] ?? false)
            case final String value)
          SrsFieldChange(SrsEntityKind.note, id, r.key, value),
    ];
    if (changes.isEmpty) continue;
    await store.editFieldsBatch(changes);
    written += changes.length;
  }
  return written;
}

/// 待裁决笔记的冲突字段里出现的写入者（设备）→ 它参与了冲突的笔记数（多到少）。
Future<Map<String, int>> srsNoteConflictWriters(
  SrsDbStore store,
  List<String> noteIds,
) async {
  final Map<String, int> out = <String, int>{};
  for (int at = 0; at < noteIds.length; at += kSrsNoteConflictBatch) {
    final int end = at + kSrsNoteConflictBatch > noteIds.length
        ? noteIds.length
        : at + kSrsNoteConflictBatch;
    final Map<String, SrsNoteView?> notes = await store.notes(
      noteIds.sublist(at, end),
    );
    for (final SrsNoteView? n in notes.values) {
      if (n == null) continue;
      final Set<String> writers = <String>{
        for (final SrsRegister r in _conflictedFields(n))
          for (final SrsFieldEdit e in r.live) e.dot.writerId,
      };
      for (final String w in writers) {
        out[w] = (out[w] ?? 0) + 1;
      }
    }
  }
  final List<MapEntry<String, int>> sorted = out.entries.toList()
    ..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );
  return Map<String, int>.fromEntries(sorted);
}

/// 每条笔记的每个冲突字段都采用 [writerId] 写的值（它在这个字段上有多条候选时取排序最前、即最新的那条）；
/// 它没参与的字段保持原样。返回改动了的笔记数。
Future<int> srsAdoptNoteConflictSide(
  SrsDbStore store,
  List<String> noteIds,
  String writerId,
) async {
  int touched = 0;
  for (int at = 0; at < noteIds.length; at += kSrsNoteConflictBatch) {
    final int end = at + kSrsNoteConflictBatch > noteIds.length
        ? noteIds.length
        : at + kSrsNoteConflictBatch;
    final Map<String, SrsNoteView?> notes = await store.notes(
      noteIds.sublist(at, end),
    );
    final List<SrsFieldChange> changes = <SrsFieldChange>[];
    for (final SrsNoteView? n in notes.values) {
      if (n == null) continue;
      bool any = false;
      for (final SrsRegister r in _conflictedFields(n)) {
        for (final SrsFieldEdit e in r.live) {
          if (e.dot.writerId != writerId) continue;
          changes.add(SrsFieldChange(SrsEntityKind.note, n.id, r.key, e.value));
          any = true;
          break;
        }
      }
      if (any) touched++;
    }
    if (changes.isNotEmpty) await store.editFieldsBatch(changes);
  }
  return touched;
}
