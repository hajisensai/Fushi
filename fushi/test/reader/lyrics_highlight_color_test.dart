import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, VoidCallback;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2972：歌词模式高亮颜色无法修改。
///
/// 覆盖层主题下 `.cue.current` 只认 CSS 变量 `--ly-current`（设计系统的
/// `LyricsHtmlTheme.currentColor`），用户偏好从未进入这条通路。修复后新偏好
/// `lyrics_highlight_color`（哨兵 0 = 跟随主题）经 `currentColorOverride` 写进变量。
const Color _themeCurrent = Color(0xFF3366CC);
const Color _userHighlight = Color(0xFFE91E63);

const LyricsHtmlTheme _theme = LyricsHtmlTheme(
  textColor: Color(0xFF888888),
  currentColor: _themeCurrent,
  accentColor: Color(0x553366CC),
  selectionTextColor: Color(0xFFFFFFFF),
  contextOpacities: <double>[0.6, 0.5, 0.4, 0.3],
  browsingOpacity: 0.7,
  deselectedScale: 0.95,
  anchorY: 0.45,
  edgeFade: 0.06,
  alignStart: true,
  contextBlurPx: 0,
  rowRadius: 16,
  hoverFill: Color(0x14000000),
);

String _css(Color c) {
  final int r = (c.r * 255.0).round().clamp(0, 255);
  final int g = (c.g * 255.0).round().clamp(0, 255);
  final int b = (c.b * 255.0).round().clamp(0, 255);
  return 'rgba($r,$g,$b,${c.a.toStringAsFixed(2)})';
}

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

void main() {
  group('LyricsModeHtml currentColorOverride', () {
    test('without override the current line follows the theme', () {
      final vars = LyricsModeHtml.themeVars(_theme).vars;
      expect(vars['--ly-current'], _css(_themeCurrent));
      expect(vars['--ly-pill-fg'], _css(_themeCurrent));
    });

    test('override replaces current line and its derived colors', () {
      final vars = LyricsModeHtml.themeVars(
        _theme,
        currentColorOverride: _userHighlight,
      ).vars;
      expect(vars['--ly-current'], _css(_userHighlight));
      expect(
        vars['--ly-upcoming'],
        _css(_userHighlight.withValues(alpha: 0.4)),
      );
      expect(vars['--ly-pill-fg'], _css(_userHighlight));
      expect(
        vars['--ly-pill-bg'],
        _css(_userHighlight.withValues(alpha: 0.16)),
      );
      // 查词选区语义不变。
      expect(vars['--ly-hl'], _css(_theme.accentColor));
    });

    test('generate inlines the override into :root', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[
          AudioCue()
            ..id = 1
            ..bookKey = 'book'
            ..chapterHref = 'chapter'
            ..sentenceIndex = 0
            ..textFragmentId = ''
            ..text = 'テスト'
            ..startMs = 0
            ..endMs = 1000
            ..audioFileIndex = 0,
        ],
        currentIndex: 0,
        backgroundColor: 'transparent',
        textColor: '#000000',
        accentColor: '#3366cc',
        fontSize: 24,
        theme: _theme,
        currentColorOverride: _userHighlight,
      );
      expect(html, contains('--ly-current: ${_css(_userHighlight)};'));
      expect(html, isNot(contains('--ly-current: ${_css(_themeCurrent)};')));
    });

    test('applyThemeInvocation carries the override for live updates', () {
      final String js = LyricsModeHtml.applyThemeInvocation(
        _theme,
        currentColorOverride: _userHighlight,
      );
      expect(js, contains(jsonEncode(_css(_userHighlight))));
      expect(js, contains('"--ly-current"'));
    });
  });

  group('lyrics_highlight_color preference', () {
    late FushiDatabase db;

    setUp(() {
      db = _testDb();
      MediaSource.setDatabase(db);
      ReaderFushiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('defaults to sentinel 0 (follow player theme)', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      expect(settings.lyricsHighlightColor, 0);
      expect(ReaderFushiSource.instance.lyricsHighlightColor, 0);
    });

    test('persists through ReaderSettings', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setLyricsHighlightColor(0xFFE91E63);

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.lyricsHighlightColor, 0xFFE91E63);
    });

    test('source setter fires the live hook and clear returns to 0', () async {
      int live = 0;
      final VoidCallback? previous = ReaderFushiSource.onSettingsChangedLive;
      ReaderFushiSource.onSettingsChangedLive = () => live++;
      try {
        await ReaderFushiSource.instance.setLyricsHighlightColor(0xFF00AA55);
        expect(ReaderFushiSource.instance.lyricsHighlightColor, 0xFF00AA55);
        await ReaderFushiSource.instance.clearLyricsHighlightColor();
        expect(ReaderFushiSource.instance.lyricsHighlightColor, 0);
        expect(live, 2);
      } finally {
        ReaderFushiSource.onSettingsChangedLive = previous;
      }
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs['src:reader_fushi:lyrics_highlight_color'], 'i:0');
    });
  });

  test(
    'every lyrics theme emit site in lyrics.part.dart passes the override',
    () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      ).readAsStringSync();
      final RegExp call = RegExp(
        r'LyricsModeHtml\.(applyThemeInvocation|generate)\(',
      );
      final List<RegExpMatch> sites = call.allMatches(src).toList();
      expect(sites, isNotEmpty);
      for (final RegExpMatch m in sites) {
        // 取到配对的右括号为止的实参文本。
        int depth = 0;
        int end = m.end - 1;
        for (int i = m.end - 1; i < src.length; i++) {
          final String ch = src[i];
          if (ch == '(') depth++;
          if (ch == ')') {
            depth--;
            if (depth == 0) {
              end = i;
              break;
            }
          }
        }
        final String args = src.substring(m.end, end);
        expect(
          args,
          contains('currentColorOverride: _lyricsCustomHighlightColor()'),
          reason: '${m.group(0)} at offset ${m.start} drops the user highlight',
        );
      }
    },
  );
}
