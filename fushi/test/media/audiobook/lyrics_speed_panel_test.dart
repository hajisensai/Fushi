import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

import '../../helpers/source_guard.dart';

/// 歌词模式倍速（2026-10-05，用户：「倍数可以设成跟普通的阅读模式一样，直接
/// 拖动拉条，自己调更好些」）：
///  * 倍速按钮点开含拖动条的面板，拖动 / 方向键实时回调；
///  * 拖动条与普通阅读模式快捷设置是同一个 [AudiobookSpeedSlider]（同范围 /
///    吸附 / 步进），回调走页面同一个 `ctrl.setSpeed`；
///  * MD3 与 Apple 两套设计系统都能渲染面板。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

ThemeData _theme({required bool apple}) {
  return buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: apple ? FushiGlassMaterial.frosted : FushiGlassMaterial.off,
    glassDesign: apple,
  ).copyWith(platform: TargetPlatform.windows);
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'apple' : 'md3';

    testWidgets('$design：倍速按钮打开拖动条面板，方向键 / 拖动 / 复位实时回调', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 760);
      addTearDown(tester.view.reset);

      double speed = 1.0;
      final List<double> changes = <double>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(apple: apple),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                rebuild = setState;
                return ReaderLyricsPlayerOverlay(
                  lyricsView: const SizedBox.expand(),
                  data: LyricsPlayerData(
                    title: '無職転生',
                    cover: null,
                    isPlaying: false,
                    speed: speed,
                    lyricsMasked: false,
                    clock: _FakeClock(),
                  ),
                  callbacks: LyricsPlayerCallbacks(
                    onClose: () {},
                    onPlayPause: () {},
                    onPreviousCue: () {},
                    onNextCue: () {},
                    onSeek: (_) {},
                    onToggleMask: () {},
                    onOpenStatistics: () {},
                    // 页面里这里是 `ctrl.setSpeed`——与普通模式同一处写入。
                    onSpeedChanged: (double v) {
                      changes.add(v);
                      rebuild(() => speed = v);
                    },
                    onMore: (_) {},
                    onTapBackground: () {},
                  ),
                  onHtmlThemeChanged: (_) {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 倍速按钮显示当前倍速，点开面板。
      final Finder button = find.text('1.0×');
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final Finder slider = find.byKey(kLyricsSpeedPanelKey);
      expect(slider, findsOneWidget);
      expect(find.byType(LyricsSpeedPanel), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 面板打开即聚焦拖动条：→ 两下 = +0.10×（与普通模式同一步进）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(changes, <double>[1.05, 1.1]);
      // 按钮读数随之更新（覆盖层重建）。
      expect(find.text('1.1×'), findsWidgets);

      // 拖动：从轨道中点拖到靠右，值实时变化且按 0.05× 吸附、不超过上限。
      changes.clear();
      final Rect track = tester.getRect(slider);
      await tester.dragFrom(track.center, Offset(track.width * 0.3, 0));
      await tester.pump();
      expect(changes, isNotEmpty);
      for (final double v in changes) {
        expect(v, inInclusiveRange(1.0, AudiobookSpeedSlider.maxSpeed));
        expect((v * 20 - (v * 20).roundToDouble()).abs(), lessThan(1e-9));
      }
      expect(speed, greaterThan(1.1));

      // 复位键回到 1.0×。
      await tester.tap(find.byKey(kLyricsSpeedPanelResetKey));
      await tester.pump();
      expect(speed, 1.0);

      // Esc 关闭面板。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LyricsSpeedPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('AudiobookSpeedSlider：范围 0.25–3.0、0.05× 吸附', () {
    expect(AudiobookSpeedSlider.minSpeed, 0.25);
    expect(AudiobookSpeedSlider.maxSpeed, 3.0);
    expect(AudiobookSpeedSlider.divisions, 55);
    expect(AudiobookSpeedSlider.snap(1.234), 1.25);
    expect(AudiobookSpeedSlider.snap(0.1), 0.25);
    expect(AudiobookSpeedSlider.snap(9), 3.0);
    expect(formatLyricsSpeed(1), '1.0×');
    expect(formatLyricsSpeed(1.25), '1.25×');
    expect(formatLyricsSpeed(1.1), '1.1×');
  });

  test('普通模式与歌词模式倍速共用同一个拖动条组件，不再有固定档位菜单', () {
    final String sheet = maskComments(
      File(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
      ).readAsStringSync(),
    );
    expect(sheet, contains('AudiobookSpeedSlider('));
    // 两处入口写进同一个偏好：都交给 AudiobookPlayerController.setSpeed（它负责
    // 生效 + 持久化），不各自存值。
    expect(sheet, contains('onChanged: ctrl.setSpeed'));
    final String lyricsPart = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      ).readAsStringSync(),
    );
    expect(
      lyricsPart,
      contains(
        'onSpeedChanged: (double speed) => unawaited(ctrl.setSpeed(speed))',
      ),
    );
    final String panel = maskComments(
      File(
        'lib/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart',
      ).readAsStringSync(),
    );
    expect(panel, contains('AudiobookSpeedSlider('));
    for (final String path in <String>[
      'lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart',
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart',
    ]) {
      final String src = maskComments(File(path).readAsStringSync());
      expect(src, contains('showLyricsSpeedPanel('), reason: path);
      expect(src, isNot(contains('kLyricsPlayerSpeeds')), reason: path);
    }
  });
}
