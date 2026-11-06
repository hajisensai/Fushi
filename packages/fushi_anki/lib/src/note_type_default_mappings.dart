import 'anki_models.dart';

/// 任意笔记类型（非 Lapis）的默认字段映射：按字段名认出常见用途，认不出的首字段兜底。
///
/// 此前选了非 Lapis 笔记类型后映射一律被置成 `{}`，用户不手动配就每张卡都是空卡、被
/// 「All fields are empty」拒收（反馈 AGLC0BuaKB，iOS 韩语用户批量制卡 2/2 失败）。
/// 判据与学习语言无关：只看字段名，别名表覆盖英文 / 中文 / 日文 / 韩文常见写法。
///
/// 规则：
/// 1. 字段名（去掉空白、下划线、连字符后小写）命中别名表 → 对应标记；同一标记只给第一个
///    命中的字段，避免两个字段灌进同一份内容。
/// 2. 首字段仍未映射 → `{expression}`（Anki 只看首字段判空，首字段必须有内容）。
/// 3. 全表还没有释义，且第二个字段未映射 → `{glossary}`（Basic 的 Front/Back 形态）。
Map<String, String> noteTypeDefaultMappings(AnkiNoteType noteType) {
  final Map<String, String> out = <String, String>{};
  final Set<String> used = <String>{};
  for (final String field in noteType.fields) {
    final String? marker = _aliasMarkers[_normalise(field)];
    if (marker == null || used.contains(marker)) continue;
    out[field] = marker;
    used.add(marker);
  }
  if (noteType.fields.isNotEmpty && !out.containsKey(noteType.fields.first)) {
    out[noteType.fields.first] = '{expression}';
    used.add('{expression}');
  }
  if (!used.contains('{glossary}') &&
      noteType.fields.length >= 2 &&
      !out.containsKey(noteType.fields[1])) {
    out[noteType.fields[1]] = '{glossary}';
  }
  return out;
}

/// [mappings] 里有没有任何一个键是 [noteType] 的字段。都不是 = 映射属于别的笔记类型
/// 或根本是空的，渲染出来必然整张空卡。
bool mappingsCoverNoteType(
  Map<String, String> mappings,
  AnkiNoteType noteType,
) => noteType.fields.any((String f) => (mappings[f] ?? '').trim().isNotEmpty);

String _normalise(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

const Map<String, String> _aliasMarkers = <String, String>{
  // 词条
  'expression': '{expression}',
  'word': '{expression}',
  'vocab': '{expression}',
  'vocabulary': '{expression}',
  'term': '{expression}',
  'headword': '{expression}',
  'front': '{expression}',
  'target': '{expression}',
  'targetword': '{expression}',
  '单词': '{expression}',
  '單詞': '{expression}',
  '词语': '{expression}',
  '詞語': '{expression}',
  '単語': '{expression}',
  '단어': '{expression}',
  // 读音
  'reading': '{reading}',
  'expressionreading': '{reading}',
  'wordreading': '{reading}',
  'kana': '{reading}',
  'pronunciation': '{reading}',
  'pinyin': '{reading}',
  'romanization': '{reading}',
  '读音': '{reading}',
  '讀音': '{reading}',
  '読み': '{reading}',
  '발음': '{reading}',
  'furigana': '{furigana-plain}',
  'expressionfurigana': '{furigana-plain}',
  // 释义
  'meaning': '{glossary}',
  'definition': '{glossary}',
  'glossary': '{glossary}',
  'back': '{glossary}',
  'translation': '{glossary}',
  'english': '{glossary}',
  'maindefinition': '{glossary-first}',
  '释义': '{glossary}',
  '釋義': '{glossary}',
  '意思': '{glossary}',
  '意味': '{glossary}',
  '뜻': '{glossary}',
  '의미': '{glossary}',
  // 例句
  'sentence': '{sentence}',
  'example': '{sentence}',
  'examplesentence': '{sentence}',
  'context': '{sentence}',
  '例句': '{sentence}',
  '例文': '{sentence}',
  '예문': '{sentence}',
  '문장': '{sentence}',
  // 音频
  'audio': '{audio}',
  'wordaudio': '{audio}',
  'expressionaudio': '{audio}',
  'sound': '{audio}',
  'sentenceaudio': '{sentence-audio}',
  // 图片
  'picture': '{card-image}',
  'image': '{card-image}',
  'screenshot': '{card-image}',
  'photo': '{card-image}',
  '图片': '{card-image}',
  '圖片': '{card-image}',
  '画像': '{card-image}',
  '그림': '{card-image}',
  '이미지': '{card-image}',
  // 其它
  'frequency': '{frequencies}',
  'frequencies': '{frequencies}',
  'source': '{source-link}',
};
