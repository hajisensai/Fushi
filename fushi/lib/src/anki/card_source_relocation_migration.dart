/// 存量小说卡片「回到出处」坐标的一次性后台迁移（拍板 hSZjfrcejt）。
///
/// BUG-4914 修复前制的小说卡，出处链接（`fushi://source?kind=book…`）与制卡历史里存的是
/// 音频匹配坐标，回看高亮错位。这里把它们逐条交给 [relocateReaderSourceSpan] 按卡上的句子
/// 在原书里核对 / 重定位，改写成学习单位坐标；定位不到的保留原值。
///
/// 覆盖两处本机数据：
/// - **Fushi 复习**（当前 profile 的 SRS 库）：字段里带书籍出处链接的笔记——改写链接 href，
///   笔记的结构化出处（`SrsSourceRef.book` 的 start / len）同一笔改；修改记录标 machine，
///   照常同步到别的设备。
/// - **制卡历史**（`mined_sentences`，source = book）。
///
/// 外部 Anki（AnkiConnect / AnkiDroid）里的卡不在这里改：那是用户自己的 Anki 库，要 Anki
/// 开着才能写，不适合静默后台改（见 PR 说明 / leftovers）。
///
/// **幂等、可中断恢复**：按书分批，每批写完就把这本书记进状态文件（[CardSourceRelocationStateFile]，
/// 设备本地，放在支持目录）；中断后下次启动跳过已完成的书，从下一本接着做。同一本书做到一半
/// 被打断也无妨——已改写的条目再核对一遍会判成「已正确」，不会被二次改动。全部做完记
/// `done`，以后不再扫描。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_anki/fushi_anki.dart' show CardSourceKind, CardSourceLink;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/reader_source_relocation.dart';
import 'package:fushi/src/srs/srs_word_audio_backfill.dart'
    show srsWordAudioQueryText;

/// 一次迁移（或续跑）的汇总。
class CardSourceRelocationReport {
  const CardSourceRelocationReport({
    this.relocated = 0,
    this.verified = 0,
    this.notLocated = 0,
  });

  factory CardSourceRelocationReport.fromJson(Object? json) {
    final Map<String, Object?> m = json is Map
        ? json.cast<String, Object?>()
        : const <String, Object?>{};
    int read(String key) => (m[key] as num?)?.toInt() ?? 0;
    return CardSourceRelocationReport(
      relocated: read('relocated'),
      verified: read('verified'),
      notLocated: read('notLocated'),
    );
  }

  /// 改写了坐标的条数（修好的）。
  final int relocated;

  /// 已经是对的、没动的条数。
  final int verified;

  /// 书不在本机 / 章不在 / 卡上文字在原章找不到，保留原值的条数。
  final int notLocated;

  int get total => relocated + verified + notLocated;

  CardSourceRelocationReport operator +(CardSourceRelocationReport other) =>
      CardSourceRelocationReport(
        relocated: relocated + other.relocated,
        verified: verified + other.verified,
        notLocated: notLocated + other.notLocated,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'relocated': relocated,
    'verified': verified,
    'notLocated': notLocated,
  };

  @override
  bool operator ==(Object other) =>
      other is CardSourceRelocationReport &&
      other.relocated == relocated &&
      other.verified == verified &&
      other.notLocated == notLocated;

  @override
  int get hashCode => Object.hash(relocated, verified, notLocated);

  @override
  String toString() =>
      'CardSourceRelocationReport(relocated: $relocated, verified: $verified, '
      'notLocated: $notLocated)';
}

/// 一个范围（制卡历史 / 某个 SRS profile）的迁移进度。
class CardSourceRelocationScopeState {
  const CardSourceRelocationScopeState({
    this.done = false,
    this.doneBooks = const <String>{},
    this.report = const CardSourceRelocationReport(),
  });

  factory CardSourceRelocationScopeState.fromJson(Object? json) {
    final Map<String, Object?> m = json is Map
        ? json.cast<String, Object?>()
        : const <String, Object?>{};
    return CardSourceRelocationScopeState(
      done: m['done'] == true,
      doneBooks: <String>{
        for (final Object? b in (m['doneBooks'] as List<Object?>?) ?? const [])
          if (b is String) b,
      },
      report: CardSourceRelocationReport.fromJson(m['report']),
    );
  }

  final bool done;

  /// 已处理完的书（分组键，见 [CardSourceRelocationItem.bookGroup]）。
  final Set<String> doneBooks;
  final CardSourceRelocationReport report;

  Map<String, Object?> toJson() => <String, Object?>{
    'done': done,
    'doneBooks': (doneBooks.toList()..sort()),
    'report': report.toJson(),
  };
}

