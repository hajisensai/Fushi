/// 导出 Anki 旧格式 .apkg（collection.anki21 + JSON 媒体清单，Anki 全版本都能导入），
/// 外加未压缩 JSON 条目 `fushi-ext`（完整 Fushi 日志、牌组设置、笔记出处），回导时无损恢复。
///
/// 身份：笔记类型 id = ankiNum，字段 / 模板 id = 各自 ankiNum（没有就不写，回导走按名字回退，ID 不变），
/// guid 原样，笔记 / 卡片 / 牌组数字 id = SrsIds.ankiNumericId。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi_engine/srs/apkg/srs_anki_package.dart'
    show srsFushiExtEntry;
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';

/// 导出范围内的媒体文件读取（没有返回 null，不进包）。
typedef SrsMediaLoad = Future<Uint8List?> Function(String name);

/// 导出时导出的日志种类（导入锚点 / 移交是 Fushi 内部事件，只进 fushi-ext）。
const Set<String> _revlogKinds = <String>{
  SrsLogKind.review,
  SrsLogKind.manual,
  SrsLogKind.reschedule,
};

const String _schema11 = '''
CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL,
  scm integer NOT NULL, ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL,
  ls integer NOT NULL, conf text NOT NULL, models text NOT NULL, decks text NOT NULL,
  dconf text NOT NULL, tags text NOT NULL);
CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL,
  mod integer NOT NULL, usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL,
  sfld integer NOT NULL, csum integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL,
  ord integer NOT NULL, mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL,
  queue integer NOT NULL, due integer NOT NULL, ivl integer NOT NULL, factor integer NOT NULL,
  reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL, odue integer NOT NULL,
  odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL,
  ease integer NOT NULL, ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL,
  time integer NOT NULL, type integer NOT NULL);
CREATE TABLE graves (usn integer NOT NULL, oid integer NOT NULL, type integer NOT NULL);
CREATE INDEX ix_notes_usn ON notes (usn);
CREATE INDEX ix_cards_usn ON cards (usn);
CREATE INDEX ix_revlog_usn ON revlog (usn);
CREATE INDEX ix_cards_nid ON cards (nid);
CREATE INDEX ix_cards_sched ON cards (did, queue, due);
CREATE INDEX ix_revlog_cid ON revlog (cid);
CREATE INDEX ix_notes_csum ON notes (csum);
''';

/// 导出 [deckId] 子树（null = 全部）里的笔记为 .apkg 字节。
///
/// 一条笔记只要有一张卡在范围内就整条导出（含它在范围外的卡，Anki 的笔记不能拆）。
/// [options] 决定带不带学习进度 / 牌组预设、附不附带 fushi-ext（见 [SrsAnkiExportOptions]）。
///
/// 内部先流式写进临时文件（见 [exportAnkiPackageFile]），最后读回一份；能直接给文件的调用方
/// 用 [exportAnkiPackageFile]，整包一份也不进内存。
Future<Uint8List> exportAnkiPackage({
  required SrsDbStore store,
  String? deckId,
  SrsMediaLoad? loadMedia,
  SrsAnkiExportOptions options = const SrsAnkiExportOptions(),
}) async {
  final Directory tmp = await Directory.systemTemp.createTemp('fushi_apkg_');
  try {
    final File out = File('${tmp.path}${Platform.pathSeparator}out.apkg');
    await exportAnkiPackageFile(
      store: store,
      file: out,
      deckId: deckId,
      loadMedia: loadMedia,
      options: options,
    );
    return await out.readAsBytes();
  } finally {
    await _deleteQuietly(tmp);
  }
}

