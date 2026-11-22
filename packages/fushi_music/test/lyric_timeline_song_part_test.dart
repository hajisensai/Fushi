import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 段落标注（`LyricLine.songPart`）走线格式 flags bit3 + 尾部段落表：不带段落时字节与旧格式一致，
/// 带段落时往返不丢（纯 Dart，不需要原生库）。
void main() {
  LyricTimeline timeline(List<String?> parts) => LyricTimeline(
    format: 'ttml',
    lines: <LyricLine>[
      for (int i = 0; i < parts.length; i++)
        LyricLine(
          startMs: i * 1000,
          endMs: i * 1000 + 900,
          syllables: <LyricSyllable>[
            LyricSyllable(
              text: 'l$i',
              startMs: i * 1000,
              endMs: i * 1000 + 900,
            ),
          ],
          songPart: parts[i],
        ),
    ],
  );

  test('没有段落：不置 bit3、不写尾部表', () {
    final Uint8List plain = encodeLyricTimeline(
      timeline(<String?>[null, null]),
    );
    final LyricTimeline back = decodeLyricTimeline(plain);
    expect(back.lines.every((LyricLine l) => l.songPart == null), isTrue);
    final Uint8List withParts = encodeLyricTimeline(
      timeline(<String?>['Verse', null]),
    );
    expect(withParts.length, greaterThan(plain.length));
  });

  test('带段落：往返相等', () {
    final LyricTimeline t = timeline(<String?>['Verse', 'Chorus', null]);
    final LyricTimeline back = decodeLyricTimeline(encodeLyricTimeline(t));
    expect(back, t);
    expect(back.lines.map((LyricLine l) => l.songPart).toList(), <String?>[
      'Verse',
      'Chorus',
      null,
    ]);
  });

  test('段落表截断抛 FormatException', () {
    final Uint8List bytes = encodeLyricTimeline(
      timeline(<String?>['Verse', 'Chorus']),
    );
    expect(
      () => decodeLyricTimeline(
        Uint8List.sublistView(bytes, 0, bytes.length - 2),
      ),
      throwsFormatException,
    );
  });
}
