// Fushi 卡片区块布局的 app 侧判据：自定义区块（字段 / HTML 区块）原生画不画得了、卡面计划
// 按区块选项取媒体（新加模板的起点见 srs_template_presets_test.dart）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_fushi_card_items.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;

Map<String, String> _fields([Map<String, String> extra = const {}]) =>
    <String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      'Term': '通う',
      'TermReading': 'かよう',
      'Sentence': '学校に<b>通う</b>。',
      'TermAudio': '[sound:w.mp3]',
      'SentenceAudio': '[sound:s.mp3]',
      ...extra,
    };

void main() {
  group('自定义区块原生判据', () {
    test('原生 HTML 子集画得了的放行；脚本 / 表格 / 定位让整张卡回退', () {
      List<FushiCardItem> back(String html) => <FushiCardItem>[
        ...kFushiCardDefaultBackItems,
        FushiCardHtmlItem(html),
      ];
      expect(
        srsFushiCardItemsNative(
          front: kFushiCardDefaultFrontItems,
          back: back('<p style="color:red">自定义</p>'),
          fields: _fields(),
        ),
        isTrue,
      );
      for (final String bad in <String>[
        '<script>alert(1)</script>',
        '<table><tr><td>x</td></tr></table>',
        '<div style="position:absolute">x</div>',
      ]) {
        expect(
          srsFushiCardItemsNative(
            front: kFushiCardDefaultFrontItems,
            back: back(bad),
            fields: _fields(),
          ),
          isFalse,
          reason: bad,
        );
        expect(srsHtmlFragmentProbe(bad).reason, isNotNull, reason: bad);
      }
    });

    test('字段区块按字段值判；标签样式只取纯文字，不判', () {
      final Map<String, String> f = _fields(<String, String>{
        'MiscInfo': '<table><tr><td>x</td></tr></table>',
      });
      expect(
        srsFushiCardItemsNative(
          front: kFushiCardDefaultFrontItems,
          back: <FushiCardItem>[FushiCardFieldItem(field: 'MiscInfo')],
          fields: f,
        ),
        isFalse,
      );
      expect(
        srsFushiCardItemsNative(
          front: kFushiCardDefaultFrontItems,
          back: <FushiCardItem>[
            FushiCardFieldItem(
              field: 'MiscInfo',
              style: FushiCardFieldStyle.tag,
            ),
          ],
          fields: f,
        ),
        isTrue,
      );
    });

    test('引擎没认出布局（defs 为 null）的卡不走原生', () {
      final SrsRenderedCard r = SrsRenderedCard(
        question: '',
        answer: '',
        css: '',
        isEmpty: false,
        fields: _fields(),
      );
      expect(srsFushiCardRenderedNative(r), isFalse);
      final SrsRenderedCard ok = SrsRenderedCard(
        question: '',
        answer: '',
        css: '',
        isEmpty: false,
        fields: _fields(),
        fushiCardDefinitions: '<div></div>',
        fushiCardFront: kFushiCardDefaultFrontItems,
        fushiCardBack: kFushiCardDefaultBackItems,
      );
      expect(srsFushiCardRenderedNative(ok), isTrue);
    });
  });

  group('卡面计划按区块选项取媒体', () {
    const SrsCardAppearance a = SrsCardAppearance();
    test('默认：单词音频与例句音频都在', () {
      final SrsFushiCardPlan p = srsFushiCardPlan(_fields(), a);
      expect(p.media.word, <String>['w.mp3']);
      expect(p.media.sentence, <String>['s.mp3']);
    });

    test('读音区块关发音键 / 例句区块关发音键：对应音频不在任何播放路径里', () {
      final SrsFushiCardPlan p = srsFushiCardPlan(
        _fields(),
        a,
        back: <FushiCardItem>[
          FushiCardBlockItem(FushiCardBlock.term),
          FushiCardBlockItem(
            FushiCardBlock.reading,
            options: <String, String>{kFushiOptAudio: '0'},
          ),
          FushiCardBlockItem(
            FushiCardBlock.sentence,
            options: <String, String>{kFushiOptAudio: '0'},
          ),
        ],
      );
      expect(p.media.word, isEmpty);
      expect(p.media.sentence, isEmpty);
      expect(p.media.back, isEmpty);
    });

    test('正面删掉题面：听力卡正面没有发音键', () {
      final Map<String, String> f = _fields(<String, String>{
        'IsAudioCard': 'x',
      });
      expect(srsFushiCardPlan(f, a).media.front, <String>['s.mp3']);
      expect(
        srsFushiCardPlan(
          f,
          a,
          front: <FushiCardItem>[FushiCardBlockItem(FushiCardFrontBlock.hint)],
        ).media.front,
        isEmpty,
      );
    });

    test('字段区块随字段有无显隐；HTML 区块随内容有无显隐', () {
      final SrsFushiCardPlan p = srsFushiCardPlan(
        _fields(<String, String>{'MiscInfo': 'x'}),
        a,
        back: <FushiCardItem>[
          FushiCardFieldItem(field: 'MiscInfo'),
          FushiCardFieldItem(field: 'Hint'),
          const FushiCardHtmlItem('  '),
          const FushiCardHtmlItem('<p>y</p>'),
        ],
      );
      expect(p.back, <FushiCardItem>[
        FushiCardFieldItem(field: 'MiscInfo'),
        const FushiCardHtmlItem('<p>y</p>'),
      ]);
    });
  });
}
