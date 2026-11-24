import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart'
    show musicAppleLyricsAppearance;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

// 用户 2026-11-24：Cupertino 下歌词 / 正在播放页照 macOS Apple Music 全屏歌词排版
// （左列：封面 → 标题 + ☆⋯ → 进度 + 时间 → 五键传输；右列 Apple 式歌词）。

class _Clock implements FushiPlaybackClock {
  int ms = 0;

  @override
  Duration get position => Duration(milliseconds: ms);

  @override
  Duration get duration => const Duration(minutes: 4);
}

LyricLine _line(int start, String text) => LyricLine(
  startMs: start,
  endMs: start + 900,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: start, endMs: start + 900),
  ],
);

LyricTimeline _timeline() => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.syllable,
  lines: <LyricLine>[
    for (int i = 0; i < 10; i++) _line(1000 + i * 1000, 'line$i'),
  ],
);

String _part() => File(
  'lib/src/pages/implementations/music/music_lyrics_page_apple.part.dart',
).readAsStringSync();

String _page() => File(
  'lib/src/pages/implementations/music/music_lyrics_page.dart',
).readAsStringSync();

/// [src] 里从 [start] 起、到下一个同级方法（两空格缩进的 `Widget _`）为止的片段。
String _method(String src, String start) {
  final int from = src.indexOf(start);
  expect(from, isNonNegative, reason: start);
  final int to = src.indexOf('\n  Widget _', from + start.length);
  return src.substring(from, to < 0 ? src.length : to);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Apple lyrics appearance: label colours, anchor at 1/3, blur on', () {
    final FushiAppleColors apple = FushiAppleColors.of(
      Brightness.dark,
      const Color(0xFF0A84FF),
    );
    final KaraokeLyricsAppearance a = musicAppleLyricsAppearance(
      apple,
      blur: true,
    );
    expect(a.activeColor, apple.label);
    expect(a.secondaryColor, apple.secondaryLabel);
    expect(a.anchor, closeTo(1 / 3, 1e-9));
    expect(a.blurInactive, isTrue);
    expect(a.fontWeight, FontWeight.w800);
    expect(
      musicAppleLyricsAppearance(apple, blur: false).blurInactive,
      isFalse,
      reason: '跟随「非当前行模糊」偏好',
    );
  });

  testWidgets('Apple lyrics: current line sharp, other lines blurred', (
    WidgetTester tester,
  ) async {
    final _Clock clock = _Clock()..ms = 3100; // line2 正在唱
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: KaraokeLyricsView(
              timeline: _timeline(),
              clock: clock,
              playing: false,
              appearance: musicAppleLyricsAppearance(
                FushiAppleColors.of(Brightness.dark, const Color(0xFF0A84FF)),
                blur: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    ImageFiltered filterOf(String text) => tester.widget<ImageFiltered>(
      find
          .ancestor(
            of: find.byWidgetPredicate(
              (Widget w) => w is Semantics && w.properties.label == text,
            ),
            matching: find.byType(ImageFiltered),
          )
          .first,
    );
    expect(filterOf('line2').enabled, isFalse, reason: '当前行不模糊');
    expect(filterOf('line1').enabled, isTrue);
    expect(filterOf('line3').enabled, isTrue);
    expect(filterOf('line5').enabled, isTrue);
  });

  test(
    'Apple wide left column order: cover → title + ☆⋯ → seek → transport',
    () {
      final String wide = _method(_part(), 'Widget _buildAppleWide(');
      final List<String> order = <String>[
        '_AppleLyricsCover(',
        '_buildAppleTitleRow(',
        '_buildSeek()',
        '_buildAppleTransport(',
      ];
      final List<int> at = <int>[for (final String s in order) wide.indexOf(s)];
      for (int i = 0; i < at.length; i++) {
        expect(at[i], isNonNegative, reason: order[i]);
        if (i > 0) expect(at[i], greaterThan(at[i - 1]), reason: order[i]);
      }
      // 标题行：标题列在左，☆ 与 ⋯ 在最右。
      final String title = _method(_part(), 'Widget _buildAppleTitleRow(');
      expect(
        title.indexOf('_buildAppleStarButton()'),
        lessThan(title.indexOf('_buildAppleMoreMenu(')),
      );
      // 五键：随机 · 上一首 · 播放 · 下一首 · 循环。
      final String transport = _method(_part(), 'Widget _buildAppleTransport(');
      final List<String> keys = <String>[
        "'music_lyrics_shuffle'",
        "'music_lyrics_previous'",
        "'music_lyrics_play_pause'",
        "'music_lyrics_next'",
        "'music_lyrics_repeat'",
      ];
      final List<int> k = <int>[
        for (final String s in keys) transport.indexOf(s),
      ];
      for (int i = 0; i < k.length; i++) {
        expect(k[i], isNonNegative, reason: keys[i]);
        if (i > 0) expect(k[i], greaterThan(k[i - 1]), reason: keys[i]);
      }
    },
  );

  test('every secondary action is reachable from ⋯', () {
    final String more = _method(_part(), 'Widget _buildAppleMoreMenu(');
    for (final String key in <String>[
      'music_lyrics_offset_earlier',
      'music_lyrics_offset_later',
      'music_lyrics_ab_loop',
      'music_lyrics_ab_loop_extend',
      'music_lyrics_quality',
      'music_lyrics_effects',
      'music_lyrics_desktop_menu',
      'music_lyrics_queue',
    ]) {
      expect(more, contains("'$key'"), reason: key);
    }
    expect(more, contains('t.music_lyrics_offset_value('));
  });

  test('M3E layouts are untouched and Apple is gated on isGlassDesign', () {
    final String page = _page();
    expect(page, contains('when apple && l != MusicLyricsLayout.disc'));
    for (final String m3e in <String>[
      '(MusicLyricsLayout.split, true) => _buildSplit(',
      '(MusicLyricsLayout.stage, true) => _buildStage(',
      '(MusicLyricsLayout.disc, _) => _buildDisc(',
      '(_, false) => _buildNarrow(context, item)',
      'FushiExpressivePlayButton(',
      'color: liked ? const Color(0xFFFF4D6D) : null',
    ]) {
      expect(page, contains(m3e), reason: m3e);
    }
    expect(page, contains('final bool apple = isGlassDesign(context);'));
  });
}
