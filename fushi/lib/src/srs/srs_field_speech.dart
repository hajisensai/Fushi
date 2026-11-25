/// 笔记编辑器里「用 TTS 生成」音频的取字口径：一个音频字段该念哪个文字字段、念什么字。
///
/// 只服务用户在编辑器里**主动点按钮**生成音频；制卡时句子音频仍不做 TTS 兜底
/// （BUG-172：自动塞 TTS 会掩盖真实旁白抽段失败）。
library;

import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;

import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities;
import 'package:fushi/src/srs/srs_sound_tag.dart' show srsSoundTagPattern;

/// 音频字段 [audioFieldName] 的朗读来源字段名（按优先级，取第一个非空的）；
/// 空表 = 这个音频字段没有已知的文字来源，不提供 TTS。
///
/// 按字段名匹配（旧 Lapis 名经 [FushiCardFields.canonical] 认成新名），不限于内置
/// 笔记类型：从 Anki 导入的 Lapis 牌组同样适用。单词音频优先念读音、没有读音才念
/// 词头，与制卡单词音频兜底同一口径（`wordAudioTtsText`）。
List<String> srsSpeechSourceFieldNames(String audioFieldName) =>
    switch (FushiCardFields.canonical(audioFieldName)) {
      FushiCardFields.termAudio => const <String>[
        FushiCardFields.termReading,
        FushiCardFields.term,
      ],
      'SentenceAudio' => const <String>['Sentence'],
      _ => const <String>[],
    };

/// [srsSpeechSourceFieldNames] 里的一个名字是否指 [fieldName]（新旧名都认）。
bool srsIsSpeechSourceField(String sourceName, String fieldName) =>
    FushiCardFields.canonical(fieldName) == sourceName;

final RegExp _rubyAnnotation = RegExp(
  r'<(rt|rp)\b[^>]*>.*?</\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _tag = RegExp(r'<[^>]+>');
final RegExp _whitespace = RegExp(r'\s+');

/// 字段 HTML 里要念出来的文字：去掉注音（`<rt>` / `<rp>` 内容，否则读音会被再念一遍）、
/// `[sound:]` 与全部标签，解实体，空白收成单个空格。
String srsSpeechText(String html) => srsDecodeEntities(
  html
      .replaceAll(_rubyAnnotation, '')
      .replaceAll(srsSoundTagPattern, '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(_tag, ''),
).replaceAll(_whitespace, ' ').trim();

/// 编辑页按 [srsSpeechSourceFieldNames] 的优先级，从笔记的 [fields]（字段名 → 值）里
/// 挑出音频字段 [audioFieldName] 的朗读来源。没有来源返回空表。
List<T> srsSpeechSourcesOf<T>(
  String audioFieldName,
  Iterable<({String name, T value})> fields,
) => <T>[
  for (final String source in srsSpeechSourceFieldNames(audioFieldName))
    for (final ({String name, T value}) f in fields)
      if (srsIsSpeechSourceField(source, f.name)) f.value,
];
