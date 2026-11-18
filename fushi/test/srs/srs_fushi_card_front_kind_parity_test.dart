// BUG-4698 / issue #3494：Fushi 卡片四个卡型开关同时打开多个时，Anki 模板把各段叠加、
// 内置复习按优先级只取一个，同一张卡两边显示不同。
//
// 守住：对 16 种开关组合，用真实模板（kFushiCardFrontTemplate）经 Anki 渲染器渲染出的正面
// 恰好只有一种卡型，且与内置复习的 srsFushiFrontKind 判定一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// 渲染结果里每种卡型独有的标记。
const Map<SrsFushiFrontKind, String> _markers = <SrsFushiFrontKind, String>{
  SrsFushiFrontKind.sentence: 'class="fc-front-sentence">',
  SrsFushiFrontKind.wordAndSentence: 'class="fc-front-context"',
  SrsFushiFrontKind.click: 'class="fc-click"',
  SrsFushiFrontKind.audio: 'class="fc-front-audio"',
};

const List<String> _flags = <String>[
  'IsSentenceCard',
  'IsWordAndSentenceCard',
  'IsClickCard',
  'IsAudioCard',
];

Set<SrsFushiFrontKind> _renderedKinds(String html) {
  final Set<SrsFushiFrontKind> kinds = <SrsFushiFrontKind>{
    for (final MapEntry<SrsFushiFrontKind, String> e in _markers.entries)
      if (html.contains(e.value)) e.key,
  };
  // 单词卡：只有词条区、没有例句上下文。
  if (kinds.isEmpty && html.contains('class="fc-front-term"')) {
    kinds.add(SrsFushiFrontKind.word);
  }
  return kinds;
}

void main() {
  for (int mask = 0; mask < 1 << _flags.length; mask++) {
    final Map<String, String> fields = <String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      'Term': '食べる',
      'Sentence': 'ご飯を<b>食べる</b>。',
      'SentenceAudio': '[sound:s.mp3]',
      for (int i = 0; i < _flags.length; i++)
        if (mask & (1 << i) != 0) _flags[i]: 'x',
    };
    final String on = <String>[
      for (int i = 0; i < _flags.length; i++)
        if (mask & (1 << i) != 0) _flags[i],
    ].join('+');
    test('Anki 模板与内置复习对卡型开关 [${on.isEmpty ? '全关' : on}] 判定一致', () {
      final AnkiRenderedCard card = renderAnkiCard(
        questionTemplate: kFushiCardFrontTemplate,
        answerTemplate: kFushiCardBackTemplate,
        noteFields: fields,
        cardOrd: 0,
        isCloze: false,
      );
      expect(_renderedKinds(card.question), <SrsFushiFrontKind>{
        srsFushiFrontKind(fields),
      });
    });
  }
}
