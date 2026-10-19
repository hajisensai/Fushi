import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

void main() {
  group('buildYomitanTokenizeResponse', () {
    test('wraps each segment in its own array (yomitan 2D content)', () {
      final out = buildYomitanTokenizeResponse(
        text: '日本語は難しい',
        index: 0,
        segments: <TokenizedSegment>[
          (text: '日本語', reading: 'にほんご'),
          (text: 'は', reading: ''),
          (text: '難しい', reading: ''),
        ],
      );

      expect(out['id'], 'scan');
      expect(out['source'], 'scanning-parser');
      expect(out['dictionary'], isNull);
      expect(out['index'], 0);

      final content = out['content'] as List;
      expect(content.length, 3);
      final firstSeg = content[0] as List;
      expect(firstSeg.length, 1);
      expect((firstSeg[0] as Map)['text'], '日本語');
      expect((firstSeg[0] as Map)['reading'], 'にほんご');
      expect(((content[1] as List)[0] as Map)['reading'], '');
    });

    test('empty text yields empty content', () {
      final out = buildYomitanTokenizeResponse(
        text: '',
        index: 2,
        // 空文本不看 segments：一律空 content。
        segments: <TokenizedSegment>[(text: 'x', reading: '')],
      );
      expect(out['index'], 2);
      expect(out['content'], <dynamic>[]);
    });
  });
}
