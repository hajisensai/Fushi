// 折叠屏桌面姿态下视频页下半屏的播放面板：M3E 与 Apple 两套设计系统各自成套，
// 播放键与短 / 长步进键真的回调到播放器，步进秒数跟配置走（不写死 10 秒）。
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_tabletop_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Widget home, {required bool apple}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006C52)),
        extensions: <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
        ],
      ).copyWith(platform: TargetPlatform.android),
      themeAnimationDuration: Duration.zero,
      locale: const Locale('en'),
      supportedLocales: const <Locale>[Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: SizedBox(height: 280, child: home)),
    ),
  );
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    testWidgets('${apple ? 'Apple' : 'M3E'}：播放键与短 / 长步进回调到播放器', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);
      final ValueNotifier<Duration> position = ValueNotifier<Duration>(
        const Duration(seconds: 30),
      );
      addTearDown(position.dispose);
      final List<int> seeks = <int>[];
      await tester.pumpWidget(
        _app(
          VideoTabletopPanel(
            listenable: playing,
            positionListenable: position,
            title: () => 'Episode 1',
            isPlaying: () => playing.value,
            position: () => position.value,
            duration: () => const Duration(minutes: 24),
            onPlayPause: () => playing.value = !playing.value,
            onSeek: (_) {},
            onSeekRelative: seeks.add,
            seekSeconds: 3,
            longSeekSeconds: 45,
          ),
          apple: apple,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(
          ValueKey<String>(
            apple
                ? 'video_tabletop_panel_apple'
                : 'video_tabletop_panel_material',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('Episode 1'), findsOneWidget);

      // 位置由推送源驱动：通知后的下一帧（不推进任何时间）就显示新位置——轮询实现
      // 要等定时器到点，这里会读不到。放在按播放之前：暂停 + 静态波形时进度条不跑
      // Ticker，只剩推送源这一条路。
      final String before = formatFushiPlaybackTime(
        const Duration(seconds: 30),
      );
      final String after = formatFushiPlaybackTime(
        const Duration(minutes: 1, seconds: 30),
      );
      expect(find.text(before), findsWidgets);
      position.value = const Duration(minutes: 1, seconds: 30);
      await tester.pump();
      expect(find.text(after), findsWidgets);
      expect(find.text(before), findsNothing);

      for (final String key in <String>[
        'video_tabletop_long_seek_back_button',
        'video_tabletop_seek_back_button',
        'video_tabletop_seek_forward_button',
        'video_tabletop_long_seek_forward_button',
      ]) {
        await tester.tap(find.byKey(ValueKey<String>(key)));
      }
      expect(seeks, <int>[-45, -3, 3, 45]);
      // 秒数动态显示：M3E 是圆钮下的「−Ns / +Ns」标注；Apple 是圆箭头里的数字
      // （SF 有 45 的带数字字形，3 秒画无数字圆箭头 + 叠字）。
      if (apple) {
        expect(find.byIcon(CupertinoIcons.gobackward_45), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.goforward_45), findsOneWidget);
        expect(find.text('3'), findsNWidgets(2));
      } else {
        for (final String label in <String>[
          t.video_bottom_seek_back_seconds_label(seconds: 45),
          t.video_bottom_seek_back_seconds_label(seconds: 3),
          t.video_bottom_seek_forward_seconds_label(seconds: 3),
          t.video_bottom_seek_forward_seconds_label(seconds: 45),
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(
          find.byTooltip(t.video_control_seek_backward_seconds(seconds: 45)),
          findsOneWidget,
        );
      }

      // Apple 的 FushiTooltip 不是 Material Tooltip，按 key 点、按 SF 字形断言。
      await tester.tap(
        apple
            ? find.byKey(const ValueKey<String>('video_tabletop_play_button'))
            : find.byTooltip(t.play),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(playing.value, isTrue);
      expect(
        apple
            ? find.byIcon(CupertinoIcons.pause_fill)
            : find.byTooltip(t.pause),
        findsOneWidget,
      );

      // 卸载：面板必须从推送源上摘掉监听（否则通知会打到已卸载的 State）。
      await tester.pumpWidget(const SizedBox());
      expect(
        // ignore: invalid_use_of_protected_member
        position.hasListeners,
        isFalse,
      );
    });
  }
}
