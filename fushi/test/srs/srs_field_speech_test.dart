import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_field_speech.dart';

void main() {
  group('srsSpeechSourceFieldNames', () {
    test('单词音频先念读音再念词头，Lapis 旧名同样认', () {
      const List<String> term = <String>['TermReading', 'Term'];
      expect(srsSpeechSourceFieldNames('TermAudio'), term);
      expect(srsSpeechSourceFieldNames('ExpressionAudio'), term);
    });

    test('句子音频念句子；不认识的音频字段不提供', () {
      expect(srsSpeechSourceFieldNames('SentenceAudio'), <String>['Sentence']);
      expect(srsSpeechSourceFieldNames('MyAudio'), isEmpty);
    });
  });

  test('srsSpeechSourcesOf 按优先级挑字段，旧名字段也能匹配', () {
    final List<int> picked =
        srsSpeechSourcesOf<int>('ExpressionAudio', <({String name, int value})>[
          (name: 'Expression', value: 1),
          (name: 'Sentence', value: 2),
          (name: 'ExpressionReading', value: 3),
        ]);
    expect(picked, <int>[3, 1]);
  });

  test('srsSpeechText 去注音 / 标签 / [sound:]、解实体、收空白', () {
    expect(
      srsSpeechText(
        '<ruby>毎日<rp>(</rp><rt>まいにち</rt><rp>)</rp></ruby>'
        '<b>通って</b>&amp;<br>います [sound:x.mp3]',
      ),
      '毎日通って& います',
    );
    expect(srsSpeechText('  <i></i>[sound:a.mp3] '), isEmpty);
  });
}
