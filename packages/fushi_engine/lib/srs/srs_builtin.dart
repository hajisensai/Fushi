/// 内置笔记类型 Lapis 与内置默认牌组（铁律 C；第六轮审查第 8 条）。
///
/// Lapis 的字段键、模板正文与 CSS 只从 packages/fushi_anki 的 LapisNoteType 取，不在这里复制一份。
/// 内置定义走通用 ID 规则（固定 ankiNum），用户没改过的项不写修改记录、跟随代码。
library;

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

const String kSrsBuiltinLapisKey = 'lapis';
const String kSrsBuiltinDefaultDeckKey = 'default';

/// 某 profile 的内置 Lapis 笔记类型 ID。
String srsLapisNoteTypeId(String profileUid) => SrsIds.noteType(
  profileUid,
  SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey),
);

/// Lapis 字段键 → fieldId。
String srsLapisFieldId(String profileUid, String fieldKey) => SrsIds.field(
  srsLapisNoteTypeId(profileUid),
  SrsIds.builtinFieldAnkiNum(kSrsBuiltinLapisKey, fieldKey),
);

/// 某 profile 的内置 Lapis 定义（代码默认值）。
SrsBuiltinNoteType srsBuiltinLapis(String profileUid) {
  final String nt = srsLapisNoteTypeId(profileUid);
  final Map<String, String> nameToId = <String, String>{
    for (final String key in LapisNoteType.fields)
      key: srsLapisFieldId(profileUid, key),
  };
  final int tplNum = SrsIds.builtinTemplateAnkiNum(
    kSrsBuiltinLapisKey,
    LapisNoteType.cardName,
  );
  return SrsBuiltinNoteType(
    key: kSrsBuiltinLapisKey,
    name: LapisNoteType.modelName,
    kind: SrsNoteTypeKind.standard,
    fields: <SrsFieldDef>[
      for (int i = 0; i < LapisNoteType.fields.length; i++)
        SrsFieldDef(
          id: nameToId[LapisNoteType.fields[i]]!,
          name: LapisNoteType.fields[i],
          ord: i,
          ankiNum: SrsIds.builtinFieldAnkiNum(
            kSrsBuiltinLapisKey,
            LapisNoteType.fields[i],
          ),
        ),
    ],
    templates: <SrsTemplateDef>[
      SrsTemplateDef(
        id: SrsIds.template(nt, tplNum),
        name: LapisNoteType.cardName,
        ord: 0,
        front: templateNamesToIds(LapisNoteType.template.front, nameToId),
        back: templateNamesToIds(LapisNoteType.template.back, nameToId),
        ankiNum: tplNum,
      ),
    ],
    css: LapisNoteType.template.css,
    termFieldId: nameToId['Expression'],
  );
}

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
      SrsEntityRecord(
        id: srsLapisNoteTypeId(profileUid),
        profileUid: profileUid,
        kind: SrsEntityKind.noteType,
        payload: <String, Object?>{
          'ankiNum': SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey),
          'ntKind': SrsNoteTypeKind.standard,
          'builtin': kSrsBuiltinLapisKey,
        },
      ),
    ];
