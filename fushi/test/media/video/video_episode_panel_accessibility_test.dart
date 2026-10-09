import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/video/video_episode_panel.dart';
import 'package:fushi/src/utils/components/fading_chrome_gate.dart';

/// 选集面板的可达性回归（Codex 第五轮审查 HBK-AUDIT-024 / 025）：
/// - 025：换到别的季浏览 → 关闭 → 重新打开，面板切回当前集所在季时那条轨道是
///   新挂载的，必须照样把焦点交给当前集卡（方向键 / 手柄从当前集出发）。
/// - 024：320 宽 + 系统 200% 文字时，「正在播放」胶囊与标题不能叠在一起。
void main() {
  const List<VideoEpisodeEntry> episodes = <VideoEpisodeEntry>[
    VideoEpisodeEntry(title: 'Long current episode title', groupKey: 's1'),
    VideoEpisodeEntry(title: 'Other season episode', groupKey: 's2'),
  ];

  Widget host({required bool visible, double textScale = 1}) =>
      TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: FadingChromeGate(
              visible: visible,
              duration: Duration.zero,
              child: PanelFocusScope(
                visible: visible,
                child: VideoEpisodePanel(
                  episodes: episodes,
                  currentIndex: 0,
                  onTapEpisode: (int _) {},
                  onClose: () {},
                  colorScheme: const ColorScheme.light(),
                  title: 'Episodes',
                  emptyHint: 'No episodes',
                  seasonLabelOf: (String key) => key,
                  visible: visible,
                ),
              ),
            ),
          ),
        ),
      );

  Finder currentCard() =>
      find.byKey(const ValueKey<String>('video-episode-card-0'));

  FocusNode currentFocus(WidgetTester tester) => tester
      .widget<InkWell>(
        find.descendant(of: currentCard(), matching: find.byType(InkWell)),
      )
      .focusNode!;

  testWidgets(
    'reopening after browsing another season focuses current episode',
    (WidgetTester tester) async {
      await tester.pumpWidget(host(visible: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(visible: true));
      await tester.pumpAndSettle();
      expect(
        currentFocus(tester).hasFocus,
        isTrue,
        reason: 'control: a retained rail claims focus when opened',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('video-episode-season-chip-s2')),
      );
      await tester.pumpAndSettle();
      expect(currentCard(), findsNothing);
      await tester.pumpWidget(host(visible: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(visible: true));
      await tester.pumpAndSettle();

      expect(currentCard(), findsOneWidget);
      expect(
        currentFocus(tester).hasFocus,
        isTrue,
        reason:
            'reopening recreates the current season rail; keyboard/gamepad '
            'navigation must still start from the current episode',
      );
    },
  );

  testWidgets(
    'narrow panel keeps now-playing and title apart at 200 percent text',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(visible: true, textScale: 2));
      await tester.pumpAndSettle();

      final Rect title = tester.getRect(
        find.descendant(
          of: currentCard(),
          matching: find.text(episodes.first.title),
        ),
      );
      final Rect nowPlaying = tester.getRect(
        find.descendant(
          of: currentCard(),
          matching: find.text(t.reader_audiobook_now_playing),
        ),
      );
      expect(
        title.overlaps(nowPlaying),
        isFalse,
        reason: 'the two text overlays must remain independently readable',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
