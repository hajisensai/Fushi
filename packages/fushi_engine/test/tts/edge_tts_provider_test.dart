import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

void main() {
  group('EdgeTtsClientIdentity.secMsGec', () {
    test('uppercase 64-hex, matches the documented formula', () {
      final DateTime t = DateTime.utc(2026, 10, 11, 12, 3, 27);
      final String gec = EdgeTtsClientIdentity.secMsGec(t);
      expect(gec, matches(RegExp(r'^[0-9A-F]{64}$')));
      final int windowStart = DateTime.utc(
        2026,
        10,
        11,
        12,
        0,
      ).millisecondsSinceEpoch ~/ 1000;
      final int ticks = (windowStart + 11644473600) * 10000000;
      final String expected = sha256
          .convert(
            ascii.encode('$ticks${EdgeTtsClientIdentity.trustedClientToken}'),
          )
          .toString()
          .toUpperCase();
      expect(gec, expected);
    });

    test('stable within a 5-minute window, changes across windows', () {
      final String a = EdgeTtsClientIdentity.secMsGec(
        DateTime.utc(2026, 1, 1, 0, 0, 0),
      );
      final String b = EdgeTtsClientIdentity.secMsGec(
        DateTime.utc(2026, 1, 1, 0, 4, 59, 999),
      );
      final String c = EdgeTtsClientIdentity.secMsGec(
        DateTime.utc(2026, 1, 1, 0, 5, 0),
      );
      final String d = EdgeTtsClientIdentity.secMsGec(
        DateTime.utc(2025, 12, 31, 23, 59, 59),
      );
      expect(a, b);
      expect(c, isNot(a));
      expect(d, isNot(a));
    });

    test('version strings derive from the chromium version', () {
      expect(
        EdgeTtsClientIdentity.secMsGecVersion,
        '1-${EdgeTtsClientIdentity.chromiumFullVersion}',
      );
      expect(
        EdgeTtsClientIdentity.userAgent,
        contains('Edg/${EdgeTtsClientIdentity.chromiumMajor}.0.0.0'),
      );
    });
  });

  group('locateTtsWordBoundaries', () {
    test('maps words sequentially to UTF-16 offsets', () {
      const String text = '今日は、いい天気ですね。いい日だ。';
      final List<TtsBoundary> b = locateTtsWordBoundaries(text, const <
        ({String text, int offsetMs, int durationMs})
      >[
        (text: '今日', offsetMs: 0, durationMs: 300),
        (text: 'いい', offsetMs: 400, durationMs: 200),
        (text: '天気', offsetMs: 600, durationMs: 300),
        (text: 'いい', offsetMs: 1500, durationMs: 200),
      ]);
      expect(b.map((TtsBoundary x) => x.textOffset), <int>[0, 4, 6, 12]);
      expect(b.map((TtsBoundary x) => x.textLength), <int>[2, 2, 2, 2]);
      expect(b.map((TtsBoundary x) => x.offsetMs), <int>[0, 400, 600, 1500]);
      expect(b.last.durationMs, 200);
    });

    test('skips unknown and empty words without moving the cursor', () {
      const String text = '第3章が始まる';
      final List<TtsBoundary> b = locateTtsWordBoundaries(text, const <
        ({String text, int offsetMs, int durationMs})
      >[
        (text: '第', offsetMs: 0, durationMs: 100),
        (text: 'さん', offsetMs: 100, durationMs: 100), // 读法改写
        (text: '', offsetMs: 150, durationMs: 0),
        (text: '章', offsetMs: 200, durationMs: 100),
        (text: '始まる', offsetMs: 400, durationMs: 300),
      ]);
      expect(b.map((TtsBoundary x) => x.textOffset), <int>[0, 2, 4]);
      expect(b.map((TtsBoundary x) => x.offsetMs), <int>[0, 200, 400]);
    });

    test('does not match words before the cursor', () {
      final List<TtsBoundary> b = locateTtsWordBoundaries('AB', const <
        ({String text, int offsetMs, int durationMs})
      >[
        (text: 'B', offsetMs: 0, durationMs: 1),
        (text: 'A', offsetMs: 1, durationMs: 1),
      ]);
      expect(b.map((TtsBoundary x) => x.textOffset), <int>[1]);
    });

    test('handles surrogate pairs in UTF-16 units', () {
      final List<TtsBoundary> b = locateTtsWordBoundaries('😀猫', const <
        ({String text, int offsetMs, int durationMs})
      >[(text: '猫', offsetMs: 0, durationMs: 1)]);
      expect(b.single.textOffset, 2);
    });
  });

  group('parseMicrosoftVoiceList', () {
    test('parses ShortName / Locale / Gender, skips invalid entries', () {
      final List<Object?> raw = <Object?>[
        <String, Object?>{
          'ShortName': 'ja-JP-NanamiNeural',
          'Locale': 'ja-JP',
          'Gender': 'Female',
          'FriendlyName': 'Microsoft Nanami Online',
        },
        <String, Object?>{
          'ShortName': 'ja-JP-KeitaNeural',
          'Locale': 'ja-JP',
          'Gender': 'Male',
          'LocalName': '圭太',
        },
        <String, Object?>{'ShortName': 'x-NoLocale'},
        <String, Object?>{'ShortName': 'en-US-X', 'Locale': 'en-US', 'Gender': 1},
        'junk',
      ];
      final voices = parseMicrosoftVoiceList(raw);
      expect(voices.map((v) => v.id), <String>[
        'ja-JP-NanamiNeural',
        'ja-JP-KeitaNeural',
        'en-US-X',
      ]);
      expect(voices[0].locale, 'ja-JP');
      expect(voices[0].gender, 'Female');
      expect(voices[0].displayName, 'Microsoft Nanami Online');
      expect(voices[1].displayName, '圭太');
      expect(voices[1].gender, 'Male');
      expect(voices[2].displayName, 'en-US-X');
      expect(voices[2].gender, isNull);
    });

    test('non-list input yields empty', () {
      expect(parseMicrosoftVoiceList(null), isEmpty);
      expect(parseMicrosoftVoiceList(<String, Object?>{}), isEmpty);
    });
  });
}
