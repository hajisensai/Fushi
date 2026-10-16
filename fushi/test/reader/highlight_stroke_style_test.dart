import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/reader/highlight_stroke_preview.dart';
import 'package:fushi/src/reader/highlight_stroke_style.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_core/fushi_core.dart';

/// 高亮条笔触样式（用户 2026-10-15「高亮条自定义做成配置」「全部高亮都要能选」）：偏好 →
/// 正文 CSS 变量 → 窄条层 JS 的契约。JS 的真画法在真 Chrome 里验
/// （highlight_stroke_marker_test.dart）。
void main() {
  Future<ReaderSettings> settingsWith(
    Future<void> Function(ReaderSettings s) apply,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await apply(settings);
    return settings;
  }

  final String js = ReaderSelectionScripts.source();

  test('wire names: unknown values fall back to classic', () {
    for (final HighlightStrokeStyle s in HighlightStrokeStyle.values) {
      expect(HighlightStrokeStyle.fromWire(s.wireName), s);
    }
    expect(HighlightStrokeStyle.fromWire('neon'), HighlightStrokeStyle.classic);
    expect(HighlightStrokeStyle.fromWire(null), HighlightStrokeStyle.classic);
  });

  List<String> jsList(String name) {
    final RegExpMatch? m = RegExp(
      'var $name = \\[([^\\]]*)\\];',
    ).firstMatch(js);
    expect(m, isNotNull, reason: '$name not found in the lanes script');
    return RegExp(
      r"'([a-z]+)'",
    ).allMatches(m!.group(1)!).map((RegExpMatch x) => x.group(1)!).toList();
  }

  test('JS MARK_STYLES lists exactly the non-classic Dart styles', () {
    final List<String> styles = jsList('MARK_STYLES');
    expect(styles, <String>[
      for (final HighlightStrokeStyle s in HighlightStrokeStyle.values)
        if (s.isStroke) s.wireName,
    ]);
    for (final String style in styles) {
      expect(
        js,
        contains('    $style: function(l, c) {'),
        reason: 'MARKERS.$style shape is missing',
      );
    }
  });

  test('JS MARK_NATURAL_EM equals the Dart natural thickness table', () {
    final RegExpMatch? m = RegExp(
      r'var MARK_NATURAL_EM = \{([^}]*)\};',
    ).firstMatch(js);
    expect(m, isNotNull, reason: 'MARK_NATURAL_EM not found');
    final Map<String, double> jsTable = <String, double>{
      for (final RegExpMatch e in RegExp(
        r'([a-z]+): ([0-9.]+)',
      ).allMatches(m!.group(1)!))
        e.group(1)!: double.parse(e.group(2)!),
    };
    expect(jsTable, <String, double>{
      for (final MapEntry<HighlightStrokeStyle, double> e
          in kHighlightStrokeNaturalEm.entries)
        e.key.wireName: e.value,
    });
    // 笔触样式以好看为先：除半截外，自然粗细都超过一个字高（用户 2026-10-16）。
    for (final HighlightStrokeStyle s in HighlightStrokeStyle.values) {
      if (!s.isStroke || s == HighlightStrokeStyle.under) continue;
      expect(kHighlightStrokeNaturalEm[s], greaterThan(1), reason: s.wireName);
    }
  });

  test('JS MARK_KINDS and group mapping cover every Dart kind', () {
    expect(jsList('MARK_KINDS'), <String>[
      for (final HighlightKind k in HighlightKind.values) k.cssName,
    ]);
    expect(js, contains("'fushi-sentence-audio': 'audio'"));
    expect(js, contains("'fushi-selection': 'lookup'"));
    expect(js, contains("'fushi-search': 'search'"));
  });

  test('defaults: classic everywhere, stroke animation on', () async {
    final ReaderSettings s = await settingsWith((_) async {});
    for (final HighlightKind kind in HighlightKind.values) {
      final HighlightStrokeConfig c = s.highlightStrokeConfig(kind);
      expect(c, kind.defaults, reason: kind.name);
      expect(c.style, HighlightStrokeStyle.classic, reason: kind.name);
    }
    for (final HighlightKind kind in HighlightKind.values) {
      expect(s.highlightStrokeConfig(kind).animate, isTrue, reason: kind.name);
    }
  });

  test('each kind round-trips independently', () async {
    const HighlightStrokeConfig tape = HighlightStrokeConfig(
      style: HighlightStrokeStyle.tape,
      thickness: 1.4,
      opacity: 0.5,
      coverRuby: true,
      roughness: 0.2,
      animate: true,
    );
    final ReaderSettings s = await settingsWith(
      (ReaderSettings s) =>
          s.setHighlightStrokeConfig(HighlightKind.audio, tape),
    );
    expect(s.highlightStrokeConfig(HighlightKind.audio), tape);
    for (final HighlightKind other in <HighlightKind>[
      HighlightKind.favorite,
      HighlightKind.lookup,
      HighlightKind.search,
    ]) {
      expect(
        s.highlightStrokeConfig(other),
        other.defaults,
        reason: other.name,
      );
    }
  });

  test('audio stroke keys do not collide with the audio colour keys', () {
    expect(HighlightKind.audio.prefPrefix, 'audio_highlight');
    for (final String suffix in <String>[
      'style',
      'thickness',
      'opacity',
      'cover_ruby',
      'roughness',
      'animate',
    ]) {
      expect(<String>[
        'audio_highlight_color',
        'audio_highlight_background',
        'audio_highlight_text_color',
      ], isNot(contains('audio_highlight_$suffix')));
    }
  });

  group('CSS variables', () {
    String vars(
      Map<HighlightKind, HighlightStrokeConfig> c, {
      bool eink = false,
      bool motion = true,
    }) => highlightStrokeCssVariables(
      c,
      einkMode: eink,
      darkBackground: false,
      paperColor: '#ffffff',
      motionEnabled: motion,
    );

    // CLAUDE.md 动效硬规则：落笔动画的时长取 FushiMotion，墨水屏与系统「减弱动态效果」下归零，
    // JS 不另立时长常量、不自己读 prefers-reduced-motion。
    test('sweep pacing comes from FushiMotion tokens', () {
      final String css = vars(const <HighlightKind, HighlightStrokeConfig>{});
      expect(
        css,
        contains(
          '--fushi-mark-sweep-base-ms: ${FushiMotion.micro.inMilliseconds};',
        ),
      );
      expect(
        css,
        contains(
          '--fushi-mark-sweep-per-em-ms: '
          '${FushiMotion.strokeSweepPerEm.inMilliseconds};',
        ),
      );
      expect(
        css,
        contains(
          '--fushi-mark-sweep-gap-ms: ${FushiMotion.staggerStep.inMilliseconds};',
        ),
      );
      expect(
        highlightStrokeSweepLineDuration(10),
        FushiMotion.micro + FushiMotion.strokeSweepPerEm * 10,
      );
    });

    test('reduced motion and e-ink switch every sweep off', () {
      final Map<HighlightKind, HighlightStrokeConfig> all =
          <HighlightKind, HighlightStrokeConfig>{
            for (final HighlightKind k in HighlightKind.values)
              k: const HighlightStrokeConfig(
                style: HighlightStrokeStyle.marker,
                animate: true,
              ),
          };
      for (final String css in <String>[
        vars(all, motion: false),
        vars(all, eink: true),
      ]) {
        for (final HighlightKind k in HighlightKind.values) {
          expect(css, contains('--fushi-mark-${k.cssName}-animate: 0;'));
        }
        expect(css, contains('--fushi-mark-sweep-base-ms: 0;'));
        expect(css, contains('--fushi-mark-sweep-per-em-ms: 0;'));
        expect(css, contains('--fushi-mark-sweep-gap-ms: 0;'));
      }
      // 动效开着时用户的开关照常生效。
      expect(vars(all), contains('--fushi-mark-favorite-animate: 1;'));
    });

    test('the reader stylesheet threads motionEnabled through', () async {
      final ReaderSettings s = await settingsWith(
        (ReaderSettings s) => s.setHighlightStrokeConfig(
          HighlightKind.audio,
          const HighlightStrokeConfig(style: HighlightStrokeStyle.rough),
        ),
      );
      expect(
        ReaderContentStyles.css(settings: s),
        contains('--fushi-mark-audio-animate: 1;'),
      );
      expect(
        ReaderContentStyles.css(settings: s, motionEnabled: false),
        contains('--fushi-mark-audio-animate: 0;'),
      );
    });

    test('the lane script has no motion constants of its own', () {
      // 时长只认 Dart 下发的 --fushi-mark-sweep-*；减弱动态效果只认 Dart 的 animate=0。
      expect(js, isNot(contains('prefers-reduced-motion')));
      expect(js, contains('--fushi-mark-sweep-base-ms'));
      expect(js, contains('--fushi-mark-sweep-per-em-ms'));
      expect(js, contains('--fushi-mark-sweep-gap-ms'));
      expect(js, isNot(contains('0.026')));
    });

    test('carry every field per kind, clamped', () {
      final String css = vars(<HighlightKind, HighlightStrokeConfig>{
        HighlightKind.lookup: const HighlightStrokeConfig(
          style: HighlightStrokeStyle.marker,
          thickness: 9,
          opacity: 0.4,
          coverRuby: true,
          roughness: -1,
          animate: false,
        ),
      });
      expect(css, contains('--fushi-mark-lookup-style: marker;'));
      expect(css, contains('--fushi-mark-lookup-thickness: 1.8;'));
      expect(css, contains('--fushi-mark-lookup-opacity: 0.4;'));
      expect(css, contains('--fushi-mark-lookup-cover-ruby: 1;'));
      expect(css, contains('--fushi-mark-lookup-roughness: 0;'));
      expect(css, contains('--fushi-mark-lookup-animate: 0;'));
      // 没给的种类按默认（经典）。
      for (final HighlightKind k in <HighlightKind>[
        HighlightKind.favorite,
        HighlightKind.audio,
        HighlightKind.search,
      ]) {
        expect(css, contains('--fushi-mark-${k.cssName}-style: classic;'));
      }
      expect(css, contains('--fushi-mark-favorite-animate: 1;'));
      expect(css, contains('--fushi-mark-paper: #ffffff;'));
      expect(css, contains('--fushi-mark-dark: 0;'));
    });

    test('e-ink forces the classic style for every kind', () {
      final String css = vars(<HighlightKind, HighlightStrokeConfig>{
        for (final HighlightKind k in HighlightKind.values)
          k: const HighlightStrokeConfig(style: HighlightStrokeStyle.fluo),
      }, eink: true);
      for (final HighlightKind k in HighlightKind.values) {
        expect(css, contains('--fushi-mark-${k.cssName}-style: classic;'));
      }
    });

    test('cover-ruby is dropped for styles where it means nothing', () {
      for (final HighlightStrokeStyle s in <HighlightStrokeStyle>[
        HighlightStrokeStyle.classic,
        HighlightStrokeStyle.under,
      ]) {
        expect(
          vars(<HighlightKind, HighlightStrokeConfig>{
            HighlightKind.search: HighlightStrokeConfig(
              style: s,
              coverRuby: true,
            ),
          }),
          contains('--fushi-mark-search-cover-ruby: 0;'),
          reason: s.wireName,
        );
      }
    });

    test('favourite underline override only for stroke styles', () {
      expect(
        favoriteHighlightUnderlineOverrideCss(
          const HighlightStrokeConfig(),
          einkMode: false,
        ),
        isEmpty,
      );
      expect(
        favoriteHighlightUnderlineOverrideCss(
          const HighlightStrokeConfig(style: HighlightStrokeStyle.marker),
          einkMode: true,
        ),
        isEmpty,
      );
      final String css = favoriteHighlightUnderlineOverrideCss(
        const HighlightStrokeConfig(style: HighlightStrokeStyle.marker),
        einkMode: false,
      );
      for (final String c in <String>[
        'yellow',
        'green',
        'blue',
        'pink',
        'purple',
      ]) {
        expect(css, contains('::highlight(fushi-hl-$c)'));
        expect(css, contains('ruby.fushi-hl-$c-ruby-active'));
      }
      expect(css, contains('text-decoration-line: none !important;'));
    });

    test('the reader stylesheet writes them from the settings', () async {
      final ReaderSettings classic = await settingsWith((_) async {});
      final String classicCss = ReaderContentStyles.css(settings: classic);
      expect(classicCss, contains('--fushi-mark-favorite-style: classic;'));
      expect(classicCss, isNot(contains('收藏笔触样式：形状本身就是标记')));

      final ReaderSettings marked = await settingsWith((
        ReaderSettings s,
      ) async {
        await s.setHighlightStrokeConfig(
          HighlightKind.favorite,
          const HighlightStrokeConfig(style: HighlightStrokeStyle.marker),
        );
        await s.setHighlightStrokeConfig(
          HighlightKind.audio,
          const HighlightStrokeConfig(style: HighlightStrokeStyle.rough),
        );
      });
      final String css = ReaderContentStyles.css(settings: marked);
      expect(css, contains('--fushi-mark-favorite-style: marker;'));
      expect(css, contains('--fushi-mark-audio-style: rough;'));
      expect(css, contains('--fushi-mark-lookup-style: classic;'));
      expect(css, contains('收藏笔触样式：形状本身就是标记'));
      expect(
        ReaderContentStyles.css(settings: marked, einkMode: true),
        contains('--fushi-mark-audio-style: classic;'),
      );
    });
  });

  group('preview', () {
    test('sample markup parses into glyphs, ruby and the highlighted run', () {
      final ({
        List<HighlightPreviewGlyph> glyphs,
        List<HighlightPreviewRuby> ruby,
      })
      parsed = parseHighlightPreviewSample('｜放課後《ほうかご》の⟦｜席《せき》に⟧座');
      expect(
        parsed.glyphs.map((HighlightPreviewGlyph g) => g.char).join(),
        '放課後の席に座',
      );
      expect(
        parsed.glyphs.map((HighlightPreviewGlyph g) => g.highlighted).toList(),
        <bool>[false, false, false, false, true, true, false],
      );
      expect(parsed.ruby.length, 2);
      expect(parsed.ruby.first.start, 0);
      expect(parsed.ruby.first.end, 3);
      expect(parsed.ruby.first.text, 'ほうかご');
      expect(parsed.ruby.last.start, 4);
      expect(parsed.ruby.last.end, 5);
    });

    test('every style paints in both orientations and mid-animation', () {
      for (final HighlightStrokeStyle style in HighlightStrokeStyle.values) {
        for (final bool vertical in <bool>[false, true]) {
          for (final double progress in <double>[0.3, 1]) {
            final ui.PictureRecorder recorder = ui.PictureRecorder();
            final Canvas canvas = Canvas(recorder);
            HighlightStrokePreviewPainter(
              sample: kHighlightPreviewSample,
              config: HighlightStrokeConfig(style: style, coverRuby: true),
              color: kFavoriteHighlightColors['pink']!,
              paper: const Color(0xFFFFFFFF),
              ink: const Color(0xFF000000),
              vertical: vertical,
              fontSize: 20,
              lineHeight: 1.9,
              progress: progress,
            ).paint(canvas, const Size(360, 300));
            recorder.endRecording().dispose();
          }
        }
      }
    });
  });
}
