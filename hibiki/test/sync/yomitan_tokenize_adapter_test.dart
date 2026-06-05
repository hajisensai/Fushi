import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

void main() {
  group('buildYomitanTokenizeResponse', () {
    test('wraps segments with index and content', () {
      List<String> fakeTokenizer(String t) => ['日本語', 'は', '難しい'];
      String fakeReading(String w) => w == '日本語' ? 'にほんご' : '';

      final out = buildYomitanTokenizeResponse(
        text: '日本語は難しい',
        index: 0,
        tokenize: fakeTokenizer,
        readingOf: fakeReading,
      );

      expect(out['index'], 0);
      final content = out['content'] as List;
      expect(content.length, 3);
      expect((content[0] as Map)['text'], '日本語');
      expect((content[0] as Map)['reading'], 'にほんご');
      expect((content[1] as Map)['reading'], '');
    });

    test('empty text yields empty content', () {
      final out = buildYomitanTokenizeResponse(
        text: '',
        index: 2,
        tokenize: (String t) => <String>[],
        readingOf: (String w) => '',
      );
      expect(out['index'], 2);
      expect(out['content'], <dynamic>[]);
    });
  });
}
