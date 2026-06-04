import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show parseSubtitleCues;

void main() {
  test('routes srt content to SrtParser cues', () {
    const srt = '1\n00:00:00,000 --> 00:00:01,000\nhello\n';
    final cues =
        parseSubtitleCues(content: srt, format: 'srt', bookUid: 'video/1');
    expect(cues, hasLength(1));
    expect(cues.first.text, 'hello');
    expect(cues.first.startMs, 0);
    expect(cues.first.endMs, 1000);
  });

  test('throws on unsupported format', () {
    expect(
      () => parseSubtitleCues(content: 'x', format: 'mp3', bookUid: 'video/1'),
      throwsArgumentError,
    );
  });
}
