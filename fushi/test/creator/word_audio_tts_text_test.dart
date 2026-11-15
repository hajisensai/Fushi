import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/lookup/lookup_audio_playback.dart'
    show lookupEntryMatchedText;
import 'package:fushi_dictionary/fushi_dictionary.dart' show DictionaryEntry;

/// 反馈 WJFhjUGaTn：英语习惯表达词头带替换写法（`quite a/the something`）时，单词
/// 音频的 TTS 兜底把「a slash the」也念了出来。拍板：念查词命中的原文（句子里实际
/// 出现的那个写法），不念斜杠。查词播放与制卡兜底共用 [wordAudioTtsText]。
void main() {
  group('wordAudioTtsText', () {
    test('词头带替换写法时念命中原文', () {
      expect(
        wordAudioTtsText(
          expression: 'quite a/the something',
          reading: '',
          matched: 'quite some',
        ),
        'quite some',
      );
    });

    test('弹窗把空读音补成词头（reading || expression）时同样念命中原文', () {
      expect(
        wordAudioTtsText(
          expression: 'instead of somebody/something',
          reading: 'instead of somebody/something',
          matched: 'instead of',
        ),
        'instead of',
      );
    });

    test('全角斜杠同样算替换写法', () {
      expect(
        wordAudioTtsText(expression: 'a／the', reading: '', matched: 'the'),
        'the',
      );
    });

    test('命中原文首尾空白不进 TTS', () {
      expect(
        wordAudioTtsText(
          expression: 'quite a/the something',
          reading: '',
          matched: '  quite some  ',
        ),
        'quite some',
      );
    });

    test('没有命中原文时照旧念词头（手动建卡 / 别的设备的结果）', () {
      expect(
        wordAudioTtsText(expression: 'quite a/the something', reading: ''),
        'quite a/the something',
      );
      expect(
        wordAudioTtsText(
          expression: 'quite a/the something',
          reading: '',
          matched: '   ',
        ),
        'quite a/the something',
      );
    });

    test('词头本身就是字面斜杠（命中原文也带斜杠）时念词头', () {
      expect(
        wordAudioTtsText(expression: 'AC/DC', reading: '', matched: 'AC/DC'),
        'AC/DC',
      );
      expect(
        wordAudioTtsText(expression: '24/7', reading: '', matched: '24/7'),
        '24/7',
      );
    });

    test('无替换写法：沿用「读音优先、空则词头」，不被命中原文（变形）替换', () {
      // 日语变形查词：命中原文是活用形，TTS 仍念辞书形的读音。
      expect(
        wordAudioTtsText(expression: '食べる', reading: 'たべる', matched: '食べさせられた'),
        'たべる',
      );
      // 英语屈折：命中 `took`，仍念词头 `take`。
      expect(
        wordAudioTtsText(expression: 'take', reading: '', matched: 'took'),
        'take',
      );
    });
  });

  group('lookupEntryMatchedText', () {
    test('取 extra JSON 里的 matched', () {
      final DictionaryEntry entry = DictionaryEntry(
        word: 'quite a/the something',
        extra: jsonEncode(<String, Object?>{'matched': 'quite some'}),
      );
      expect(lookupEntryMatchedText(entry), 'quite some');
    });

    test('extra 为空 / 不是对象 / 不是 JSON / 没有 matched 时为空串', () {
      expect(lookupEntryMatchedText(DictionaryEntry(word: 'x')), '');
      expect(
        lookupEntryMatchedText(DictionaryEntry(word: 'x', extra: '[1]')),
        '',
      );
      expect(
        lookupEntryMatchedText(DictionaryEntry(word: 'x', extra: '{oops')),
        '',
      );
      expect(
        lookupEntryMatchedText(
          DictionaryEntry(word: 'x', extra: jsonEncode(<String, Object?>{})),
        ),
        '',
      );
    });
  });
}
