/// 复习历史捐赠（给 anki-rwkv 训练调度模型）：预览、导出捐赠包、捐赠身份。
///
/// 设计见 docs/specs/2026-11-26-srs-review-donation.md。捐赠包复用 [exportAnkiPackageFile]
/// 的导出器，只多传一个 [SrsApkgRedaction]（不复制导出器）；词头 / 读音保留规则只写在
/// [srsDonationWordFieldsOf] + [srsDonationHeadwordOf] 这一处，预览与导出共用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_store_background.dart';

/// `fushi_donation_meta.format`。
const String srsDonationFormat = 'fushi-srs-donation';

/// `fushi_donation_meta.version`。
const int srsDonationVersion = 1;

/// 一条会保留词头的笔记（预览词表的一行）。
class SrsDonationWord {
  const SrsDonationWord({
    required this.noteId,
    required this.headword,
    this.reading,
  });

  final String noteId;
  final String headword;
  final String? reading;
}

/// 捐赠包预览：将进包的数量与会保留的词。
class SrsDonationPreview {
  const SrsDonationPreview({
    required this.reviewCount,
    required this.cardCount,
    required this.noteCount,
    required this.firstReviewAt,
    required this.words,
  });

  /// 将进包的 revlog 条数（有效的 [SrsLogKind.review] 日志）。
  final int reviewCount;

  /// 至少有一条复习日志的卡片数（同笔记里没复习过的兄弟卡也会进包，不计在内）。
  final int cardCount;

  /// 进包的笔记数。
  final int noteCount;

  /// 最早一次复习；没有复习时 null。
  final DateTime? firstReviewAt;

  /// 会保留词头的笔记，按词头（再按笔记 ID）排序。
  final List<SrsDonationWord> words;
}

/// 一种笔记类型里算词头 / 读音的字段（fieldId；没有就是 null）。
typedef SrsDonationWordFields = ({
  String? headwordFieldId,
  String? readingFieldId,
});

/// 词头字段名白名单（去空格、小写后比较）。
const List<String> _headwordNames = <String>[
  'expression',
  'word',
  'vocab',
  'vocabulary',
  'kanji',
  'term',
  'headword',
  'japanese',
  '単語',
  '語彙',
  '言葉',
  '漢字',
  '表記',
];

/// 读音字段名白名单（去空格、小写后比较）。
const List<String> _readingNames = <String>[
  'reading',
  'kana',
  'hiragana',
  'expressionreading',
  'wordreading',
  'vocabreading',
  'vocabkana',
  '読み',
  '読み方',
  'かな',
  '仮名',
];

String _normalizeFieldName(String name) =>
    name.replaceAll(RegExp(r'\s+', unicode: true), '').toLowerCase();

/// 笔记类型 [noteTypeId]（内置时 [builtinKey] 非 null）里哪个字段算词头、哪个算读音。
///
/// 内置 Lapis：`Expression` / `ExpressionReading`；内置 Fushi 卡片：[FushiCardFields.term] /
/// [FushiCardFields.termReading]（按字段 ID 认，不受改名影响）。其他类型按字段名白名单，
/// 每类取 [fields] 顺序里第一个命中的。
SrsDonationWordFields srsDonationWordFieldsOf({
  required String noteTypeId,
  required String? builtinKey,
  required List<SrsFieldDef> fields,
}) {
  final SrsBuiltinNoteTypeSpec? spec = srsBuiltinNoteTypeSpec(builtinKey);
  if (spec != null) {
    final Map<String, String> idOf = <String, String>{
      for (final SrsFieldDef f in srsBuiltinNoteTypeIn(noteTypeId, spec).fields)
        f.name: f.id,
    };
    final bool fushi = spec.key == kSrsBuiltinFushiCardKey;
    final String? hw = idOf[fushi ? FushiCardFields.term : 'Expression'];
    final String? rd =
        idOf[fushi ? FushiCardFields.termReading : 'ExpressionReading'];
    final Set<String> present = <String>{
      for (final SrsFieldDef f in fields) f.id,
    };
    return (
      headwordFieldId: present.contains(hw) ? hw : null,
      readingFieldId: present.contains(rd) ? rd : null,
    );
  }
  String? hw;
  String? rd;
  for (final SrsFieldDef f in fields) {
    final String n = _normalizeFieldName(f.name);
    if (hw == null && _headwordNames.contains(n)) {
      hw = f.id;
    } else if (rd == null && _readingNames.contains(n)) {
      rd = f.id;
    }
  }
  return (headwordFieldId: hw, readingFieldId: rd);
}

// 平假名 / 片假名（含ヶ）/ 汉字（CJK 统一表意文字及扩展、兼容表意文字）/ ー々〆。
final RegExp _headwordValue = RegExp(
  r'^[ぁ-ゖァ-ヺー々〆㐀-䶿一-鿿'
  r'豈-﫿\u{20000}-\u{3134F}]{1,15}$',
  unicode: true,
);

