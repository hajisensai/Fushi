import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';

void main() {
  group('SrtParser error paths', () {
    test('empty string returns empty list', () {
      final cues = SrtParser.parseString(content: '', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('garbage text returns empty list', () {
      final cues = SrtParser.parseString(
        content: 'this is not a subtitle file at all',
        bookUid: 'b',
      );
      expect(cues, isEmpty);
    });

    test('malformed timestamp line is skipped', () {
      final cues = SrtParser.parseString(
        content: '1\nnot-a-timestamp\nHello\n\n'
            '2\n00:00:01,000 --> 00:00:02,000\nWorld\n',
        bookUid: 'b',
      );
      expect(cues.where((c) => c.text == 'World'), isNotEmpty);
    });

    test('only whitespace returns empty list', () {
      final cues = SrtParser.parseString(content: '   \n\n  \n', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('negative timestamps do not crash', () {
      final cues = SrtParser.parseString(
        content: '1\n-1:00:00,000 --> 00:00:01,000\nBad\n',
        bookUid: 'b',
      );
      expect(cues, isA<List>());
    });
  });

  group('VttParser error paths', () {
    test('empty string returns empty list', () {
      final cues = VttParser.parseString(content: '', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('missing WEBVTT header still attempts parse', () {
      final cues = VttParser.parseString(
        content: '00:00:01.000 --> 00:00:02.000\nHello\n',
        bookUid: 'b',
      );
      expect(cues, isA<List>());
    });

    test('only WEBVTT header with no cues returns empty', () {
      final cues = VttParser.parseString(content: 'WEBVTT\n\n', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('cue with missing end time does not crash', () {
      final cues = VttParser.parseString(
        content: 'WEBVTT\n\n00:00:01.000 -->\nHello\n',
        bookUid: 'b',
      );
      expect(cues, isA<List>());
    });
  });

  group('AssParser error paths', () {
    test('empty string returns empty list', () {
      final cues = AssParser.parseString(content: '', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('file with no Events section returns empty list', () {
      final cues = AssParser.parseString(
        content: '[Script Info]\nTitle: Test\n',
        bookUid: 'b',
      );
      expect(cues, isEmpty);
    });

    test('Events section with no Dialogue lines returns empty', () {
      final cues = AssParser.parseString(
        content: '[Events]\nFormat: Layer, Start, End, Style, Name, '
            'MarginL, MarginR, MarginV, Effect, Text\n'
            'Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,test\n',
        bookUid: 'b',
      );
      expect(cues, isEmpty);
    });

    test('Dialogue with insufficient fields does not crash', () {
      final cues = AssParser.parseString(
        content: '[Events]\nFormat: Layer, Start, End, Style, Name, '
            'MarginL, MarginR, MarginV, Effect, Text\n'
            'Dialogue: 0,bad\n',
        bookUid: 'b',
      );
      expect(cues, isA<List>());
    });
  });

  group('LrcParser error paths', () {
    test('empty string returns empty list', () {
      final cues = LrcParser.parseString(content: '', bookUid: 'b');
      expect(cues, isEmpty);
    });

    test('lines without timestamps are skipped', () {
      final cues = LrcParser.parseString(
        content: 'this is just text\nno timestamps here\n',
        bookUid: 'b',
      );
      expect(cues, isEmpty);
    });

    test('only metadata tags with no lyrics returns empty', () {
      final cues = LrcParser.parseString(
        content: '[ar:Artist]\n[ti:Title]\n[al:Album]\n',
        bookUid: 'b',
      );
      expect(cues, isEmpty);
    });

    test('timestamp with empty text still parses', () {
      final cues = LrcParser.parseString(
        content: '[00:01.00]\n[00:02.00]Text\n',
        bookUid: 'b',
      );
      // At least one cue with actual text
      expect(cues.where((c) => c.text == 'Text'), isNotEmpty);
    });
  });
}
