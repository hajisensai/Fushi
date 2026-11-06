import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:fushi_music/fushi_music.dart';

LyricSyllable syl(String text, [String? ruby]) =>
    LyricSyllable(text: text, startMs: 0, endMs: 1, ruby: ruby);

void main() {
  final List<LyricSyllable> line = <LyricSyllable>[
    syl('忙', 'せわ'),
    syl('しい'),
    syl('毎日', 'まいにち'),
    syl('ア', 'ア'),
    syl('空', '  '),
  ];

  test('从行首查词：音节起点作为区间，空读音忽略，片假名原样保留', () {
    expect(musicLyricsRubySpans(line, 0), const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
      FushiRubySpan(start: 3, end: 5, reading: 'まいにち'),
      FushiRubySpan(start: 5, end: 6, reading: 'ア'),
    ]);
  });

  test('查词起点之前的音节丢弃，坐标平移到查词串', () {
    expect(musicLyricsRubySpans(line, 3), const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 2, reading: 'まいにち'),
      FushiRubySpan(start: 2, end: 3, reading: 'ア'),
    ]);
  });

  test('注音基字被查词起点截断（点在多字基字的第二个字）时丢弃', () {
    expect(musicLyricsRubySpans(line, 4), const <FushiRubySpan>[
      FushiRubySpan(start: 1, end: 2, reading: 'ア'),
    ]);
  });
}