/// 同 [exportAnkiPackage]，写到文件：zip 条目边生成边写盘——集合 SQLite 从临时文件分块原生
/// deflate、媒体一个读一个写、fushi-ext 的日志边遍历边写临时文件，整包从不整份放进内存（以前
/// 全部条目先进 [Archive]，`ZipEncoder.encode` 出整包，再 `Uint8List.fromList` 复制一份才落盘）。
///
/// 先写 `<file>.part`，成功后改名：失败不留半截包、也不覆盖已有的同名文件。
Future<void> exportAnkiPackageFile({
  required SrsDbStore store,
  required File file,
  String? deckId,
  SrsMediaLoad? loadMedia,
  SrsAnkiExportOptions options = const SrsAnkiExportOptions(),
}) async {
  final File part = File('${file.path}.part');
  try {
    await _Exporter(
      store,
      options,
    ).run(part, deckId: deckId, loadMedia: loadMedia);
    await part.rename(file.path);
  } on Object {
    if (part.existsSync()) await _deleteQuietly(part);
    rethrow;
  }
}

Future<void> _deleteQuietly(FileSystemEntity e) async {
  try {
    await e.delete(recursive: true);
  } on FileSystemException {
    // 句柄晚释放：留给系统清理临时目录。
  }
}

/// fushi-ext 的 JSON 边生成边写进 [path]：`logs` 数组逐条追加，攒满一块才落盘（导出时日志
/// 是全部条目里最大的一份，不再整份放进内存再 `jsonEncode`）。字节与
/// `jsonEncode(<format, version, profileUid, logs, …>)` 相同。
class _ExtWriter {
  _ExtWriter(String path, Map<String, Object?> head)
    : _raf = File(path).openSync(mode: FileMode.write) {
    final String h = jsonEncode(head);
    _buf
      ..write(h.substring(0, h.length - 1))
      ..write(',"logs":[');
  }

  static const int _flushChars = 1 << 20;

  final RandomAccessFile _raf;
  final StringBuffer _buf = StringBuffer();
  bool _firstLog = true;

  void addLog(Map<String, Object?> log) {
    if (!_firstLog) _buf.write(',');
    _firstLog = false;
    _buf.write(jsonEncode(log));
    if (_buf.length >= _flushChars) _flush();
  }

  /// 收尾：`logs` 之后的键按 [tail] 的顺序写完、关文件。
  void finish(Map<String, Object?> tail) {
    _buf.write(']');
    for (final MapEntry<String, Object?> e in tail.entries) {
      _buf
        ..write(',')
        ..write(jsonEncode(e.key))
        ..write(':')
        ..write(jsonEncode(e.value));
    }
    _buf.write('}');
    _flush();
    _raf.closeSync();
  }

  void abort() {
    try {
      _raf.closeSync();
    } on FileSystemException {
      // 已关。
    }
  }

  void _flush() {
    _raf.writeFromSync(utf8.encode(_buf.toString()));
    _buf.clear();
  }
}

class _ExportCard {
  _ExportCard(this.row, this.history);

  final SrsCardCacheRow row;
  final SrsCardHistory history;
}

class _Exporter {
  _Exporter(this.store, this.options);

  final SrsDbStore store;
  final SrsAnkiExportOptions options;

  int _ankiDeckId(String id) =>
      id == store.defaultDeckId ? 1 : SrsIds.ankiNumericId(id);

