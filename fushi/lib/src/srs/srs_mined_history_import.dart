/// 把已有的制卡历史（`mined_sentences` 表）批量导入 Fushi 复习（计划 PR3a）。
///
/// - 每条历史记录变成一条 Lapis 笔记（Expression / ExpressionReading / MainDefinition /
///   Sentence / MiscInfo），归入**当前 profile** 的默认牌组；
/// - 出处按 source 转：书 = bookKey + sectionIndex + 字符偏移；视频 = 媒体身份 + 时间区间
///   （视频行里 normCharOffset / normCharLength 复用为 cue 起点 / 时长）；
/// - 去重：guid 由记录**内容**派生（制卡时刻 + 词形 + 读音），重复导入不会重复建卡，
///   同一份历史经同步到了别的设备、在那边再导入一次，也会落到同一条笔记上。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 导入结果。
class SrsMinedHistoryImportResult {
  const SrsMinedHistoryImportResult({
    required this.imported,
    required this.skipped,
  });

  /// 新建的笔记数。
  final int imported;

  /// 已导入过 / 词形为空而跳过的记录数。
  final int skipped;
}

/// Anki guid 字母表（与 fushi_srs `newNoteGuid` 同一套 base91）。
const String _guidAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#\$%&()*+,-./:;<=>?@[]^_`{|}~';

/// 一条制卡历史的确定性 guid（10 位 base91，取内容 sha1 的前 10 字节映射）。
String srsMinedSentenceGuid(MinedSentenceRow row) {
  final List<int> digest = sha1
      .convert(
        utf8.encode(
          'minedSentence:${row.createdAt}:${row.expression}:${row.reading}',
        ),
      )
      .bytes;
  return String.fromCharCodes(<int>[
    for (int i = 0; i < 10; i++)
      _guidAlphabet.codeUnitAt(digest[i] % _guidAlphabet.length),
  ]);
}

/// 一条制卡历史的出处。
SrsSourceRef srsSourceRefForMinedSentence(MinedSentenceRow row) {
  final String? title = (row.documentTitle?.trim().isEmpty ?? true)
      ? null
      : row.documentTitle!.trim();
  final String? key = (row.bookKey?.isEmpty ?? true) ? null : row.bookKey;
  if (key != null) {
    switch (row.source) {
      case 'video':
        final int start = row.normCharOffset ?? 0;
        final int? length = row.normCharLength;
        return SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: key,
          startMs: start,
          endMs: length == null ? null : start + length,
          title: title,
        );
      case 'book':
      case 'audiobook':
      case 'lyrics':
        return SrsSourceRef.book(
          bookKey: key,
          sectionIndex: row.sectionIndex ?? 0,
          charStart: row.normCharOffset ?? 0,
          charLength: row.normCharLength,
          title: title,
        );
    }
  }
  return SrsSourceRef(SrsSourceKind.manual, <String, Object?>{
    if (title != null) 'title': title,
  });
}

/// 导入 [rows]（缺省读整张 `mined_sentences` 表）到 [store] 的默认牌组。
Future<SrsMinedHistoryImportResult> importMinedSentencesIntoSrs({
  required FushiDatabase db,
  required SrsDbStore store,
  List<MinedSentenceRow>? rows,
}) async {
  final List<MinedSentenceRow> all =
      rows ??
      await (db.select(db.minedSentences)
            ..orderBy(<OrderClauseGenerator<$MinedSentencesTable>>[
              ($MinedSentencesTable t) => OrderingTerm.asc(t.createdAt),
            ]))
          .get();
  String field(String key) => srsLapisFieldId(store.profileUid, key);
  int imported = 0;
  int skipped = 0;
  for (final MinedSentenceRow row in all) {
    if (row.expression.trim().isEmpty) {
      skipped++;
      continue;
    }
    final String guid = srsMinedSentenceGuid(row);
    if (await store.noteIdByGuid(guid) != null) {
      skipped++;
      continue;
    }
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      guid: guid,
      createdAt: row.createdAt,
      fieldsById: <String, String>{
        field('Expression'): row.expression,
        field('ExpressionReading'): row.reading,
        field('MainDefinition'): row.glossary,
        field('Sentence'): row.sentence,
        field('MiscInfo'): row.documentTitle ?? '',
      },
      source: srsSourceRefForMinedSentence(row),
    );
    imported++;
  }
  return SrsMinedHistoryImportResult(imported: imported, skipped: skipped);
}