/// 迁移状态文件（JSON，范围名 → [CardSourceRelocationScopeState]）。设备本地：描述的是
/// **这台设备的数据**改到哪了，不随备份 / 设置同步走。
class CardSourceRelocationStateFile {
  CardSourceRelocationStateFile(this.file);

  /// 支持目录下的默认位置。
  static Future<CardSourceRelocationStateFile> standard(
    Directory supportRoot,
  ) async => CardSourceRelocationStateFile(
    File(p.join(supportRoot.path, kCardSourceRelocationStateFileName)),
  );

  final File file;

  Future<Map<String, Object?>> _readAll() async {
    try {
      if (!file.existsSync()) return <String, Object?>{};
      final Object? json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, Object?>() : <String, Object?>{};
    } on FormatException {
      // 写坏的状态文件当没有：迁移本身幂等，从头再核对一遍只多花时间。
      return <String, Object?>{};
    }
  }

  Future<CardSourceRelocationScopeState> read(String scope) async =>
      CardSourceRelocationScopeState.fromJson((await _readAll())[scope]);

  Future<void> write(String scope, CardSourceRelocationScopeState state) async {
    final Map<String, Object?> all = await _readAll();
    all[scope] = state.toJson();
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(all), flush: true);
    await tmp.rename(file.path);
  }
}

/// 状态文件名（版本号随迁移算法走：算法改了要重跑就换名字）。
const String kCardSourceRelocationStateFileName =
    'card_source_relocation_v1.json';

/// 一条待核对的出处。
class CardSourceRelocationItem {
  const CardSourceRelocationItem({
    required this.bookGroup,
    required this.request,
    required this.write,
  });

  /// 所在书的解压目录；null = 书不在本机（直接计「定位不到」）。
  final String? bookGroup;
  final ReaderSourceRelocationRequest request;

  /// 把重定位结果写回；返回 false = 期间被别的写入改过 / 条目没了，没写（计「定位不到」）。
  final Future<bool> Function(int offset, int length) write;
}

/// 在解压目录 [extractDir] 的书里核对一批出处（app 侧在后台 isolate 跑
/// [relocateReaderSourceSpansInExtractedBook]；测试注入假实现）。
typedef CardSourceBookRelocator =
    Future<List<ReaderSourceRelocation>> Function(
      String extractDir,
      List<ReaderSourceRelocationRequest> requests,
    );

Future<List<ReaderSourceRelocation>> relocateInBackgroundIsolate(
  String extractDir,
  List<ReaderSourceRelocationRequest> requests,
) => Isolate.run(
  () => relocateReaderSourceSpansInExtractedBook((
    extractDir: extractDir,
    requests: requests,
  )),
);

/// 「书不在本机」这一组在状态文件里的键。
const String _kMissingBookGroup = '';

/// 跑一个范围的迁移（已做完的直接返回 null；做完返回这个范围累计的报告）。
///
/// 一本书核对失败（书坏了 / 文件缺了，解析或建索引抛异常）只算这本书的条目「定位不到」、
/// 交给 [onBookError] 记一笔，照样把这本书记为已做、接着做下一本：同一本书每次启动都会
/// 同样失败，若整个迁移随之中止，排在它后面的书永远轮不到、每次启动都重新解析它一遍。
/// 写回与状态文件抛出的异常（库关了 / 磁盘满）原样抛给调用方，已完成的书已落进状态文件，
/// 下次从下一本接着做。
Future<CardSourceRelocationReport?> runCardSourceRelocationScope({
  required String scope,
  required CardSourceRelocationStateFile stateFile,
  required Future<List<CardSourceRelocationItem>> Function() loadItems,
  required CardSourceBookRelocator relocate,
  void Function(String book, Object error, StackTrace stack)? onBookError,
}) async {
  CardSourceRelocationScopeState state = await stateFile.read(scope);
  if (state.done) return null;
  final Map<String, List<CardSourceRelocationItem>> byBook =
      <String, List<CardSourceRelocationItem>>{};
  for (final CardSourceRelocationItem item in await loadItems()) {
    (byBook[item.bookGroup ?? _kMissingBookGroup] ??=
            <CardSourceRelocationItem>[])
        .add(item);
  }
  final List<String> books = byBook.keys.toList()..sort();
  for (final String book in books) {
    if (state.doneBooks.contains(book)) continue;
    final List<CardSourceRelocationItem> items = byBook[book]!;
    final List<ReaderSourceRelocation> unresolved = <ReaderSourceRelocation>[
      for (final CardSourceRelocationItem _ in items)
        const ReaderSourceRelocation.notLocated(),
    ];
    List<ReaderSourceRelocation> results = unresolved;
    if (book != _kMissingBookGroup) {
      try {
        results = await relocate(book, <ReaderSourceRelocationRequest>[
          for (final CardSourceRelocationItem i in items) i.request,
        ]);
      } catch (e, stack) {
        onBookError?.call(book, e, stack);
      }
    }
    int relocated = 0;
    int verified = 0;
    int notLocated = 0;
    for (int i = 0; i < items.length; i++) {
      final ReaderSourceRelocation r = results[i];
      switch (r.status) {
        case ReaderSourceRelocationStatus.verified:
          verified++;
        case ReaderSourceRelocationStatus.notLocated:
          notLocated++;
        case ReaderSourceRelocationStatus.relocated:
          if (await items[i].write(r.offset!, r.length!)) {
            relocated++;
          } else {
            notLocated++;
          }
      }
    }
    state = CardSourceRelocationScopeState(
      doneBooks: <String>{...state.doneBooks, book},
      report:
          state.report +
          CardSourceRelocationReport(
            relocated: relocated,
            verified: verified,
            notLocated: notLocated,
          ),
    );
    await stateFile.write(scope, state);
  }
  state = CardSourceRelocationScopeState(
    done: true,
    doneBooks: state.doneBooks,
    report: state.report,
  );
  await stateFile.write(scope, state);
  return state.report;
}