  Future<void> run(File out, {String? deckId, SrsMediaLoad? loadMedia}) async {
    final SrsDeckTree tree = await store.deckTree();
    final SrsDayContext day = await store.dayContext();
    final (int nowMs, _) = store.now();
    final int today = day.dayIndexOf(nowMs);
    final Set<String>? scope = deckId == null
        ? null
        : tree.subtree(deckId).toSet();

    // 范围内的笔记。
    final List<SrsCardCacheRow> all =
        await (store.db.select(store.db.srsCardsCache)..where(
              ($SrsCardsCacheTable c) => c.profileUid.equals(store.profileUid),
            ))
            .get();
    final Set<String> noteIds = <String>{
      for (final SrsCardCacheRow c in all)
        if (!c.hidden && (scope == null || scope.contains(c.deckId))) c.noteId,
    };
    // 笔记、卡片历史各按块一次预读；卡按笔记先分好组（以前每条笔记各查三次、每张卡各查四五次，
    // 每条笔记还把全部卡片行过滤一遍——平方级，BUG-3543）。
    final List<SrsNoteView> notes = <SrsNoteView>[
      for (final SrsNoteView? n in (await store.notes(noteIds)).values)
        if (n != null && n.deletedAt == null) n,
    ];
    notes.sort((SrsNoteView a, SrsNoteView b) {
      final int c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

    final Map<String, List<SrsCardCacheRow>> visibleCardsOf =
        <String, List<SrsCardCacheRow>>{};
    for (final SrsCardCacheRow c in all) {
      if (!c.hidden) (visibleCardsOf[c.noteId] ??= <SrsCardCacheRow>[]).add(c);
    }
    final Map<String, SrsCardHistory> histories = await store
        .histories(<String>[
          for (final SrsNoteView n in notes)
            for (final SrsCardCacheRow c
                in visibleCardsOf[n.id] ?? const <SrsCardCacheRow>[])
              c.id,
        ]);
    final Map<String, SrsNoteTypeView> types = <String, SrsNoteTypeView>{};
    final Map<String, List<_ExportCard>> cardsOf =
        <String, List<_ExportCard>>{};
    final Set<String> usedDecks = <String>{store.defaultDeckId};
    int minDueDay = today;
    for (final SrsNoteView n in notes) {
      final SrsNoteTypeView? t =
          types[n.noteTypeId] ?? await store.noteType(n.noteTypeId);
      if (t == null) continue;
      types[n.noteTypeId] = t;
      final List<_ExportCard> cs = <_ExportCard>[];
      for (final SrsCardCacheRow c
          in visibleCardsOf[n.id] ?? const <SrsCardCacheRow>[]) {
        final SrsCardHistory h = histories[c.id]!;
        cs.add(_ExportCard(c, h));
        String? d = tree[c.deckId] == null ? store.defaultDeckId : c.deckId;
        while (d != null) {
          usedDecks.add(d);
          d = tree.parentOf(d);
        }
        final int? due = h.state.dueDay;
        if (options.withScheduling &&
            h.state.queue == SrsQueue.review &&
            due != null) {
          minDueDay = min(minDueDay, due);
        }
      }
      cardsOf[n.id] = cs;
    }
    // crt 取最早到期日之前：review 卡的 due（相对 crt 的天数）恒非负。
    final int crtDay = minDueDay;
    final int crtSecs = day.dayStartMs(crtDay) ~/ 1000;
    final int nowSecs = nowMs ~/ 1000;

    final Directory tmp = await Directory.systemTemp.createTemp('fushi_apkg_');
    final File dbFile = File('${tmp.path}${Platform.pathSeparator}c.anki21');
    // 兼容 Anki：只写 Anki 认识的条目，不附带 fushi-ext（日志也就不必写）。
    final File? extFile = options.ankiCompatible
        ? null
        : File('${tmp.path}${Platform.pathSeparator}fushi-ext.json');
    final _ExtWriter? ext = extFile == null
        ? null
        : _ExtWriter(extFile.path, <String, Object?>{
            'format': srsFushiExtFormat,
            'version': srsFushiExtVersion,
            'profileUid': store.profileUid,
          });
    final Database db = sqlite3.open(dbFile.path);
    final Set<String> mediaRefs = <String>{};
    try {
      db.execute(_schema11);
      final PreparedStatement insNote = db.prepare(
        'INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      );
      final PreparedStatement insCard = db.prepare(
        'INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      );
      final PreparedStatement insRev = db.prepare(
        'INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)',
      );
      final Map<String, int> revlogIds = <String, int>{};
      final Map<String, int> extLogCards = <String, int>{};
      final Map<String, Object?> extNotes = <String, Object?>{};
      // 笔记数字 id 是 ankiNumericId 派生的，不是创建时刻：创建时刻另记，回导时恢复。
      final Map<String, int> extCreatedAt = <String, int>{};
      final List<(SrsReviewLog, int)> revlogQueue = <(SrsReviewLog, int)>[];
      int newPos = 0;
      try {
        db.execute('BEGIN');
        for (final SrsNoteView n in notes) {
          final SrsNoteTypeView? t = types[n.noteTypeId];
          if (t == null) continue;
          // 释义样式去重的引用行展开回内联 `<style>`：导出包自包含，AnkiDroid / AnkiMobile
          // 不必认识 `<link>`、也不必带共享样式文件（Fushi 回导时会重新去重）。
          final List<String> values = <String>[
            for (final SrsFieldDef f in t.fields)
              await store.expandStyles(n.field(f.id)),
          ];
          for (final String v in values) {
            mediaRefs.addAll(srsMediaRefsIn(v));
          }
          final String sort = values.isEmpty
              ? ''
              : ankiStripHtml(values.first).trim();
          final int nid = SrsIds.ankiNumericId(n.id);
          insNote.execute(<Object?>[
            nid,
            n.guid,
            t.ankiNum,
            nowSecs,
            -1,
            n.tags.isEmpty ? '' : ' ${n.tags.join(' ')} ',
            values.join('\x1f'),
            sort,
            _checksum(sort),
            0,
            '',
          ]);
          if (n.source != null) extNotes[n.guid] = n.source!.toJson();
          extCreatedAt[n.guid] = n.createdAt;
          for (final _ExportCard ec in cardsOf[n.id] ?? const <_ExportCard>[]) {
            final SrsCardCacheRow c = ec.row;
            final int tplPos = t.templates.indexWhere(
              (SrsTemplateDef x) => x.id == c.templateId,
            );
            if (tplPos < 0) continue;
            final int cid = SrsIds.ankiNumericId(c.id);
            final SrsScheduleResult s = ec.history.state;
            final String deck = tree[c.deckId] == null
                ? store.defaultDeckId
                : c.deckId;
            // 不带学习进度：一律作为新卡（按出卡顺序排位）、去掉暂停，同 Anki「不含学习
            // 进度」导出。
            final bool asNew = !options.withScheduling;
            final List<Object?> sched = asNew
                ? <Object?>[0, 0, newPos, 0]
                : _cardSchedule(s, crtDay: crtDay, newPos: newPos);
            if (asNew || s.queue == SrsQueue.newCard) newPos++;
            insCard.execute(<Object?>[
              cid,
              nid,
              _ankiDeckId(deck),
              t.isCloze ? max(0, c.clozeOrd - 1) : tplPos,
              nowSecs,
              -1,
              sched[0], // type
              c.suspended && !asNew ? -1 : sched[1], // queue
              sched[2], // due
              asNew ? 0 : s.scheduledDays,
              sched[3], // factor
              asNew ? 0 : s.reps,
              asNew ? 0 : s.lapses,
              0,
              0,
              0,
              c.flag,
              '',
            ]);
            if (asNew) continue;
            for (final SrsReviewLog l in ec.history.all) {
              ext?.addLog(l.toJson());
              // 「更改笔记类型」继承来的前身卡日志：记下它在包里归哪张卡，回导时跟到这张卡上。
              if (l.cardId != c.id) extLogCards[l.id] = cid;
            }
            for (final SrsReviewLog l in ec.history.effective) {
              if (_revlogKinds.contains(l.kind)) revlogQueue.add((l, cid));
            }
          }
        }

        // revlog id = 原生日志 occurredAt；撞号按 (时刻, 日志 ID) 排序依次 +1 ms。
        revlogQueue.sort(((SrsReviewLog, int) a, (SrsReviewLog, int) b) {
          final int c = a.$1.occurredAt.compareTo(b.$1.occurredAt);
          return c != 0 ? c : a.$1.id.compareTo(b.$1.id);
        });
        final Set<int> used = <int>{};
        final Map<int, int> lastIvl = <int, int>{};
        for (final (SrsReviewLog l, int cid) in revlogQueue) {
          int id = l.occurredAt;
          while (used.contains(id)) {
            id++;
          }
          used.add(id);
          revlogIds[l.id] = id;
          final int ivl = _revlogIvl(l);
          final SrsScheduleResult? r = l.result;
          insRev.execute(<Object?>[
            id,
            cid,
            -1,
            l.isRatingReview ? (l.rating ?? 0) : 0,
            ivl,
            lastIvl[cid] ?? 0,
            r == null || (r.queue == SrsQueue.newCard && r.reps == 0)
                ? 0
                : (r.ease ?? 2500),
            min(l.durationMs, 60000),
            SrsReviewType.toAnki(l.reviewType),
          ]);
          lastIvl[cid] = ivl;
        }

        final Map<String, Object?> models = <String, Object?>{
          for (final SrsNoteTypeView t in types.values)
            '${t.ankiNum}': _modelJson(t, nowSecs, mediaRefs),
        };
        final (Map<String, Object?> decks, Map<String, Object?> dconf) =
            _decksJson(tree, usedDecks, nowSecs);
        db.execute(
          'INSERT INTO col VALUES (1,?,?,?,11,0,0,0,?,?,?,?,?)',
          <Object?>[
            crtSecs,
            nowMs,
            nowMs,
            jsonEncode(<String, Object?>{
              'activeDecks': <int>[1],
              'curDeck': 1,
              'newSpread': 0,
              'collapseTime': 1200,
              'timeLim': 0,
              'estTimes': true,
              'dueCounts': true,
              'curModel': null,
              'nextPos': newPos + 1,
              'sortType': 'noteFld',
              'sortBackwards': false,
              'addToCur': true,
              'schedVer': 2,
              'rollover': day.rolloverHour,
              'creationOffset': -day.utcOffsetMin,
              'localOffset': -day.utcOffsetMin,
              'fsrs': true,
            }),
            jsonEncode(models),
            jsonEncode(decks),
            jsonEncode(dconf),
            '{}',
          ],
        );
        db.execute('COMMIT');
      } finally {
        insNote.close();
        insCard.close();
        insRev.close();
      }

      ext?.finish(<String, Object?>{
        'revlogIds': revlogIds,
        if (extLogCards.isNotEmpty) 'logCards': extLogCards,
        'notes': extNotes,
        'noteCreatedAt': extCreatedAt,
        'decks': <Map<String, Object?>>[
          for (final String d in usedDecks)
            if (options.withDeckConfigs && tree[d] != null)
              <String, Object?>{
                'name': tree.fullName(d),
                'values': <String, Object?>{
                  for (final String k in srsFushiExtDeckKeys)
                    if (tree[d]!.edits[k] != null) k: tree[d]!.edits.value(k),
                },
              },
        ],
      });
    } on Object {
      ext?.abort();
      db.close();
      await _deleteQuietly(tmp);
      rethrow;
    }
    db.close();

    // 条目逐个写进 zip 文件：集合与 fushi-ext 从临时文件分块原生 deflate，媒体读一个写一个。
    final ZipFileEncoder zip = ZipFileEncoder()..create(out.path);
    try {
      addFileNativeDeflate(zip, dbFile, 'collection.anki21');
      final Map<String, String> mediaJson = <String, String>{};
      if (loadMedia != null) {
        int i = 0;
        for (final String name in mediaRefs.toList()..sort()) {
          final Uint8List? b = await loadMedia(name);
          if (b == null) continue;
          zip.addArchiveFile(nativeDeflatedArchiveFile('$i', b));
          mediaJson['$i'] = name;
          i++;
        }
      }
      zip.addArchiveFile(
        nativeDeflatedArchiveFile('media', utf8.encode(jsonEncode(mediaJson))),
      );
      if (extFile != null) addFileNativeDeflate(zip, extFile, srsFushiExtEntry);
    } finally {
      zip.closeSync();
      await _deleteQuietly(tmp);
    }
  }

  /// [type, queue, due, factor]
  List<Object?> _cardSchedule(
    SrsScheduleResult s, {
    required int crtDay,
    required int newPos,
  }) => switch (s.queue) {
    SrsQueue.newCard => <Object?>[0, 0, newPos, 0],
    SrsQueue.learning => <Object?>[
      1,
      1,
      (s.dueAt ?? 0) ~/ 1000,
      s.ease ?? 2500,
    ],
    SrsQueue.relearning => <Object?>[
      3,
      1,
      (s.dueAt ?? 0) ~/ 1000,
      s.ease ?? 2500,
    ],
    SrsQueue.review => <Object?>[
      2,
      2,
      (s.dueDay ?? crtDay) - crtDay,
      s.ease ?? 2500,
    ],
  };

  /// revlog.ivl：复习间隔天数；学习步是负的秒数。
  static int _revlogIvl(SrsReviewLog l) {
    final SrsScheduleResult? r = l.result;
    if (r == null) return 0;
    switch (r.queue) {
      case SrsQueue.review:
        return r.scheduledDays;
      case SrsQueue.learning:
      case SrsQueue.relearning:
        final int? at = r.dueAt;
        if (at == null) return 0;
        return -max(1, (at - l.occurredAt) ~/ 1000);
      case SrsQueue.newCard:
        return 0;
    }
  }

  /// Anki 的 csum：去 HTML 后首字段 SHA-1 的前 8 个十六进制位。
  static int _checksum(String text) => int.parse(
    sha1.convert(utf8.encode(text)).toString().substring(0, 8),
    radix: 16,
  );

  Map<String, Object?> _modelJson(
    SrsNoteTypeView t,
    int nowSecs,
    Set<String> mediaRefs,
  ) {
    final Map<String, String> idToName = <String, String>{
      for (final SrsFieldDef f in t.fields) f.id: f.name,
    };
    final List<Map<String, Object?>> tmpls = <Map<String, Object?>>[];
    for (int i = 0; i < t.templates.length; i++) {
      final SrsTemplateDef tpl = t.templates[i];
      final String q = templateIdsToNames(tpl.front, idToName);
      final String a = templateIdsToNames(tpl.back, idToName);
      mediaRefs
        ..addAll(srsMediaRefsIn(q, includeStatic: true))
        ..addAll(srsMediaRefsIn(a, includeStatic: true));
      tmpls.add(<String, Object?>{
        'name': tpl.name,
        'ord': i,
        'qfmt': q,
        'afmt': a,
        'bqfmt': '',
        'bafmt': '',
        'did': null,
        'bfont': '',
        'bsize': 0,
        if (tpl.ankiNum != null) 'id': tpl.ankiNum,
      });
    }
    mediaRefs.addAll(srsMediaRefsIn(t.css, includeStatic: true));
    final List<int> allOrds = <int>[
      for (int i = 0; i < t.fields.length; i++) i,
    ];
    return <String, Object?>{
      'id': t.ankiNum,
      'name': t.name,
      'type': t.isCloze ? 1 : 0,
      'mod': nowSecs,
      'usn': -1,
      'sortf': 0,
      'did': 1,
      'tmpls': tmpls,
      'flds': <Map<String, Object?>>[
        for (int i = 0; i < t.fields.length; i++)
          <String, Object?>{
            'name': t.fields[i].name,
            'ord': i,
            'sticky': false,
            'rtl': false,
            'font': 'Arial',
            'size': 20,
            'description': t.fields[i].description,
            'plainText': false,
            'collapsed': false,
            'excludeFromSearch': false,
            if (t.fields[i].ankiNum != null) 'id': t.fields[i].ankiNum,
          },
      ],
      'css': t.css,
      'latexPre':
          '\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n'
          '\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n'
          '\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n',
      'latexPost': '\\end{document}',
      'latexsvg': false,
      'req': <Object?>[
        for (int i = 0; i < t.templates.length; i++)
          <Object?>[i, 'any', allOrds],
      ],
    };
  }

  (Map<String, Object?>, Map<String, Object?>) _decksJson(
    SrsDeckTree tree,
    Set<String> used,
    int nowSecs,
  ) {
    final Map<String, Object?> decks = <String, Object?>{};
    final Map<String, Object?> dconf = <String, Object?>{};
    for (final String id in used) {
      final SrsDeckView? d = tree[id];
      final String name = id == store.defaultDeckId
          ? 'Default'
          : (d == null ? 'Default' : tree.fullName(id));
      final String ownerId = d == null ? id : tree.paramsOwner(id).id;
      // 不带牌组预设：所有牌组共用 Anki 的默认预设（id 1，全部取默认值）。
      final int confId = options.withDeckConfigs ? _ankiDeckId(ownerId) : 1;
      decks['${_ankiDeckId(id)}'] = <String, Object?>{
        'id': _ankiDeckId(id),
        'mod': nowSecs,
        'name': name,
        'usn': -1,
        'lrnToday': <int>[0, 0],
        'revToday': <int>[0, 0],
        'newToday': <int>[0, 0],
        'timeToday': <int>[0, 0],
        'collapsed': d?.collapsed ?? false,
        'browserCollapsed': false,
        'desc': '',
        'dyn': 0,
        'conf': confId,
        'extendNew': 0,
        'extendRev': 0,
      };
      if (!dconf.containsKey('$confId')) {
        dconf['$confId'] = options.withDeckConfigs
            ? _dconfJson(
                confId,
                tree[ownerId],
                d,
                tree[ownerId]?.name ?? 'Default',
                nowSecs,
              )
            : _dconfJson(confId, null, null, 'Default', nowSecs);
      }
    }
    return (decks, dconf);
  }

  Map<String, Object?> _dconfJson(
    int id,
    SrsDeckView? owner,
    SrsDeckView? self,
    String name,
    int nowSecs,
  ) {
    final SrsDeckView? o = owner ?? self;
    final List<double> fsrs6 = o?.fsrs6?.params ?? const <double>[];
    return <String, Object?>{
      'id': id,
      'mod': nowSecs,
      'name': name,
      'usn': -1,
      'maxTaken': 60,
      'autoplay': o?.autoplayAudio ?? true,
      'timer': 0,
      'replayq': o?.replayQuestionAudio ?? true,
      'new': <String, Object?>{
        'bury': false,
        'delays':
            o?.learnStepsFor(o.localAlgorithm) ?? SrsDeckView.defaultLearnSteps,
        'initialFactor': 2500,
        'ints': <int>[1, 4, 0],
        'order': 1,
        'perDay': o?.newPerDay ?? 20,
      },
      'rev': <String, Object?>{
        'bury': false,
        'ease4': 1.3,
        'ivlFct': 1.0,
        'maxIvl': o?.maxIntervalDays ?? 36500,
        'perDay': o?.reviewsPerDay ?? 200,
        'hardFactor': 1.2,
      },
      'lapse': <String, Object?>{
        'delays':
            o?.relearnStepsFor(o.localAlgorithm) ??
            SrsDeckView.defaultRelearnSteps,
        'leechAction': 1,
        'leechFails': 8,
        'minInt': 1,
        'mult': 0.0,
      },
      'dyn': false,
      'newMix': 0,
      'newPerDayMinimum': 0,
      'interdayLearningMix': 0,
      'reviewOrder': 0,
      'newSortOrder': 0,
      'newGatherPriority': 0,
      'buryInterdayLearning': false,
      'fsrsWeights': <double>[],
      'fsrsParams5': <double>[],
      // 只写 FSRS-6 参数组；FSRS-7 参数 Anki 主线不认，不写。
      'fsrsParams6': fsrs6.length == SrsAlgorithm.fsrs6.paramCount
          ? fsrs6
          : <double>[],
      // Anki RWKV fork 认这个键（导入时读的就是它）；Anki 主线忽略。
      if (o?.localAlgorithm == SrsAlgorithm.rwkv) 'rwkvReviewEnabled': true,
      'desiredRetention': o?.desiredRetention ?? 0.9,
      'ignoreRevlogsBeforeDate': '',
      'easyDaysPercentages': <double>[1, 1, 1, 1, 1, 1, 1],
      'stopTimerOnAnswer': false,
      'secondsToShowQuestion': 0.0,
      'secondsToShowAnswer': 0.0,
      'questionAction': 0,
      'answerAction': 0,
      'waitForAudio': true,
      'sm2Retention': 0.9,
      'weightSearch': '',
    };
  }
}
