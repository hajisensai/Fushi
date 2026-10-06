// 歌词播放卡窄屏布局与触控目标的回归测试（Round7 审查复现迁入）。
// HBK048：新头行在 280 宽右溢；200% 字号下顶栏 / 底卡高度写死而溢出。
// HBK049：触控平台 ±10 秒按钮被整组 FittedBox 缩到 48 以下，偏中心点击落空。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';

class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => const LyricsPlayerStats(
    sessionDurationMs: 600000,
    sessionChars: 3000,
    tracking: true,
    currentChars: 92047,
    totalChars: 106317,
  );
}

Widget _app({
  required double textScale,
  TargetPlatform? platform,
  ValueChanged<int>? onSeekRelative,
  ValueChanged<LyricsMenuAnchor>? onSleepTimer,
  ValueChanged<String>? onOtherAction,
}) => MaterialApp(
  theme: platform == null ? null : ThemeData(platform: platform),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: ReaderLyricsPlayerOverlay(
      lyricsView: const SizedBox.expand(key: ValueKey<String>('lyrics_probe')),
      data: LyricsPlayerData(
        title: '無職転生',
        chapterLabel: '第一章　新しい旅の始まり',
        cover: null,
        isPlaying: false,
        speed: 1,
        lyricsMasked: false,
        sleepTimerMinutes: 15,
        clock: _Clock(),
      ),
      callbacks: LyricsPlayerCallbacks(
        onClose: () => onOtherAction?.call('close'),
        onPlayPause: () => onOtherAction?.call('playPause'),
        onPreviousCue: () => onOtherAction?.call('previousCue'),
        onNextCue: () => onOtherAction?.call('nextCue'),
        onSeek: (_) => onOtherAction?.call('absoluteSeek'),
        onToggleMask: () => onOtherAction?.call('toggleMask'),
        onOpenStatistics: () => onOtherAction?.call('statistics'),
        onSpeedChanged: (_) => onOtherAction?.call('speed'),
        onMore: (_) => onOtherAction?.call('more'),
        onTypography: (_) => onOtherAction?.call('typography'),
        onTapBackground: () => onOtherAction?.call('background'),
        onSeekRelative: onSeekRelative ?? (_) {},
        onSleepTimer: onSleepTimer ?? (_) => onOtherAction?.call('sleepTimer'),
      ),
      onHtmlThemeChanged: (_) {},
    ),
  ),
);

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final ({Size size, double scale}) viewport
        in <({Size size, double scale})>[
          (size: const Size(390, 844), scale: 1),
          (size: const Size(320, 640), scale: 1),
          (size: const Size(280, 640), scale: 1),
          (size: const Size(390, 844), scale: 1.3),
          (size: const Size(360, 780), scale: 1.5),
          (size: const Size(390, 844), scale: 2),
          (size: const Size(320, 640), scale: 2),
          (size: const Size(844, 390), scale: 1),
        ]) {
      testWidgets('complete lyrics card ${platform.name} ${viewport.size} '
          'text ${viewport.scale} fits', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport.size;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(textScale: viewport.scale, platform: platform),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final Object? exception = tester.takeException();
        // 头行的次要操作不再被压进固定高度：触控平台上睡眠按钮命中区保持 48。
        Size? sleep;
        if (viewport.size.width < viewport.size.height &&
            platform == TargetPlatform.android) {
          final RenderBox box = tester.renderObject<RenderBox>(
            find.byKey(const ValueKey<String>('lyrics_sleep_timer_button')),
          );
          final Offset a = box.localToGlobal(Offset.zero);
          final Offset b = box.localToGlobal(box.size.bottomRight(Offset.zero));
          sleep = Size(b.dx - a.dx, b.dy - a.dy);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(exception, isNull);
        if (sleep != null && viewport.size.width >= 320) {
          expect(sleep.width, greaterThanOrEqualTo(48));
          expect(sleep.height, greaterThanOrEqualTo(48));
        }
      });
    }
  }

  testWidgets('new relative seek and sleep controls forward real UI taps', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final List<int> relativeSeeks = <int>[];
    LyricsMenuAnchor? sleepAnchor;
    await tester.pumpWidget(
      _app(
        textScale: 1,
        onSeekRelative: relativeSeeks.add,
        onSleepTimer: (LyricsMenuAnchor anchor) => sleepAnchor = anchor,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('lyrics_seek_back_button')));
    await tester.tap(find.byKey(const ValueKey('lyrics_seek_forward_button')));
    await tester.tap(find.byKey(const ValueKey('lyrics_sleep_timer_button')));
    expect(relativeSeeks, <int>[-10, 10]);
    expect(sleepAnchor, isNotNull);
    expect(sleepAnchor!.rect.isEmpty, isFalse);
    expect(sleepAnchor!.context.mounted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