// ------------------------------------------------------------------ 制卡历史

/// 制卡历史范围的状态键。
const String kCardSourceRelocationHistoryScope = 'mined_sentences';

/// 制卡历史里待核对的书内条目。[extractDirOf] 按 bookKey 找本机解压目录（没有为 null）。
Future<List<CardSourceRelocationItem>> loadMinedSentenceRelocationItems(
  FushiDatabase db, {
  required Future<String?> Function(String bookKey) extractDirOf,
}) async {
  final Map<String, String?> dirs = <String, String?>{};
  final List<CardSourceRelocationItem> out = <CardSourceRelocationItem>[];
  for (final MinedSentenceRow row in await db.getAllMinedSentences()) {
    final String? bookKey = row.bookKey;
    final int? section = row.sectionIndex;
    final int? offset = row.normCharOffset;
    if (row.source != kStatSourceBook ||
        bookKey == null ||
        bookKey.isEmpty ||
        section == null ||
        offset == null) {
      continue;
    }
    if (!dirs.containsKey(bookKey)) dirs[bookKey] = await extractDirOf(bookKey);
    final int? length = row.normCharLength;
    out.add(
      CardSourceRelocationItem(
        bookGroup: dirs[bookKey],
        request: ReaderSourceRelocationRequest(
          chapterIndex: section,
          offset: offset,
          length: length,
          texts: <String>[row.sentence, row.expression],
        ),
        write: (int newOffset, int newLength) async =>
            await db.updateMinedSentenceCharAnchor(
              row.id,
              expectedOffset: offset,
              expectedLength: length,
              normCharOffset: newOffset,
              normCharLength: newLength,
            ) ==
            1,
      ),
    );
  }
  return out;
}

// ------------------------------------------------------------------ Fushi 复习

/// SRS 范围的状态键（按 profile 分开）。
String cardSourceRelocationSrsScope(String profileUid) => 'srs:$profileUid';

/// 字段里书籍出处链接的公共子串（href 里 `&` 可能转义成 `&amp;`，这一段两种写法都有）。
const String _kBookLinkNeedle = 'kind=book';

final RegExp _sourceHref = RegExp(
  r'''(href\s*=\s*["'])(fushi://source/?\?[^"'<>]+)(["'])''',
  caseSensitive: false,
);

/// [link] 换成新区间（其余参数原样）。
CardSourceLink cardSourceLinkWithSpan(
  CardSourceLink link, {
  required int offset,
  required int length,
}) => CardSourceLink(
  kind: link.kind,
  uid: link.uid,
  sourceId: link.sourceId,
  chapterIndex: link.chapterIndex,
  charOffset: offset,
  charLength: length,
  pageIndex: link.pageIndex,
  episodeIndex: link.episodeIndex,
  startMs: link.startMs,
  endMs: link.endMs,
  audioFileIndex: link.audioFileIndex,
  chapterId: link.chapterId,
  fingerprint: link.fingerprint,
  bookKey: link.bookKey,
);

