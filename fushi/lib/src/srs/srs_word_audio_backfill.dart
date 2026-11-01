/// 复习（SRS）「补全单词音频」（反馈 LOIae5mPUS）：给一个牌组（含子牌组）里单词音频
/// 字段为空的 Fushi 卡片，按卡上**已有**的词与读音去查用户配置的音频来源，查到就存进
/// SRS 媒体并写回单词音频字段。
///
/// - 只处理内置「Fushi 卡片」笔记类型：词 = `Term`、读音 = `TermReading`、单词音频 =
///   `TermAudio`（按内置 fieldId 定位，用户改过字段名也认）。
/// - 读音只取 `TermReading` 字段的现成值（制卡时从词典词条带来的），**绝不**做任何机器推断
///   读音（自动注音是全仓功能黑名单）；读音为空就只拿词去查（音频来源接口本来就接受空读音，
///   与查词时词条没有读音的情况同一口径），词为空的卡跳过。
/// - 查音频 / 落文件 / 存媒体 / 写字段都由调用方注入（[SrsWordAudioBackfillDeps]）：app 侧
///   复用制卡时取单词音频的同一条路径（见 srs_word_audio_backfill_dialog.dart），测试注入假实现。
/// - 扫描走批量读：牌组子树 → 卡片缓存按块取笔记 id → 笔记缓存按块筛 Fushi 卡片 →
///   [SrsDbStore.notes] 按块物化，不逐卡往返。写字段走 [SrsDbStore.updateNote]（修改记录，
///   可同步、编辑历史可见）。
/// - 逐张串行处理（网络来源不并发）；可取消，取消后不再处理后续，已写入的保留。
library;

import 'package:drift/drift.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsAudioSources, srsPlainText;

/// 一张待补单词音频的笔记：词与读音都是卡上现成的值（读音可为空）。
class SrsWordAudioBackfillItem {
  const SrsWordAudioBackfillItem({
    required this.noteId,
    required this.term,
    required this.reading,
  });

  final String noteId;
  final String term;
  final String reading;

  @override
  bool operator ==(Object other) =>
      other is SrsWordAudioBackfillItem &&
      other.noteId == noteId &&
      other.term == term &&
      other.reading == reading;

  @override
  int get hashCode => Object.hash(noteId, term, reading);

  @override
  String toString() => 'SrsWordAudioBackfillItem($noteId, $term, $reading)';
}

/// 内置 Fushi 卡片在某 profile 下的三个相关字段 id。
class SrsWordAudioBackfillFields {
  const SrsWordAudioBackfillFields({
    required this.noteTypeId,
    required this.termFieldId,
    required this.readingFieldId,
    required this.audioFieldId,
  });

  factory SrsWordAudioBackfillFields.forProfile(String profileUid) =>
      SrsWordAudioBackfillFields(
        noteTypeId: srsFushiCardNoteTypeId(profileUid),
        termFieldId: srsFushiCardFieldId(profileUid, FushiCardFields.term),
        readingFieldId: srsFushiCardFieldId(
          profileUid,
          FushiCardFields.termReading,
        ),
        audioFieldId: srsFushiCardFieldId(
          profileUid,
          FushiCardFields.termAudio,
        ),
      );

  final String noteTypeId;
  final String termFieldId;
  final String readingFieldId;
  final String audioFieldId;
}

/// 单词音频字段算不算「空」：没有任何可播的音频引用（`[sound:]` / `<audio src>`），也没有
/// 别的可见文字。只有空白 / 空标签的字段算空；带着失效引用的字段不算空（不覆盖用户的内容）。
bool srsWordAudioFieldIsEmpty(String raw) =>
    raw.trim().isEmpty ||
    (srsAudioSources(raw).isEmpty && srsPlainText(raw).isEmpty);

