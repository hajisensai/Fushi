// 复习卡面朗读键（拍板台 YmWT1x57XV）：{{tts}} 标签、没有音频的字段出朗读键、词头不按字形念。
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_card_tts.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000002';

final RegExp _soundName = RegExp(r'\[sound:([^\]]+)\]');

/// [html] 里第一个 `[sound:]` 解出来的朗读键；没有 / 不是朗读键返回 null。
SrsTtsSound? _firstTts(String html) {
  final Match? m = _soundName.firstMatch(html);
  return m == null ? null : SrsTtsSound.parse(m.group(1)!);
}

void main() {
  group('SrsTtsSound', () {
    test('名字往返：文字、语言、声音、倍速原样回来', () {
      const SrsTtsSound sound = SrsTtsSound(
        text: '散歩の途中で "偶然" <会った> & ]',
        lang: 'ja_JP',
        voices: <String>['Fushi', 'Apple_Otoya'],
        speed: 1.25,
      );
      final String name = sound.name;
      expect(name, startsWith(kSrsTtsSoundPrefix));
      expect(name, isNot(contains(']')));
      expect(name, isNot(contains('&')));
      expect(name, isNot(contains('"')));
      expect(srsIsTtsSoundName(name), isTrue);
      expect(SrsTtsSound.parse(name), sound);
    });

    test('不是朗读键 / 载荷坏了返回 null', () {
      expect(SrsTtsSound.parse('a.mp3'), isNull);
      expect(SrsTtsSound.parse('$kSrsTtsSoundPrefix!!!'), isNull);
      expect(SrsTtsSound.parse(kSrsTtsSoundPrefix), isNull);
      expect(srsIsTtsSoundName('a.mp3'), isFalse);
    });
  });

  group('srsRenderTtsTags', () {
    const Map<String, String> fields = <String, String>{
      'Expression': '偶然',
      'ExpressionReading': 'ぐうぜん',
      'Sentence': '散歩の途中で<b>偶然</b>会った。',
    };

    test('{{tts}} 的输出换成朗读键，带上 lang / voices / speed', () {
      final String out = srsRenderTtsTags(
        'A [anki:tts lang=ja_JP voices=Fushi,Bob speed=1.5]散歩の途中で<b>偶然</b>'
        '会った。[/anki:tts] B',
        fields: fields,
      );
      expect(out, startsWith('A [sound:fushi-tts:'));
      expect(out, endsWith('] B'));
      final SrsTtsSound sound = _firstTts(out)!;
      expect(sound.text, '散歩の途中で偶然会った。');
      expect(sound.lang, 'ja_JP');
      expect(sound.voices, <String>['Fushi', 'Bob']);
      expect(sound.speed, 1.5);
    });

    test('去掉注音与 [sound:]，不把读音再念一遍', () {
      final String out = srsRenderTtsTags(
        '[anki:tts lang=ja_JP]<ruby>散歩<rt>さんぽ</rt></ruby>する[sound:x.mp3]'
        '[/anki:tts]',
        fields: fields,
      );
      expect(_firstTts(out)!.text, '散歩する');
    });

    test('关掉时整段去掉，不露出原始标记', () {
      expect(
        srsRenderTtsTags(
          'A[anki:tts lang=ja_JP]偶然[/anki:tts]B',
          fields: fields,
          enabled: false,
        ),
        'AB',
      );
    });

    test('念词头（含汉字）改念读音字段', () {
      final String out = srsRenderTtsTags(
        '[anki:tts lang=ja_JP]偶然[/anki:tts]',
        fields: fields,
      );
      expect(_firstTts(out)!.text, 'ぐうぜん');
    });

    test('汉字词头读音为空：不出词头朗读（不按字形推读音）', () {
      expect(
        srsRenderTtsTags(
          'A[anki:tts lang=ja_JP]偶然[/anki:tts]B',
          fields: const <String, String>{'Term': '偶然', 'TermReading': ''},
        ),
        'AB',
      );
    });

    test('纯假名 / 拉丁字母词头读音为空照常念字形', () {
      expect(
        _firstTts(
          srsRenderTtsTags(
            '[anki:tts lang=ja_JP]あちら[/anki:tts]',
            fields: const <String, String>{'Term': 'あちら'},
          ),
        )!.text,
        'あちら',
      );
      expect(
        _firstTts(
          srsRenderTtsTags(
            '[anki:tts lang=en_US]serendipity[/anki:tts]',
            fields: const <String, String>{'Term': 'serendipity'},
          ),
        )!.text,
        'serendipity',
      );
    });

    test('文字为空的标签去掉', () {
      expect(
        srsRenderTtsTags(
          'A[anki:tts lang=ja_JP] <br> [/anki:tts]B',
          fields: fields,
        ),
        'AB',
      );
    });

    test('与渲染器的 {{tts}} 输出对得上', () {
      final AnkiRenderedCard r = renderAnkiCard(
        questionTemplate: '{{Sentence}}{{tts ja_JP voices=Fushi:Sentence}}',
        answerTemplate: '{{FrontSide}}',
        noteFields: fields,
        cardOrd: 0,
        isCloze: false,
      );
      final SrsTtsSound sound = _firstTts(
        srsRenderTtsTags(r.question, fields: fields),
      )!;
      expect(sound.text, '散歩の途中で偶然会った。');
      expect(sound.voices, <String>['Fushi']);
    });
  });

  group('srsFillTtsAudioFields', () {
    test('空的例句音频填朗读键（念例句），已有音频的不动', () {
      final Map<String, String> out =
          srsFillTtsAudioFields(const <String, String>{
            'Sentence': '散歩の途中で<b>偶然</b>会った。',
            'SentenceAudio': '',
            'TermAudio': '[sound:word.mp3]',
            'Term': '偶然',
            'TermReading': 'ぐうぜん',
          }, kSrsTtsFillableAudioFields);
      expect(_firstTts(out['SentenceAudio']!)!.text, '散歩の途中で偶然会った。');
      expect(out['TermAudio'], '[sound:word.mp3]');
    });

    test('单词音频念读音；Lapis 旧名同样认', () {
      final Map<String, String> out = srsFillTtsAudioFields(
        const <String, String>{
          'Expression': '偶然',
          'ExpressionReading': 'ぐうぜん',
          'ExpressionAudio': '',
        },
        const <String>{FushiCardFields.termAudio},
      );
      expect(_firstTts(out['ExpressionAudio']!)!.text, 'ぐうぜん');
    });

    test('汉字词头读音为空不填；纯假名词头照常填', () {
      final Map<String, String> kanji = srsFillTtsAudioFields(
        const <String, String>{'Term': '偶然', 'TermAudio': ''},
        const <String>{FushiCardFields.termAudio},
      );
      expect(kanji['TermAudio'], '');
      final Map<String, String> kana = srsFillTtsAudioFields(
        const <String, String>{'Term': 'あちら', 'TermAudio': ''},
        const <String>{FushiCardFields.termAudio},
      );
      expect(_firstTts(kana['TermAudio']!)!.text, 'あちら');
    });

    test('没选的字段、例句为空、带 <audio> 的字段都不填', () {
      const Map<String, String> fields = <String, String>{
        'Sentence': '',
        'SentenceAudio': '',
        'Term': 'あちら',
        'TermAudio': '<audio src="a.mp3"></audio>',
      };
      expect(
        srsFillTtsAudioFields(fields, kSrsTtsFillableAudioFields),
        same(fields),
      );
      expect(
        srsFillTtsAudioFields(const <String, String>{
          'Sentence': 'x',
          'SentenceAudio': '',
        }, const <String>{})['SentenceAudio'],
        '',
      );
    });
  });

  group('SrsCardTtsOptions', () {
    test('JSON 往返；不认识的字段名丢掉', () {
      const SrsCardTtsOptions o = SrsCardTtsOptions(
        templateTags: false,
        fillAudioFields: <String>{'SentenceAudio'},
      );
      expect(SrsCardTtsOptions.fromJson(o.toJson()), o);
      expect(
        SrsCardTtsOptions.fromJson(<String, Object?>{
          'fill': <Object?>['SentenceAudio', 'Bogus', 3],
        }).fillAudioFields,
        <String>{'SentenceAudio'},
      );
      expect(SrsCardTtsOptions.fromJson(null), const SrsCardTtsOptions());
    });
  });

  group('renderCard', () {
    int t = DateTime.utc(2026, 11, 26, 12).millisecondsSinceEpoch;

    Future<SrsRenderedCard> render(
      SrsDbStore s,
      Map<String, String> fieldsByKey, {
      SrsCardTtsOptions tts = const SrsCardTtsOptions(),
    }) async {
      final String note = await s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kProfile, 'MainDefinition'):
              '<ol><li>by chance</li></ol>',
          for (final MapEntry<String, String> e in fieldsByKey.entries)
            srsFushiCardFieldId(kProfile, e.key): e.value,
        },
      );
      final SrsCardCacheRow card = (await s.cardsOfNote(note)).first;
      t += 1000;
      return (await s.renderCard(card.id, tts: tts))!;
    }

    test('选了填字段：空的例句音频与单词音频出朗读键，原生卡面字段同一份', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      final SrsRenderedCard plain = await render(s, <String, String>{
        'Expression': '偶然',
        'ExpressionReading': 'ぐうぜん',
        'Sentence': '散歩の途中で偶然会った。',
      });
      expect(plain.fields.values.join(), isNot(contains(kSrsTtsSoundPrefix)));

      final SrsRenderedCard filled = await render(
        s,
        <String, String>{
          'Expression': '偶然',
          'ExpressionReading': 'ぐうぜん',
          'Sentence': '散歩の途中で偶然会った。',
        },
        tts: const SrsCardTtsOptions(
          fillAudioFields: kSrsTtsFillableAudioFields,
        ),
      );
      final String sentenceAudio = FushiCardFields.value(
        filled.fields,
        'SentenceAudio',
      )!;
      final String termAudio = FushiCardFields.value(
        filled.fields,
        FushiCardFields.termAudio,
      )!;
      expect(_firstTts(sentenceAudio)!.text, '散歩の途中で偶然会った。');
      expect(_firstTts(termAudio)!.text, 'ぐうぜん');
    });
  });
}
