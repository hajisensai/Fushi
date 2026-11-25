/// 新笔记的「至少生成一张非空卡」门：AnkiConnect 加卡与文本导入共用（Anki：「would make an empty question
/// on all cards」时不加）。
library;

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// [byId]（字段 id → 值）按笔记类型 [t] 能不能至少生成一张非空卡。填空题看有没有填空序号；
/// 普通笔记类型逐个模板判正面是否为空，模板解析失败按「非空」处理（与卡片生成门一致）。
bool srsNoteProducesCard(SrsNoteTypeView t, Map<String, String> byId) {
  final Map<String, String> byName = <String, String>{
    for (final SrsFieldDef f in t.fields) f.name: byId[f.id] ?? '',
  };
  if (t.isCloze) {
    return t.templates.isNotEmpty &&
        clozeOrdinalsIn(byName.values.join('\n')).isNotEmpty;
  }
  final Map<String, String> idToName = <String, String>{
    for (final SrsFieldDef f in t.fields) f.id: f.name,
  };
  for (final SrsTemplateDef tpl in t.templates) {
    try {
      if (!isAnkiCardEmpty(
        questionTemplate: templateIdsToNames(tpl.front, idToName),
        noteFields: byName,
        cardOrd: tpl.ord,
        isCloze: false,
      )) {
        return true;
      }
    } on Object {
      return true;
    }
  }
  return false;
}
