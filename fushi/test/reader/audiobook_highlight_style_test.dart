import 'dart:ui' show Color;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/reader/audio_highlight_style.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 有声书「当前句高亮」样式组：正文底色开关 / 正文字色 / 歌词逐字渐变，以及
/// BUG-3105（歌词竖排不逐字推进、暂停或查词时当前句被纯色块盖住）。
const LyricsHtmlTheme _theme = LyricsHtmlTheme(
  textColor: Color(0xFF888888),
  currentColor: Color(0xFF3366CC),
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

Future<ReaderSettings> _settings() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

AudioCue _cue(int i, String text) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _lyricsHtml({required bool vertical, bool sweep = true}) =>
    LyricsModeHtml.generate(
      cues: <AudioCue>[_cue(0, 'ほっと胸を撫で下ろす'), _cue(1, '雪ノ下を見る。')],
      currentIndex: 0,
      backgroundColor: 'transparent',
      textColor: '#888888',
      accentColor: '#3366cc',
      fontSize: 24,
      vertical: vertical,
      theme: _theme,
      sweep: sweep,
    );

/// 生成 CSS 里所有给当前行 `.tx` 铺渐变背景的规则（选择器 → 声明块）。
Map<String, String> _sweepBackgroundRules(String html) {
  final Map<String, String> rules = <String, String>{};
  final RegExp rule = RegExp(r'([^{}]+)\{([^{}]*)\}');
  for (final RegExpMatch m in rule.allMatches(html)) {
    final String selector = m.group(1)!.trim().split('\n').last.trim();
    final String body = m.group(2)!;
    if (selector.contains('.cue.current') &&
        selector.contains('.tx') &&
        body.contains('background-image')) {
      rules[selector] = body;
    }
  }
  return rules;
}

int _classCount(String selector) => '.'.allMatches(selector).length;

void main() {
  group('resolveAudioHighlightStyle', () {
    const Color hl = Color(0x66FFCC00);

    test('默认：铺底色、不改字色（历史行为）', () {
      final AudioHighlightStyle s = resolveAudioHighlightStyle(
        highlight: hl,
        showBackground: true,
        customTextColor: 0,
      );
      expect(s.background, hl);
      expect(s.text, isNull);
    });

    test('关底色未设字色：底色透明，字色退回不透明高亮色', () {
      final AudioHighlightStyle s = resolveAudioHighlightStyle(
        highlight: hl,
        showBackground: false,
        customTextColor: 0,
      );
      expect(s.background.a, 0);
      expect(s.text, const Color(0xFFFFCC00));
    });

    test('只变字色、无底色：自定义字色优先', () {
      final AudioHighlightStyle s = resolveAudioHighlightStyle(
        highlight: hl,
        showBackground: false,
        customTextColor: 0xFFB00020,
      );
      expect(s.background.a, 0);
      expect(s.text, const Color(0xFFB00020));
    });

    test('底色 + 字色', () {
      final AudioHighlightStyle s = resolveAudioHighlightStyle(
        highlight: hl,
        showBackground: true,
        customTextColor: 0xFFB00020,
      );
      expect(s.background, hl);
      expect(s.text, const Color(0xFFB00020));
    });
  });

  group('ReaderSettings 高亮样式偏好', () {
    test('默认值与写穿', () async {
      final ReaderSettings settings = await _settings();
      expect(settings.lyricsSweep, isTrue);
      expect(settings.audioHighlightBackground, isTrue);
      expect(settings.audioHighlightTextColor, 0);

      await settings.setLyricsSweep(false);
      await settings.setAudioHighlightBackground(false);
      await settings.setAudioHighlightTextColor(0xFF112233);
      expect(settings.lyricsSweep, isFalse);
      expect(settings.audioHighlightBackground, isFalse);
      expect(settings.audioHighlightTextColor, 0xFF112233);
    });
  });

  group('正文 CSS 当前句字色', () {
    test('传了字色就写进 --fushi-sentence-audio-text-color，否则沿用正文色', () async {
      final ReaderSettings settings = await _settings();
      final String plain = ReaderContentStyles.css(
        settings: settings,
        customFg: 'rgba(10,20,30,1.0)',
      );
      expect(
        plain,
        contains('--fushi-sentence-audio-text-color: rgba(10,20,30,1.0);'),
      );

      final String recolored = ReaderContentStyles.css(
        settings: settings,
        customFg: 'rgba(10,20,30,1.0)',
        sentenceAudioHighlightColor: 'rgba(0,0,0,0.0)',
        sentenceAudioTextColor: 'rgba(176,0,32,1.0)',
      );
      expect(
        recolored,
        contains('--fushi-sentence-audio-text-color: rgba(176,0,32,1.0);'),
      );
      expect(
        recolored,
        contains('--fushi-sentence-audio-background-color: rgba(0,0,0,0.0);'),
      );
    });
  });

  group('歌词逐字跟读渐变开关', () {
    test('sweep=false 不挂 ly-sweep（整行纯色），默认挂', () {
      expect(
        LyricsModeHtml.themeVars(_theme).bodyClasses,
        contains('ly-sweep'),
      );
      expect(
        LyricsModeHtml.themeVars(_theme, sweep: false).bodyClasses,
        isNot(contains('ly-sweep')),
      );
      expect(
        LyricsModeHtml.applyThemeInvocation(_theme, sweep: false),
        isNot(contains('ly-sweep')),
        reason: '运行期热更必须能把 ly-sweep 摘掉',
      );
      expect(
        _lyricsHtml(vertical: false, sweep: false),
        isNot(contains('ly-sweep ')),
      );
    });
  });

  group('BUG-3105 歌词竖排逐字推进 / 暂停不盖字', () {
    test('每条给当前行铺渐变的规则都带「播放中、非查词」门', () {
      for (final bool vertical in <bool>[false, true]) {
        final Map<String, String> rules = _sweepBackgroundRules(
          _lyricsHtml(vertical: vertical),
        );
        expect(rules, hasLength(2), reason: '横排 + 竖排各一条');
        for (final String selector in rules.keys) {
          expect(
            selector,
            contains(':not(.ly-paused)'),
            reason:
                '暂停时没有 background-clip:text，渐变会画成实心块盖住字：'
                '$selector',
          );
          expect(
            selector,
            contains(':not(.ly-nosweep)'),
            reason: '查词时同理：$selector',
          );
        }
      }
    });

    test('竖排规则特异性高于横排规则（播放中改走 to bottom）', () {
      final Map<String, String> rules = _sweepBackgroundRules(
        _lyricsHtml(vertical: true),
      );
      final String vertical = rules.keys.singleWhere(
        (String s) => s.contains('.ly-vertical'),
      );
      final String horizontal = rules.keys.singleWhere(
        (String s) => !s.contains('.ly-vertical'),
      );
      expect(rules[vertical], contains('to bottom'));
      expect(rules[horizontal], contains('to right'));
      expect(
        _classCount(vertical),
        greaterThan(_classCount(horizontal)),
        reason: '同为 body 元素选择器，类数更多者胜；否则竖排被 to right 压掉',
      );
    });
  });
}