final RegExp _rubyAnnotation = RegExp(
  r'<(rt|rp)\b[^>]*>.*?</\1\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// 字段值 → 查音频用的纯文字：去掉 ruby 注音部分（`<rt>` / `<rp>`，只留基字）、全部标签与
/// `[sound:]`，解实体、收空白。只做「取现成文字」，不推断任何读音。
String srsWordAudioQueryText(String raw) =>
    srsPlainText(raw.replaceAll(_rubyAnnotation, '')).replaceAll('\n', ' ');

/// 从物化好的笔记里挑出待补音频的：内置 Fushi 卡片、未删除、单词音频字段为空。
/// 词为空的卡也收进来（[SrsWordAudioBackfillItem.term] 为空），由执行时计为跳过。
List<SrsWordAudioBackfillItem> srsWordAudioBackfillCandidates(
  Iterable<SrsNoteView> notes,
  SrsWordAudioBackfillFields fields,
) => <SrsWordAudioBackfillItem>[
  for (final SrsNoteView n in notes)
    if (n.deletedAt == null &&
        n.noteTypeId == fields.noteTypeId &&
        srsWordAudioFieldIsEmpty(n.field(fields.audioFieldId)))
      SrsWordAudioBackfillItem(
        noteId: n.id,
        term: srsWordAudioQueryText(n.field(fields.termFieldId)),
        reading: srsWordAudioQueryText(n.field(fields.readingFieldId)),
      ),
];

/// 按 SQLite 变量上限分块（IN 列表）。
Iterable<List<String>> _chunks(List<String> ids, [int size = 500]) sync* {
  for (int i = 0; i < ids.length; i += size) {
    yield ids.sublist(i, i + size > ids.length ? ids.length : i + size);
  }
}

/// [deckId]（含子牌组）里待补单词音频的 Fushi 卡片，按笔记创建时间升序（与列表口径无关，只为
/// 稳定）。全程批量读：卡片缓存 / 笔记缓存按块查，笔记按块物化。
Future<List<SrsWordAudioBackfillItem>> loadSrsWordAudioBackfillItems(
  SrsDbStore store,
  String deckId,
) async {
  final SrsWordAudioBackfillFields fields =
      SrsWordAudioBackfillFields.forProfile(store.profileUid);
  final SrsDeckTree tree = await store.deckTree();
  final List<String> decks = tree.subtree(deckId);
  if (decks.isEmpty) return const <SrsWordAudioBackfillItem>[];
  final SrsDatabase db = store.db;

  final $SrsCardsCacheTable c = db.srsCardsCache;
  final Set<String> noteIds = <String>{};
  for (final List<String> chunk in _chunks(decks)) {
    final List<TypedResult> rows =
        await (db.selectOnly(c, distinct: true)
              ..addColumns(<Expression<Object>>[c.noteId])
              ..where(
                c.profileUid.equals(store.profileUid) & c.deckId.isIn(chunk),
              ))
            .get();
    noteIds.addAll(rows.map((TypedResult r) => r.read(c.noteId)!));
  }
  if (noteIds.isEmpty) return const <SrsWordAudioBackfillItem>[];

  // 笔记缓存先筛掉别的笔记类型 / 已删的：只物化 Fushi 卡片。
  final $SrsNotesCacheTable n = db.srsNotesCache;
  final List<(String, int)> fushiNotes = <(String, int)>[];
  for (final List<String> chunk in _chunks(noteIds.toList())) {
    final List<TypedResult> rows =
        await (db.selectOnly(n)
              ..addColumns(<Expression<Object>>[n.id, n.createdAt])
              ..where(
                n.profileUid.equals(store.profileUid) &
                    n.id.isIn(chunk) &
                    n.noteTypeId.equals(fields.noteTypeId) &
                    n.deletedAt.isNull(),
              ))
            .get();
    for (final TypedResult r in rows) {
      fushiNotes.add((r.read(n.id)!, r.read(n.createdAt)!));
    }
  }
  fushiNotes.sort(
    ((String, int) a, (String, int) b) =>
        a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
  );
  final List<String> ordered = <String>[
    for (final (String, int) e in fushiNotes) e.$1,
  ];
  final List<SrsWordAudioBackfillItem> out = <SrsWordAudioBackfillItem>[];
  for (final List<String> chunk in _chunks(ordered)) {
    final Map<String, SrsNoteView?> views = await store.notes(chunk);
    out.addAll(
      srsWordAudioBackfillCandidates(<SrsNoteView>[
        for (final String id in chunk)
          if (views[id] case final SrsNoteView v) v,
      ], fields),
    );
  }
  return out;
}

/// 单张卡取音频的结果。
sealed class SrsWordAudioFetch {
  const SrsWordAudioFetch();
}

/// 没有任何来源有这个词（不是错误）。
class SrsWordAudioNotFound extends SrsWordAudioFetch {
  const SrsWordAudioNotFound();
}

/// 拿到了，已存进 SRS 媒体，[mediaName] 是存储后的文件名。
class SrsWordAudioStored extends SrsWordAudioFetch {
  const SrsWordAudioStored(this.mediaName);

  final String mediaName;
}

/// 找到了来源但没取回来（下载非 200、网络错误、落盘失败……），[reason] 给诊断。
class SrsWordAudioFetchFailed extends SrsWordAudioFetch {
  const SrsWordAudioFetchFailed(this.reason);

  final String reason;
}

/// 「查音频 → 落文件 → 存媒体」：返回 [SrsWordAudioFetch]；抛出也按失败计。
typedef SrsWordAudioFetcher =
    Future<SrsWordAudioFetch> Function(String term, String reading);

/// 把单词音频字段写成 [value]（只写这一个字段）。
typedef SrsWordAudioFieldWriter =
    Future<void> Function(String noteId, String value);

/// 执行时注入的依赖。
class SrsWordAudioBackfillDeps {
  const SrsWordAudioBackfillDeps({required this.fetch, required this.write});

  final SrsWordAudioFetcher fetch;
  final SrsWordAudioFieldWriter write;
}

/// 一次补全的汇总。
class SrsWordAudioBackfillResult {
  const SrsWordAudioBackfillResult({
    required this.total,
    required this.filled,
    required this.skipped,
    required this.failed,
    required this.cancelled,
    this.failures = const <String>[],
  });

  /// 待补的卡数（扫描结果）。
  final int total;

  /// 补上音频的卡数。
  final int filled;

  /// 没查到音频 / 卡上没有词的卡数。
  final int skipped;

  /// 出错的卡数（找到来源但没取回、存 / 写失败）。
  final int failed;

  /// 中途取消：此时 `filled + skipped + failed < total`，余下的没处理。
  final bool cancelled;

  /// 失败原因（诊断用，最多留前若干条）。
  final List<String> failures;

  int get processed => filled + skipped + failed;
}

/// 失败原因最多留几条（诊断够用，不让超大牌组撑爆内存）。
const int kSrsWordAudioBackfillMaxFailureNotes = 20;

/// 单词音频字段的写入值：与制卡同形（`{audio}` → `[sound:<存储名>]`）。
String srsWordAudioFieldValue(String mediaName) => '[sound:$mediaName]';

/// 逐张串行补全 [items]。每处理完一张调一次 [onProgress]（已处理数, 总数）。
/// [isCancelled] 在每张开始前检查：为真就停，已写入的保留，结果带 `cancelled`。
Future<SrsWordAudioBackfillResult> runSrsWordAudioBackfill(
  List<SrsWordAudioBackfillItem> items,
  SrsWordAudioBackfillDeps deps, {
  void Function(int processed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  int filled = 0;
  int skipped = 0;
  int failed = 0;
  final List<String> failures = <String>[];
  void fail(SrsWordAudioBackfillItem item, String reason) {
    failed++;
    if (failures.length < kSrsWordAudioBackfillMaxFailureNotes) {
      failures.add('${item.term}: $reason');
    }
  }

  for (final SrsWordAudioBackfillItem item in items) {
    if (isCancelled?.call() ?? false) {
      return SrsWordAudioBackfillResult(
        total: items.length,
        filled: filled,
        skipped: skipped,
        failed: failed,
        cancelled: true,
        failures: failures,
      );
    }
    if (item.term.isEmpty) {
      skipped++;
    } else {
      try {
        switch (await deps.fetch(item.term, item.reading)) {
          case SrsWordAudioNotFound():
            skipped++;
          case SrsWordAudioFetchFailed(:final String reason):
            fail(item, reason);
          case SrsWordAudioStored(:final String mediaName):
            await deps.write(item.noteId, srsWordAudioFieldValue(mediaName));
            filled++;
        }
      } catch (e) {
        fail(item, '$e');
      }
    }
    onProgress?.call(filled + skipped + failed, items.length);
  }
  return SrsWordAudioBackfillResult(
    total: items.length,
    filled: filled,
    skipped: skipped,
    failed: failed,
    cancelled: false,
    failures: failures,
  );
}
