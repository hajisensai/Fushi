import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_episode_rail.dart';

/// BUG-1306 守卫：合集详情页「选集」横排必须能用**鼠标拖动**滚动。
///
/// 用户实报「这里的集，没办法鼠标拖动欸」。根因是 Flutter 桌面的默认
/// `MaterialScrollBehavior.dragDevices` **不含** [PointerDeviceKind.mouse]：横向
/// 滚动区用鼠标左键按住左右拖毫无反应。仓库早有共享件
/// （`HorizontalDragScrollable` / `WheelToHorizontalScroll`，BUG-1214）且已用在
/// 合集横排行、标签筛选栏、首页横排 —— 唯独这条剧集轨漏包，于是同样的横排在库页
/// 拖得动、进了详情页就拖不动。
///
/// 这里断言的是**真滚动行为**（拖完 offset 真的变了），不是「包了某个 widget」的
/// 结构断言 —— 后者在共享件被换实现时会假绿。
void main() {
  Widget wrap(List<VideoEpisodeEntry> episodes) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400, // 刻意窄于内容总宽，保证有可滚动余量
              child: VideoEpisodeRail(
                episodes: episodes,
                currentIndex: 0,
                onTapEpisode: (int _) {},
                colorScheme: const ColorScheme.dark(),
              ),
            ),
          ),
        ),
      );

  List<VideoEpisodeEntry> episodes(int n) => <VideoEpisodeEntry>[
        for (int i = 0; i < n; i++) VideoEpisodeEntry(title: 'S01E${i + 1}'),
      ];

  /// 取轨道内 ListView 的当前横向偏移。
  double offsetOf(WidgetTester tester) {
    final Scrollable scrollable = tester.widget<Scrollable>(
      find.descendant(
        of: find.byType(VideoEpisodeRail),
        matching: find.byType(Scrollable),
      ),
    );
    return scrollable.controller!.offset;
  }

  testWidgets('鼠标按住左右拖 → 剧集轨真的滚动（BUG-1306）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(episodes(12)));
    await tester.pumpAndSettle();

    expect(offsetOf(tester), 0);

    // kind: mouse 是本用例的全部意义所在——不指定 kind 时 flutter_test 默认发
    // touch 事件，而 touch 在默认 dragDevices 里，测不出这个 bug。
    await tester.drag(
      find.byType(VideoEpisodeRail),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(
      offsetOf(tester),
      greaterThan(0),
      reason: '鼠标拖动必须驱动横向滚动；默认 dragDevices 不含 mouse 时这里恒为 0',
    );
  });

  testWidgets('触屏拖动照旧可用（放开鼠标不得破坏原有输入）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(episodes(12)));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byType(VideoEpisodeRail),
      const Offset(-200, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();

    expect(offsetOf(tester), greaterThan(0));
  });

  testWidgets('内容不足一屏时拖动不越界（无可滚动余量）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(episodes(1)));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byType(VideoEpisodeRail),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(offsetOf(tester), 0, reason: '没有可滚动余量时不得滚出内容区');
  });
}
