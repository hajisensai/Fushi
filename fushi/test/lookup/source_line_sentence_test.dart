import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/ocr_block_sentence.dart';
import 'package:fushi/src/lookup/source_line_sentence.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';

/// 反馈 1Mwaro8UTC：悬浮球（拍照查词 / iOS 截屏识字）与悬浮字幕点字走主窗常驻查词
/// 宿主，制卡只有单词、没有例句。根因是请求总线不带出处那一句、宿主制卡时也没有补
/// 句子的口子。这里钉住：总线带句子、宿主补句子的判据（与 app 外查词窗共用）、拍照
/// 查词只有行时的取句规则。
void main() {
  group('withSourceLineSentence', () {
    const Map<String, String> fields = <String, String>{
      'expression': '晴れ',
      'reading': 'はれ',
    };

    test('基础层、查询串仍是出自这一行的那个：补上例句', () {
      final Map<String, String> out = withSourceLineSentence(
        fields,
        layerIndex: 0,
        baseTerm: '晴れ',
        sourceQuery: '晴れ',
        sentence: '今日は晴れだ。',
      );
      expect(out['sentence'], '今日は晴れだ。');
      expect(out['expression'], '晴れ');
    });

    test('查询串首尾空白不影响判定', () {
      final Map<String, String> out = withSourceLineSentence(
        fields,
        layerIndex: 0,
        baseTerm: ' 晴れ ',
        sourceQuery: '晴れ\n',
        sentence: '今日は晴れだ。',
      );
      expect(out['sentence'], '今日は晴れだ。');
    });

    test('嵌套层（查的是释义里的词）不补', () {
      final Map<String, String> out = withSourceLineSentence(
        fields,
        layerIndex: 1,
        baseTerm: '晴れ',
        sourceQuery: '晴れ',
        sentence: '今日は晴れだ。',
      );
      expect(out.containsKey('sentence'), isFalse);
    });

    test('基础层原地跳到别的词后不补（即使那个词是行的子串）', () {
      final Map<String, String> out = withSourceLineSentence(
        fields,
        layerIndex: 0,
        baseTerm: '今日',
        sourceQuery: '晴れ',
        sentence: '今日は晴れだ。',
      );
      expect(out.containsKey('sentence'), isFalse);
    });

    test('没有出处（手动输入 / 剪贴板）不补', () {
      expect(
        withSourceLineSentence(
          fields,
          layerIndex: 0,
          baseTerm: '晴れ',
          sourceQuery: '晴れ',
          sentence: '',
        ).containsKey('sentence'),
        isFalse,
      );
      expect(
        withSourceLineSentence(
          fields,
          layerIndex: 0,
          baseTerm: '晴れ',
          sourceQuery: '',
          sentence: '今日は晴れだ。',
        ).containsKey('sentence'),
        isFalse,
      );
    });

    test('JS 送来的非空 sentence 仍优先', () {
      final Map<String, String> out = withSourceLineSentence(
        <String, String>{...fields, 'sentence': 'JS の句'},
        layerIndex: 0,
        baseTerm: '晴れ',
        sourceQuery: '晴れ',
        sentence: '今日は晴れだ。',
      );
      expect(out['sentence'], 'JS の句');
    });
  });

  group('ocrSentenceInLine', () {
    test('一行两句只取被点字所在的那一句', () {
      const String line = '雨が降った。今日は晴れだ。';
      expect(ocrSentenceInLine(line, line.indexOf('晴')), '今日は晴れだ。');
      expect(ocrSentenceInLine(line, 0), '雨が降った。');
    });

    test('没有句末标点时是整行', () {
      expect(ocrSentenceInLine(' 今日は晴れ ', 3), '今日は晴れ');
    });

    test('下标越界回落为整行', () {
      expect(ocrSentenceInLine('今日は晴れ', 99), '今日は晴れ');
    });
  });

  group('FloatingLyricLookupNotifier 带出处句子', () {
    final FloatingLyricLookupNotifier notifier =
        FloatingLyricLookupNotifier.instance;
    setUp(notifier.debugReset);
    tearDown(notifier.debugReset);

    test('requestLookup 把句子交给宿主（去首尾空白）', () {
      notifier.requestLookup('今日は晴れだ。', 3, sentence: ' 今日は晴れだ。 ');
      expect(notifier.pending?.sentence, '今日は晴れだ。');
    });

    test('不给句子时为空（手动输入 / 剪贴板查词不补例句）', () {
      notifier.requestLookup('晴れ', 0);
      expect(notifier.pending?.sentence, '');
    });
  });
}
