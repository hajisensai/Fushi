/// 内置笔记类型（Lapis、Fushi 卡片）与内置默认牌组（铁律 C；第六轮审查第 8 条）。
///
/// 字段键、模板正文与 CSS 只从 packages/fushi_anki 的 [LapisNoteType] / [FushiCardNoteType]
/// 取，不在这里复制一份。内置定义走通用 ID 规则（固定 ankiNum），用户没改过的项不写修改记录、
/// 跟随代码。两种内置类型的字段键相同（Fushi 卡片 = Lapis 字段 + SentenceTranslation），但
/// ankiNum 按各自的 key 派生，fieldId 互不相同。
library;

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

const String kSrsBuiltinLapisKey = 'lapis';
const String kSrsBuiltinFushiCardKey = 'fushi_card';
const String kSrsBuiltinDefaultDeckKey = 'default';

/// 一种内置笔记类型的代码定义来源。
class SrsBuiltinNoteTypeSpec {
  const SrsBuiltinNoteTypeSpec({
    required this.key,
    required this.template,
    required this.defaultFieldMappings,
  });

  /// 持久化名（身份记录 payload 的 `builtin`），冻结。
  final String key;
  final AnkiNoteTypeTemplate template;

  /// 字段键 → 制卡占位符（挖词按字段键定位，不受改名影响）。
  final Map<String, String> defaultFieldMappings;
}

/// 全部内置笔记类型（顺序 = 播种顺序）。
const List<SrsBuiltinNoteTypeSpec> kSrsBuiltinNoteTypes =
    <SrsBuiltinNoteTypeSpec>[
      SrsBuiltinNoteTypeSpec(
        key: kSrsBuiltinLapisKey,
        template: LapisNoteType.template,
        defaultFieldMappings: LapisNoteType.defaultFieldMappings,
      ),
      SrsBuiltinNoteTypeSpec(
        key: kSrsBuiltinFushiCardKey,
        template: FushiCardNoteType.template,
        defaultFieldMappings: FushiCardNoteType.defaultFieldMappings,
      ),
    ];

/// [key] 对应的内置定义；不是内置 key 时返回 null。
SrsBuiltinNoteTypeSpec? srsBuiltinNoteTypeSpec(String? key) {
  for (final SrsBuiltinNoteTypeSpec s in kSrsBuiltinNoteTypes) {
    if (s.key == key) return s;
  }
  return null;
}

/// 某 profile 的内置笔记类型 ID。
String srsBuiltinNoteTypeId(String profileUid, String key) =>
    SrsIds.noteType(profileUid, SrsIds.builtinNoteTypeAnkiNum(key));

/// 内置字段 ID / ankiNum 的派生种子。Fushi 卡片 2026-10-29 给 9 个字段改了名
/// （[FushiCardFields]），ID 仍按**旧名**派生：旧卡的字段值、同步日志、词状态零迁移。
/// 新增字段（改名之后才有的）没有旧名，种子就是自己的名字。
String srsBuiltinFieldSeed(String key, String fieldKey) =>
    key == kSrsBuiltinFushiCardKey
    ? FushiCardFields.legacyNameOf(fieldKey)
    : fieldKey;

/// 内置笔记类型的字段键 → fieldId。
String srsBuiltinFieldId(String profileUid, String key, String fieldKey) =>
    SrsIds.field(
      srsBuiltinNoteTypeId(profileUid, key),
      SrsIds.builtinFieldAnkiNum(key, srsBuiltinFieldSeed(key, fieldKey)),
    );

/// 某 profile 的内置 Lapis 笔记类型 ID。
String srsLapisNoteTypeId(String profileUid) =>
    srsBuiltinNoteTypeId(profileUid, kSrsBuiltinLapisKey);

/// Lapis 字段键 → fieldId。
String srsLapisFieldId(String profileUid, String fieldKey) =>
    srsBuiltinFieldId(profileUid, kSrsBuiltinLapisKey, fieldKey);

/// 某 profile 的内置 Fushi 卡片笔记类型 ID。
String srsFushiCardNoteTypeId(String profileUid) =>
    srsBuiltinNoteTypeId(profileUid, kSrsBuiltinFushiCardKey);

/// Fushi 卡片字段键 → fieldId。
String srsFushiCardFieldId(String profileUid, String fieldKey) =>
    srsBuiltinFieldId(profileUid, kSrsBuiltinFushiCardKey, fieldKey);