// 只有假名与ー。
final RegExp _readingValue = RegExp(r'^[ぁ-ゖァ-ヺー]{1,15}$', unicode: true);

/// 捐赠包里保留的词头 / 读音值（不通过校验的是 null，对应字段写空串）。
///
/// 值先去 HTML（[ankiStripHtml]）再 trim；词头 1–15 个字符且全为平假名 / 片假名 / 汉字 / `ー々〆ヶ`，
/// 读音同样长度且只含假名与 `ー`；空格、标点、拉丁字母、数字、括号（`漢字[かんじ]`）一律不通过。
/// 读音单独不通过不影响词头；词头不通过时读音也不留（没有词头的读音对训练没有意义）。
({String? headword, String? reading}) srsDonationHeadwordOf({
  required SrsDonationWordFields fields,
  required String Function(String fieldId) valueOf,
}) {
  final String? hwId = fields.headwordFieldId;
  if (hwId == null) return (headword: null, reading: null);
  final String hw = ankiStripHtml(valueOf(hwId)).trim();
  if (!_headwordValue.hasMatch(hw)) return (headword: null, reading: null);
  final String? rdId = fields.readingFieldId;
  final String? rd = rdId == null ? null : ankiStripHtml(valueOf(rdId)).trim();
  return (
    headword: hw,
    reading: rd != null && _readingValue.hasMatch(rd) ? rd : null,
  );
}

/// 捐赠身份：`donorId` = sha256("fushi-srs-donation-id:" + uid) 前 32 位十六进制，
/// `donorKey` = sha256("fushi-srs-donation-key:" + uid) 全 64 位（上传 / 查询 / 撤回的 Bearer 凭据）。
({String donorId, String donorKey}) srsDonationIdentity(String profileUid) => (
  donorId: sha256
      .convert(utf8.encode('fushi-srs-donation-id:$profileUid'))
      .toString()
      .substring(0, 32),
  donorKey: sha256
      .convert(utf8.encode('fushi-srs-donation-key:$profileUid'))
      .toString(),
);

/// 按类型缓存词头 / 读音字段（同一类型的笔记很多）。
class _WordFieldsCache {
  final Map<String, SrsDonationWordFields> _byType =
      <String, SrsDonationWordFields>{};

  SrsDonationWordFields of(SrsNoteTypeView t) =>
      _byType[t.id] ??= srsDonationWordFieldsOf(
        noteTypeId: t.id,
        builtinKey: t.builtinKey,
        fields: t.fields,
      );
}

/// 预览：数一遍将进包的复习 / 卡片 / 笔记，列出会保留词头的笔记（不看排除集合：词表就是给用户逐词排除用的）。
///
/// 范围判据与导出器一致（srs_apkg_export.dart `_Exporter.run` 带 [SrsApkgRedaction] 时）：当前 profile 全部
/// 牌组、不可见卡不算、已删笔记 / 类型不在的笔记不算、模板已删的卡不算；有效日志里的 [SrsLogKind.review] 才算复习。
Future<SrsDonationPreview> previewSrsDonation({
  required SrsDbStore store,
}) async {
  final List<SrsCardCacheRow> all = await store.cardRowsWhere(
    const <String, Object?>{},
  );
  final Map<String, List<SrsCardCacheRow>> cardsOf =
      <String, List<SrsCardCacheRow>>{};
  for (final SrsCardCacheRow c in all) {
    if (!c.hidden) (cardsOf[c.noteId] ??= <SrsCardCacheRow>[]).add(c);
  }
  final List<SrsNoteView> notes = <SrsNoteView>[
    for (final SrsNoteView? n in (await store.notes(cardsOf.keys)).values)
      if (n != null && n.deletedAt == null) n,
  ];
  final Map<String, SrsCardHistory> histories = await store.histories(<String>[
    for (final SrsNoteView n in notes)
      for (final SrsCardCacheRow c in cardsOf[n.id]!) c.id,
  ]);
  final Map<String, SrsNoteTypeView?> types = <String, SrsNoteTypeView?>{};
  final _WordFieldsCache wordFields = _WordFieldsCache();
  int reviews = 0;
  int cards = 0;
  int noteCount = 0;
  int? first;
  final List<SrsDonationWord> words = <SrsDonationWord>[];
  for (final SrsNoteView n in notes) {
    final SrsNoteTypeView? t = types.containsKey(n.noteTypeId)
        ? types[n.noteTypeId]
        : (types[n.noteTypeId] = await store.noteType(n.noteTypeId));
    if (t == null) continue;
    int noteReviews = 0;
    for (final SrsCardCacheRow c in cardsOf[n.id]!) {
      if (!t.templates.any((SrsTemplateDef x) => x.id == c.templateId)) {
        continue;
      }
      int cardReviews = 0;
      for (final SrsReviewLog l in histories[c.id]!.effective) {
        if (l.kind != SrsLogKind.review) continue;
        cardReviews++;
        if (first == null || l.occurredAt < first) first = l.occurredAt;
      }
      if (cardReviews > 0) cards++;
      noteReviews += cardReviews;
    }
    if (noteReviews == 0) continue;
    reviews += noteReviews;
    noteCount++;
    final ({String? headword, String? reading}) w = srsDonationHeadwordOf(
      fields: wordFields.of(t),
      valueOf: n.field,
    );
    if (w.headword != null) {
      words.add(
        SrsDonationWord(
          noteId: n.id,
          headword: w.headword!,
          reading: w.reading,
        ),
      );
    }
  }
  words.sort((SrsDonationWord a, SrsDonationWord b) {
    final int c = a.headword.compareTo(b.headword);
    return c != 0 ? c : a.noteId.compareTo(b.noteId);
  });
  return SrsDonationPreview(
    reviewCount: reviews,
    cardCount: cards,
    noteCount: noteCount,
    firstReviewAt: first == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(first, isUtc: true),
    words: words,
  );
}