/// 把 [html] 里 sourceId 与 [next] 相同的出处 href 换成 [next]；其余内容逐字节不动。
String replaceCardSourceLinkHref(String html, CardSourceLink next) =>
    html.replaceAllMapped(_sourceHref, (Match m) {
      final CardSourceLink? link = CardSourceLink.tryParse(
        m.group(2)!.replaceAll('&amp;', '&'),
      );
      if (link == null || link.sourceId != next.sourceId) return m.group(0)!;
      final String href = const HtmlEscape(
        HtmlEscapeMode.attribute,
      ).convert(next.toUri().toString());
      return '${m.group(1)}$href${m.group(3)}';
    });

/// 一条字段里可以重定位的书籍出处链接（有章、有起点）。
Iterable<CardSourceLink> _bookLinks(String field) =>
    CardSourceLink.fromHtml(field).where(
      (CardSourceLink l) =>
          l.kind == CardSourceKind.book &&
          l.chapterIndex != null &&
          l.charOffset != null,
    );

/// 按 SQLite 变量上限分块。
Iterable<List<String>> _chunks(List<String> ids, [int size = 500]) sync* {
  for (int i = 0; i < ids.length; i += size) {
    yield ids.sublist(i, i + size > ids.length ? ids.length : i + size);
  }
}

/// [store] 里字段带书籍出处链接的笔记，每条链接一项。卡上文字取**不带出处链接**的字段
/// （去注音 / 标签后的纯文字）：带链接的字段只有锚文本（书名），拿它去章里找会找错。
/// [extractDirOf] 按链接找本机书的解压目录（没有为 null）。
Future<List<CardSourceRelocationItem>> loadSrsNoteRelocationItems(
  SrsDbStore store, {
  required Future<String?> Function(CardSourceLink link) extractDirOf,
}) async {
  final List<String> ids = await store.sourceNoteCandidates(_kBookLinkNeedle);
  final Map<String, String?> dirs = <String, String?>{};
  final List<CardSourceRelocationItem> out = <CardSourceRelocationItem>[];
  for (final List<String> chunk in _chunks(ids)) {
    final Map<String, SrsNoteView?> views = await store.notes(chunk);
    for (final String noteId in chunk) {
      final SrsNoteView? note = views[noteId];
      if (note == null || note.deletedAt != null) continue;
      final List<String> texts = <String>[
        for (final String value in note.fields.values)
          if (!value.contains('fushi://source')) srsWordAudioQueryText(value),
      ];
      for (final MapEntry<String, String> field in note.fields.entries) {
        for (final CardSourceLink link in _bookLinks(field.value)) {
          final String dirKey = '${link.uid}\u0000${link.bookKey ?? ''}';
          if (!dirs.containsKey(dirKey)) {
            dirs[dirKey] = await extractDirOf(link);
          }
          out.add(
            CardSourceRelocationItem(
              bookGroup: dirs[dirKey],
              request: ReaderSourceRelocationRequest(
                chapterIndex: link.chapterIndex!,
                offset: link.charOffset!,
                length: link.charLength,
                texts: texts,
              ),
              write: (int offset, int length) => _writeSrsLink(
                store,
                noteId: noteId,
                fieldId: field.key,
                original: field.value,
                link: link,
                offset: offset,
                length: length,
              ),
            ),
          );
        }
      }
    }
  }
  return out;
}

/// 写回一条笔记的出处链接（乐观并发：字段在扫描之后被改过就不写）。结构化出处
/// （`SrsSourceRef.book`）指的是同一处时同一笔改掉。
Future<bool> _writeSrsLink(
  SrsDbStore store, {
  required String noteId,
  required String fieldId,
  required String original,
  required CardSourceLink link,
  required int offset,
  required int length,
}) async {
  final SrsNoteView? note = (await store.notes(<String>[noteId]))[noteId];
  if (note == null || note.deletedAt != null) return false;
  if (note.field(fieldId) != original) return false;
  final String next = replaceCardSourceLinkHref(
    original,
    cardSourceLinkWithSpan(link, offset: offset, length: length),
  );
  if (next == original) return false;
  final SrsSourceRef? source = note.source;
  final bool sameSource =
      source != null &&
      source.kind == SrsSourceKind.book &&
      source.data['section'] == link.chapterIndex &&
      source.data['start'] == link.charOffset;
  await store.editFields(SrsEntityKind.note, noteId, <String, Object?>{
    SrsFieldKeys.noteField(fieldId): next,
    if (sameSource)
      SrsFieldKeys.noteSource: SrsSourceRef(
        SrsSourceKind.book,
        <String, Object?>{...source.data, 'start': offset, 'len': length},
      ).toJson(),
  }, machine: true);
  return true;
}