/// 某 profile 的某个内置笔记类型定义（代码默认值）。
SrsBuiltinNoteType srsBuiltinNoteType(
  String profileUid,
  SrsBuiltinNoteTypeSpec spec,
) {
  final String key = spec.key;
  final AnkiNoteTypeTemplate tpl = spec.template;
  final String nt = srsBuiltinNoteTypeId(profileUid, key);
  final Map<String, String> nameToId = <String, String>{
    for (final String f in tpl.fields) f: srsBuiltinFieldId(profileUid, key, f),
  };
  final int tplNum = SrsIds.builtinTemplateAnkiNum(key, tpl.cardName);
  return SrsBuiltinNoteType(
    key: key,
    name: tpl.name,
    kind: SrsNoteTypeKind.standard,
    fields: <SrsFieldDef>[
      for (int i = 0; i < tpl.fields.length; i++)
        SrsFieldDef(
          id: nameToId[tpl.fields[i]]!,
          name: tpl.fields[i],
          ord: i,
          ankiNum: SrsIds.builtinFieldAnkiNum(
            key,
            srsBuiltinFieldSeed(key, tpl.fields[i]),
          ),
        ),
    ],
    templates: <SrsTemplateDef>[
      SrsTemplateDef(
        id: SrsIds.template(nt, tplNum),
        name: tpl.cardName,
        ord: 0,
        front: templateNamesToIds(tpl.front, nameToId),
        back: templateNamesToIds(tpl.back, nameToId),
        ankiNum: tplNum,
      ),
    ],
    css: tpl.css,
    termFieldId: nameToId['Expression'] ?? nameToId[FushiCardFields.term],
    freqFieldId:
        nameToId['FreqSort'] ?? nameToId[FushiCardFields.frequencyRank],
  );
}

/// [key] 的内置定义；不是内置 key 时返回 null。
SrsBuiltinNoteType? srsBuiltinNoteTypeForKey(String profileUid, String? key) {
  final SrsBuiltinNoteTypeSpec? spec = srsBuiltinNoteTypeSpec(key);
  return spec == null ? null : srsBuiltinNoteType(profileUid, spec);
}

/// 某 profile 的内置 Lapis 定义（代码默认值）。
SrsBuiltinNoteType srsBuiltinLapis(String profileUid) =>
    srsBuiltinNoteType(profileUid, kSrsBuiltinNoteTypes.first);

/// 某 profile 的内置 Fushi 卡片定义（代码默认值）。
SrsBuiltinNoteType srsBuiltinFushiCard(String profileUid) =>
    srsBuiltinNoteTypeForKey(profileUid, kSrsBuiltinFushiCardKey)!;

/// 内置类型的读音字段（词状态的 readingKey 来源）；不是内置类型时返回 null。
String? srsBuiltinReadingFieldId(String profileUid, String? key) =>
    srsBuiltinNoteTypeSpec(key) == null
    ? null
    : srsBuiltinFieldId(
        profileUid,
        key!,
        key == kSrsBuiltinFushiCardKey
            ? FushiCardFields.termReading
            : 'ExpressionReading',
      );

/// Lapis 的读音字段（词状态的 readingKey 来源）。
String srsLapisReadingFieldId(String profileUid) =>
    srsLapisFieldId(profileUid, 'ExpressionReading');

/// 内置身份记录（每台设备都会确定性地生成同一份，合并后是同一行）。
List<SrsEntityRecord> srsBuiltinEntities(String profileUid) =>
    <SrsEntityRecord>[
      SrsEntityRecord(
        id: SrsIds.builtinDefaultDeck(profileUid),
        profileUid: profileUid,
        kind: SrsEntityKind.deck,
        payload: const <String, Object?>{'builtin': kSrsBuiltinDefaultDeckKey},
      ),
      for (final SrsBuiltinNoteTypeSpec spec in kSrsBuiltinNoteTypes)
        SrsEntityRecord(
          id: srsBuiltinNoteTypeId(profileUid, spec.key),
          profileUid: profileUid,
          kind: SrsEntityKind.noteType,
          payload: <String, Object?>{
            'ankiNum': SrsIds.builtinNoteTypeAnkiNum(spec.key),
            'ntKind': SrsNoteTypeKind.standard,
            'builtin': spec.key,
          },
        ),
    ];