/// 同 [exportSrsDonationFile]，整个导出在一次性后台 isolate 里跑（[srsRunWithStoreInBackground]），UI isolate
/// 只等结果。产品代码一律走这里。
Future<void> exportSrsDonationFileInBackground({
  required SrsDbStore store,
  required File file,
  required String donorId,
  required String appVersion,
  bool includeWords = true,
  Set<String> excludedNoteIds = const <String>{},
}) => srsRunWithStoreInBackground<void>(
  store,
  _donationInBackground(
    file.path,
    donorId,
    appVersion,
    includeWords,
    Set<String>.of(excludedNoteIds),
  ),
  debugName: 'srs-donation-export',
);

/// [exportSrsDonationFileInBackground] 的后台一半（顶层函数：闭包只捕获可发送的值）。
Future<void> Function(SrsDbStore) _donationInBackground(
  String path,
  String donorId,
  String appVersion,
  bool includeWords,
  Set<String> excludedNoteIds,
) =>
    (SrsDbStore store) => exportSrsDonationFile(
      store: store,
      file: File(path),
      donorId: donorId,
      appVersion: appVersion,
      includeWords: includeWords,
      excludedNoteIds: excludedNoteIds,
    );

/// 导出捐赠包到 [file]（Anki 兼容 .apkg：schema-11 集合 + 空媒体清单，不带 fushi-ext）。
///
/// [includeWords] 为 false 时连词头 / 读音也清空；[excludedNoteIds] 里的笔记同样清空（笔记与复习照常进包）。
/// 先写 `<file>.part` 成功后改名（同 [exportAnkiPackageFile]）。
Future<void> exportSrsDonationFile({
  required SrsDbStore store,
  required File file,
  required String donorId,
  required String appVersion,
  bool includeWords = true,
  Set<String> excludedNoteIds = const <String>{},
}) {
  final _WordFieldsCache wordFields = _WordFieldsCache();
  return exportAnkiPackageFile(
    store: store,
    file: file,
    // 学习进度与预设 id 要带（cards / revlog / 牌组预设 id）；fushi-ext 不带。
    options: const SrsAnkiExportOptions(ankiCompatible: true),
    redaction: SrsApkgRedaction(
      fieldNames: (SrsNoteTypeView t) {
        final SrsDonationWordFields w = wordFields.of(t);
        return <String>[
          for (final (int i, SrsFieldDef f) in t.fields.indexed)
            f.id == w.headwordFieldId
                ? 'Headword'
                : f.id == w.readingFieldId
                ? 'Reading'
                : 'Field ${i + 1}',
        ];
      },
      fieldValues: (SrsNoteView n, SrsNoteTypeView t) {
        final ({String? headword, String? reading}) w =
            includeWords && !excludedNoteIds.contains(n.id)
            ? srsDonationHeadwordOf(fields: wordFields.of(t), valueOf: n.field)
            : (headword: null, reading: null);
        final SrsDonationWordFields ids = wordFields.of(t);
        return <String>[
          for (final SrsFieldDef f in t.fields)
            f.id == ids.headwordFieldId
                ? (w.headword ?? '')
                : f.id == ids.readingFieldId
                ? (w.reading ?? '')
                : '',
        ];
      },
      meta: (SrsDayContext day, int nowMs) => <String, String>{
        'format': srsDonationFormat,
        'version': '$srsDonationVersion',
        'donor_id': donorId,
        'exported_at': '$nowMs',
        'app_version': appVersion,
        'scheduler': 'fushi-fsrs',
        'utc_offset_min': '${day.utcOffsetMin}',
        'rollover_hour': '${day.rolloverHour}',
      },
    ),
  );
}
