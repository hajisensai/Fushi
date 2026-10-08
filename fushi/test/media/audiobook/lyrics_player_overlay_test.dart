import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';

import '../../helpers/source_guard.dart';

/// 歌词覆盖层（2026-10-04，对齐 Niratan）：
///  * 覆盖层只**读**阅读器的读数，自身不写任何统计；
///  * 歌词 WebView 在覆盖层里的位置恒定——宽窄布局切换只改矩形、不重建平台视图；
///  * 宽屏双栏、窄屏单栏（不显示封面）。
class _FakeClock implements LyricsPlayerClock {
  int statsReads = 0;

  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats {
    statsReads++;
    return const LyricsPlayerStats(
      sessionDurationMs: 600000,
      sessionChars: 3000,
      tracking: true,
      currentChars: 92047,
      totalChars: 106317,
    );
  }
}

/// 记录自己被创建了几次：State 只建一次 = 歌词 WebView 没被重建。
class _LyricsProbe extends StatefulWidget {
  const _LyricsProbe({required this.onCreate});

  final VoidCallback onCreate;

  @override
  State<_LyricsProbe> createState() => _LyricsProbeState();
}

class _LyricsProbeState extends State<_LyricsProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey<String>('lyrics_probe'));
}

void main() {
  LyricsPlayerCallbacks callbacks() => LyricsPlayerCallbacks(
    onClose: () {},
    onPlayPause: () {},
    onPreviousCue: () {},
    onNextCue: () {},
    onSeek: (_) {},
    onToggleMask: () {},
    onOpenStatistics: () {},
    onSpeedChanged: (_) {},
    onMore: (_) {},
    onTapBackground: () {},
  );

  test('LyricsPlayerStats 只是阅读器读数的派生显示', () {
    const LyricsPlayerStats stats = LyricsPlayerStats(
      sessionDurationMs: 1800000,
      sessionChars: 4500,
      tracking: true,
      currentChars: 50,
      totalChars: 200,
    );
    expect(stats.charsPerHour, 9000);
    expect(stats.percent, 25);
    expect(LyricsPlayerStats.empty.charsPerHour, 0);
    expect(LyricsPlayerStats.empty.percent, isNull);
    expect(formatLyricsPlayerTime(const Duration(seconds: 65)), '1:05');
    expect(formatLyricsPlayerTime(const Duration(seconds: 3725)), '1:02:05');
  });

  test('宽窄判据：横屏 / 桌面双栏，手机竖屏单栏', () {
    expect(lyricsPlayerIsWide(const Size(1200, 700)), isTrue);
    expect(lyricsPlayerIsWide(const Size(844, 390)), isTrue);
    expect(lyricsPlayerIsWide(const Size(390, 844)), isFalse);
    expect(lyricsPlayerIsWide(const Size(560, 500)), isFalse);
  });

  test('覆盖层代码不写任何统计（统计归下面的阅读器）', () {
    final Directory dir = Directory('lib/src/media/audiobook/lyrics_player');
    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final File f in files) {
      final String src = maskComments(f.readAsStringSync());
      for (final String banned in <String>[
        'StudyClock',
        'ReadUnitLedger',
        'addChars(',
        'StatisticsRepository',
        'study_segments',
        'flushReadingStats',
        'reader_fushi_page.dart',
      ]) {
        expect(
          src,
          isNot(contains(banned)),
          reason: '${f.path} 不得写统计 / 依赖阅读器页面（$banned）',
        );
      }
    }
  });

  for (final String design in <String>['md3']) {
    testWidgets('$design：宽窄切换不重建歌词 WebView，矩形随布局变化', (
      WidgetTester tester,
    ) async {
      int created = 0;
      final _FakeClock clock = _FakeClock();
      final Widget probe = _LyricsProbe(onCreate: () => created++);
      LyricsHtmlTheme? reported;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: ReaderLyricsPlayerOverlay(
            lyricsView: probe,
            data: LyricsPlayerData(
              title: '無職転生',
              cover: null,
              isPlaying: false,
              speed: 1,
              lyricsMasked: false,
              clock: clock,
            ),
            callbacks: callbacks(),
            onHtmlThemeChanged: (LyricsHtmlTheme t) => reported = t,
          ),
        ),
      );

      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(1280, 760);
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 50));
      final Rect wide = tester.getRect(
        find.byKey(const ValueKey<String>('lyrics_probe')),
      );
      // 宽屏：歌词是右栏（左边让给封面与控件）。
      expect(wide.left, greaterThan(1280 * 0.25));

      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final Rect narrow = tester.getRect(
        find.byKey(const ValueKey<String>('lyrics_probe')),
      );
      // 窄屏：单栏，歌词占满宽度（不显示封面）。
      expect(narrow.width, greaterThan(390 * 0.8));
      expect(created, 1, reason: '布局切换不得重建歌词 WebView');
      expect(reported, isNotNull, reason: '首帧即下发歌词 HTML 主题');
      // 覆盖层只读读数，不会把读数写回任何地方（clock 是只读接口）。
      expect(clock.statsReads, greaterThanOrEqualTo(0));
      // 收尾：停掉外观里的循环动画 / 计时器。
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('歌词 HTML 主题渲染为 CSS 变量并支持热更', () {
    const LyricsHtmlTheme theme = LyricsHtmlTheme(
      textColor: Color(0xFFFFFFFF),
      currentColor: Color(0xFFFFFFFF),
      accentColor: Color(0x4DFFFFFF),
      selectionTextColor: Color(0xFFFFFFFF),
      contextOpacities: <double>[0.46, 0.36, 0.3, 0.26],
      browsingOpacity: 0.6,
      deselectedScale: 0.96,
      anchorY: 0.46,
      edgeFade: 0.08,
      alignStart: true,
      contextBlurPx: 0,
      rowRadius: 16,
      hoverFill: Color(0x14FFFFFF),
    );
    final ({Map<String, String> vars, List<String> bodyClasses}) v =
        LyricsModeHtml.themeVars(theme);
    expect(v.vars['--ly-align'], 'start');
    expect(v.vars['--ly-op1'], '0.460');
    expect(v.vars['--ly-anchor'], '0.460');
    expect(v.bodyClasses, containsAll(<String>['ly-themed', 'ly-fade']));
    // 用户自定义歌词文字色覆盖非当前行颜色（不丢旧设置）。
    final ({Map<String, String> vars, List<String> bodyClasses}) custom =
        LyricsModeHtml.themeVars(
          theme,
          textColorOverride: const Color(0xFFFF0000),
        );
    expect(custom.vars['--ly-text'], 'rgba(255,0,0,1.00)');
    expect(
      LyricsModeHtml.applyThemeInvocation(theme),
      startsWith('window.__lyricsApplyTheme && window.__lyricsApplyTheme('),
    );
  });
}
