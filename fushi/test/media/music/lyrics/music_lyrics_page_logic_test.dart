import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:fushi_music/fushi_music.dart' show LyricSyllable;

/// 歌词页里不依赖 AppModel 的判据：查词暂停、查词起点、播放项 → 歌词曲目、插值时钟。
void main() {
  test('查词暂停：设置开着且在播才暂停', () {
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: true),
      isTrue,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: false, playing: true),
      isFalse,
    );
    expect(
      musicLyricsShouldPauseForLookup(settingEnabled: true, playing: false),
      isFalse,
    );
  });

  test('查词起点：从命中字符到行尾，越界夹住', () {
    const KaraokeLookupHit hit = KaraokeLookupHit(
      lineIndex: 0,
      syllableIndex: 2,
      charIndexInLine: 2,
      lineText: '夜に駆ける',
      globalRect: Rect.zero,
    );
    expect(musicLyricsLookupTerm(hit), '駆ける');
    expect(
      musicLyricsLookupTerm(
        const KaraokeLookupHit(
          lineIndex: 0,
          syllableIndex: 0,
          charIndexInLine: 99,
          lineText: 'ab',
          globalRect: Rect.zero,
        ),
      ),
      '',
    );
  });

  test('BUG-4495 英文歌词点词中字母：查词起点回退到词首', () {
    KaraokeLookupHit hitAt(String line, int index) => KaraokeLookupHit(
      lineIndex: 0,
      syllableIndex: 0,
      charIndexInLine: index,
      lineText: line,
      globalRect: Rect.zero,
    );
    // 反馈原样：点 world 的 r 只查到 rld。
    expect(musicLyricsLookupStart(hitAt('Hello world', 8)), 6);
    expect(musicLyricsLookupTerm(hitAt('Hello world', 8)), 'world');
    // 点词尾字母、词首字母都从同一个词首起。
    expect(musicLyricsLookupTerm(hitAt('Hello world', 10)), 'world');
    expect(musicLyricsLookupTerm(hitAt('Hello world', 0)), 'Hello world');
    // 重音字母与数字算词内。
    expect(musicLyricsLookupTerm(hitAt('mon café 2045', 7)), 'café 2045');
    expect(musicLyricsLookupTerm(hitAt('mon café 2045', 11)), '2045');
    // 日英混排：英文词首不越过日文；日文仍从被点字起。
    expect(musicLyricsLookupTerm(hitAt('夜にdancing', 6)), 'dancing');
    expect(musicLyricsLookupTerm(hitAt('夜に駆けるdance', 2)), '駆けるdance');
    // 点在空格 / 标点上：起点不动。
    expect(musicLyricsLookupStart(hitAt('Hello world', 5)), 5);
  });

  test('BUG-4495 源注音区间跟着回退后的起点算', () {
    final List<FushiRubySpan> spans = musicLyricsRubySpans(
      const <LyricSyllable>[
        LyricSyllable(text: 'Hey ', startMs: 0, endMs: 1),
        LyricSyllable(text: '星', startMs: 1, endMs: 2, ruby: 'ほし'),
      ],
      musicLyricsLookupStart(
        const KaraokeLookupHit(
          lineIndex: 0,
          syllableIndex: 0,
          charIndexInLine: 2,
          lineText: 'Hey 星',
          globalRect: Rect.zero,
        ),
      ),
    );
    expect(spans, hasLength(1));
    expect(spans.single.start, 4);
    expect(spans.single.end, 5);
  });

  test('CUE 虚拟曲目的起点带进歌词曲目（不认 sidecar / 内嵌）', () {
    final MusicLyricsTrackRef ref = musicLyricsTrackRefOf(
      const MusicPlayItem(
        trackUid: 'u',
        path: '/m/full.flac',
        title: 'T',
        startMs: 60000,
        endMs: 120000,
        durationMs: 60000,
      ),
    );
    expect(ref.isCueTrack, isTrue);
    expect(ref.durationMs, 60000);
  });

  test('插值时钟：在播时外推、封顶、暂停定住', () {
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(milliseconds: 80),
        playing: true,
      ),
      const Duration(milliseconds: 10080),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 30),
        playing: true,
      ),
      const Duration(seconds: 12),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 10),
        sinceLastEvent: const Duration(seconds: 1),
        playing: false,
      ),
      const Duration(seconds: 10),
    );
    expect(
      extrapolateMusicPosition(
        lastPosition: const Duration(seconds: 59),
        sinceLastEvent: const Duration(seconds: 2),
        playing: true,
        duration: const Duration(seconds: 60),
      ),
      const Duration(seconds: 60),
    );
  });

  group('手柄查词模式（gamepad-unify）', () {
    KaraokeLookupHit hitAt(String line, int index) => KaraokeLookupHit(
      lineIndex: 0,
      syllableIndex: 0,
      charIndexInLine: index,
      lineText: line,
      globalRect: Rect.zero,
    );

    test('右端上限按字素截查询串，null 不截、至少 1 个', () {
      final KaraokeLookupHit hit = hitAt('夜に駆ける', 2);
      expect(musicLyricsLookupTerm(hit), '駆ける');
      expect(musicLyricsLookupTerm(hit, maxGraphemes: 2), '駆け');
      expect(musicLyricsLookupTerm(hit, maxGraphemes: 99), '駆ける');
      expect(musicLyricsLookupTerm(hit, maxGraphemes: 0), '駆');
      // 组合字素（emoji ZWJ 序列）算一个字素，不截断在中间。
      expect(
        musicLyricsLookupTerm(hitAt('a👨‍👩‍👧b', 1), maxGraphemes: 1),
        '👨‍👩‍👧',
      );
      // 拉丁词中段：先回退到词首再截。
      expect(
        musicLyricsLookupTerm(hitAt('Hello world', 8), maxGraphemes: 3),
        'wor',
      );
    });

    test('副屏查询：不截原样整行 + 命中字；截了是行首到截断处 + 查词起点', () {
      expect(musicLyricsCompanionQuery(hitAt('Hello world', 8)), (
        text: 'Hello world',
        charIndex: 8,
      ));
      expect(
        musicLyricsCompanionQuery(hitAt('Hello world', 8), maxGraphemes: 1),
        (text: 'Hello w', charIndex: 6),
      );
      expect(musicLyricsCompanionQuery(hitAt('夜に駆ける', 2), maxGraphemes: 2), (
        text: '夜に駆け',
        charIndex: 2,
      ));
    });

    test('选区右端上界：光标的查词起点到行尾的字素数', () {
      expect(musicLyricsGraphemesFromCursor('夜に駆ける', 2), 3);
      expect(musicLyricsGraphemesFromCursor('夜に駆ける', 0), 5);
      // 拉丁词中段从词首算，与真正查的串同起点。
      expect(musicLyricsGraphemesFromCursor('Hello world', 8), 5);
      expect(musicLyricsGraphemesFromCursor('a👨‍👩‍👧b', 1), 2);
      expect(musicLyricsGraphemesFromCursor('', 0), 0);
    });

    test('命中高亮长度换算成字素，查不到 = 0', () {
      expect(musicLyricsMatchedGraphemes('駆ける', 2), 2);
      expect(musicLyricsMatchedGraphemes('駆ける', 9), 3);
      expect(musicLyricsMatchedGraphemes('駆ける', 0), 0);
      expect(musicLyricsMatchedGraphemes('', 3), 0);
      expect(musicLyricsMatchedGraphemes('👨‍👩‍👧b', 8), 1);
    });

    test('查询串被截短：越过截断处的注音丢掉', () {
      const List<LyricSyllable> syllables = <LyricSyllable>[
        LyricSyllable(text: '星', startMs: 0, endMs: 1, ruby: 'ほし'),
        LyricSyllable(text: '空', startMs: 1, endMs: 2, ruby: 'そら'),
      ];
      expect(musicLyricsRubySpans(syllables, 0), hasLength(2));
      final List<FushiRubySpan> capped = musicLyricsRubySpans(
        syllables,
        0,
        termLength: 1,
      );
      expect(capped, hasLength(1));
      expect(capped.single.reading, 'ほし');
    });
  });
}
