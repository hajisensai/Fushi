import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderPanelSwitcher;
import 'package:material_ui/material_ui.dart';

/// 设置面板内容是左右分页（分类 [TabBarView]）时，分页在竞技场里赢下横拖：
/// 首页再往右甩、末页再往左甩必须交还给外层 [VideoPanelSwipeSwitch] 切相邻面板，
/// 中间页的横甩只翻分页、不切面板。
void main() {
  const List<String> tabs = <String>['t0', 't1', 't2'];

  Future<({List<String> selected, TabController controller})> pump(
    WidgetTester tester, {
    required int initialTab,
  }) async {
    final List<String> selected = <String>[];
    final ValueNotifier<String> current = ValueNotifier<String>('settings');
    addTearDown(current.dispose);
    final ReaderPanelSwitcher switcher = ReaderPanelSwitcher(
      items: const <({String id, IconData icon, String label})>[
        (id: 'subtitles', icon: Icons.subtitles, label: 'subtitles'),
        (id: 'settings', icon: Icons.settings, label: 'settings'),
        (id: 'audio', icon: Icons.audiotrack, label: 'audio'),
      ],
      current: current,
      onSelect: selected.add,
    );
    late TabController controller;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: VideoPanelSwipeSwitch(
              switcher: switcher,
              child: DefaultTabController(
                length: tabs.length,
                initialIndex: initialTab,
                child: Builder(
                  builder: (BuildContext context) {
                    controller = DefaultTabController.of(context);
                    return TabBarView(
                      children: <Widget>[
                        for (final String id in tabs)
                          ListView(
                            key: PageStorageKey<String>(id),
                            children: <Widget>[
                              for (int i = 0; i < 30; i++)
                                ListTile(title: Text('$id row $i')),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (selected: selected, controller: controller);
  }

  Future<void> fling(WidgetTester tester, double dx) async {
    await tester.fling(find.byType(TabBarView), Offset(dx, 0), 1200);
    await tester.pumpAndSettle();
  }

  testWidgets('首页再往右甩：交给外层切到上一个面板，分页不动', (tester) async {
    final r = await pump(tester, initialTab: 0);
    await fling(tester, 300);
    expect(r.selected, <String>['subtitles']);
    expect(r.controller.index, 0);
  });

  testWidgets('末页再往左甩：交给外层切到下一个面板，分页不动', (tester) async {
    final r = await pump(tester, initialTab: 2);
    await fling(tester, -300);
    expect(r.selected, <String>['audio']);
    expect(r.controller.index, 2);
  });

  testWidgets('中间页左右甩只翻分页，不切面板', (tester) async {
    final r = await pump(tester, initialTab: 1);
    await fling(tester, -300);
    expect(r.controller.index, 2);
    expect(r.selected, isEmpty);

    await fling(tester, 300);
    expect(r.controller.index, 1);
    expect(r.selected, isEmpty);
  });

  testWidgets('首页往左甩是翻到下一页，不切面板', (tester) async {
    final r = await pump(tester, initialTab: 0);
    await fling(tester, -300);
    expect(r.controller.index, 1);
    expect(r.selected, isEmpty);
  });

  testWidgets('鼠标横拖越界不切面板（只认触摸 / 触控笔）', (tester) async {
    final r = await pump(tester, initialTab: 0);
    await tester.fling(
      find.byType(TabBarView),
      const Offset(300, 0),
      1200,
      deviceKind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(r.selected, isEmpty);
  });

  test('edgeHandoffTarget：RTL 下分页方向镜像', () {
    final ValueNotifier<String> current = ValueNotifier<String>('b');
    addTearDown(current.dispose);
    final ReaderPanelSwitcher sw = ReaderPanelSwitcher(
      items: const <({String id, IconData icon, String label})>[
        (id: 'a', icon: Icons.abc, label: 'a'),
        (id: 'b', icon: Icons.abc, label: 'b'),
        (id: 'c', icon: Icons.abc, label: 'c'),
      ],
      current: current,
      onSelect: (_) {},
    );
    // RTL：首页在 min 端，手指往左推才是往 min 推。
    expect(
      VideoPanelSwipeSwitch.edgeHandoffTarget(
        sw,
        startedAtMin: true,
        startedAtMax: false,
        endedAtMin: true,
        endedAtMax: false,
        axisDirection: AxisDirection.left,
        velocityDx: -1000,
      ),
      'c',
    );
    expect(
      VideoPanelSwipeSwitch.edgeHandoffTarget(
        sw,
        startedAtMin: true,
        startedAtMax: false,
        endedAtMin: true,
        endedAtMax: false,
        axisDirection: AxisDirection.left,
        velocityDx: 1000,
      ),
      isNull,
    );
    // 中途拖离边界后再甩回来不算越界。
    expect(
      VideoPanelSwipeSwitch.edgeHandoffTarget(
        sw,
        startedAtMin: true,
        startedAtMax: false,
        endedAtMin: false,
        endedAtMax: false,
        axisDirection: AxisDirection.right,
        velocityDx: 1000,
      ),
      isNull,
    );
  });
}
