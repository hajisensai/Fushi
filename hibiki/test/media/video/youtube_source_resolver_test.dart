import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';

void main() {
  group('isYoutubeUrl', () {
    test('accepts watch and youtu.be', () {
      expect(isYoutubeUrl('https://www.youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://youtu.be/abc123'), true);
    });
    test('rejects non-youtube', () {
      expect(isYoutubeUrl('https://www.netflix.com/watch/1'), false);
      expect(isYoutubeUrl('/local/file.mp4'), false);
    });
  });

  group('parseYoutubeTimedTextToCues', () {
    test('converts timedtext XML to cues with ms bounds', () {
      const xml = '<transcript>'
          '<text start="1.5" dur="2.0">走り出した</text>'
          '<text start="4.0" dur="1.5">こんにちは</text>'
          '</transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:abc');
      expect(cues.length, 2);
      expect(cues[0].text, '走り出した');
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3500);
      expect(cues[1].startMs, 4000);
      expect(cues[1].endMs, 5500);
    });
    test('decodes entities and skips empty', () {
      const xml =
          '<transcript><text start="0" dur="1">&#39;</text><text start="1" dur="1"></text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.length, 1);
      expect(cues[0].text, "'");
    });
  });
}
