import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';

/// 一次 `isIn` 的上限（SQLite 变量数上限 999 以内）。
const int kWebKnownWordQueryChunk = 400;

/// 一个词所有卡片的状态归并：有一张未暂停的卡还在学（新 / 学习 / 重学）= 学习中；
/// 否则（全部复习中或已暂停）= 已知。空列表不该出现，按生词处理。
WebKnownWordStatus webKnownWordStatusOf(
  Iterable<({SrsQueue queue, bool suspended})> cards,
) {
  bool any = false;
  for (final ({SrsQueue queue, bool suspended}) c in cards) {
    any = true;
    if (!c.suspended && c.queue != SrsQueue.review) {
      return WebKnownWordStatus.learning;
    }
  }
  return any ? WebKnownWordStatus.known : WebKnownWordStatus.unknown;
}

/// 整批查已知词状态（按表层形归一化后的 termKey，与复习「词状态」同一个键）。
///
/// 与 [SrsDbStore.lookupTermStatus] 同源（srs.db 的笔记缓存 `term_key` + 卡片缓存），
/// 但那个入口每个词两条查询；整页一批几百个词时这里只做「笔记一条 + 卡片一条」
/// （按 [kWebKnownWordQueryChunk] 分块）。读音不参与：分词器给的是词典首条读音，
/// 拿它精确匹配会把同形异读的已知词判成生词。
///
/// 已知局限：分词器只回表层形，活用形（`食べた`）对不上词典形卡片（`食べる`），
/// 会被当成生词——要根治需要原生分词同时回传词条原形。
Future<Map<String, WebKnownWordStatus>> lookupWebKnownWords(
  SrsDbStore store,
  Set<String> surfaces,
) async {
  final Map<String, List<String>> surfacesByKey = <String, List<String>>{};
  for (final String s in surfaces) {
    final String key = srsTermKey(s);
    if (key.isEmpty) continue;
    (surfacesByKey[key] ??= <String>[]).add(s);
  }
  if (surfacesByKey.isEmpty) return const <String, WebKnownWordStatus>{};
  final SrsDatabase db = store.db;
  final Map<String, String> keyByNote = <String, String>{};
  final List<String> keys = surfacesByKey.keys.toList();
  for (int i = 0; i < keys.length; i += kWebKnownWordQueryChunk) {
    final List<String> chunk = keys.sublist(
      i,
      (i + kWebKnownWordQueryChunk).clamp(0, keys.length),
    );
    final List<SrsNoteCacheRow> notes =
        await (db.select(db.srsNotesCache)..where(
              (n) =>
                  n.profileUid.equals(store.profileUid) &
                  n.termKey.isIn(chunk) &
                  n.deletedAt.isNull(),
            ))
            .get();
    for (final SrsNoteCacheRow n in notes) {
      keyByNote[n.id] = n.termKey;
    }
  }
  final Map<String, List<({SrsQueue queue, bool suspended})>> cardsByKey =
      <String, List<({SrsQueue queue, bool suspended})>>{};
  final List<String> noteIds = keyByNote.keys.toList();
  for (int i = 0; i < noteIds.length; i += kWebKnownWordQueryChunk) {
    final List<String> chunk = noteIds.sublist(
      i,
      (i + kWebKnownWordQueryChunk).clamp(0, noteIds.length),
    );
    final List<SrsCardCacheRow> cards = await (db.select(
      db.srsCardsCache,
    )..where((c) => c.noteId.isIn(chunk) & c.hidden.equals(false))).get();
    for (final SrsCardCacheRow c in cards) {
      final String? key = keyByNote[c.noteId];
      if (key == null) continue;
      (cardsByKey[key] ??= <({SrsQueue queue, bool suspended})>[]).add((
        queue: SrsQueue.parse(c.queue),
        suspended: c.suspended,
      ));
    }
  }
  final Map<String, WebKnownWordStatus> out = <String, WebKnownWordStatus>{};
  cardsByKey.forEach((
    String key,
    List<({SrsQueue queue, bool suspended})> cards,
  ) {
    final WebKnownWordStatus status = webKnownWordStatusOf(cards);
    for (final String s in surfacesByKey[key]!) {
      out[s] = status;
    }
  });
  return out;
}
