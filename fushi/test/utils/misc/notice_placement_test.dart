// 短时通知避让页面 chrome（用户 2026-11-22：漫画有声模式的结果卡压在播放底栏上；
// 视频 OSD 顶栏收起后仍空着顶栏那段）。纯函数表测 + 真实 FushiChromeReveal 登记后
// toast 让到底栏上方的 widget 测。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/notice_placement.dart';
import 'package:material_ui/material_ui.dart';

NoticeObstacle _bar(
  NoticeObstacleEdge edge,
  Rect rect, [
  double presence = 1,
]) => (edge: edge, rect: rect, presence: presence);

void main() {
  group('noticeBottomOffset', () {
    const double h = 800;
    double bottom(Iterable<NoticeObstacle> obstacles) => noticeBottomOffset(
      overlayHeight: h,
      fallback: 50,
      obstacles: obstacles,
      laneLeft: 300,
      laneRight: 700,
    );

    test('没有 chrome：用默认底距', () {
      expect(bottom(const <NoticeObstacle>[]), 50);
    });

    test('底栏完全显示：让到栏上沿再往上 12', () {
      // 栏占 640..800（漫画有声：播放条 + 页码滑条，比默认底距高）。
      expect(
        bottom(<NoticeObstacle>[
          _bar(
            NoticeObstacleEdge.bottom,
            const Rect.fromLTWH(0, 640, 1000, 160),
          ),
        ]),
        800 - 640 + 12,
      );
    });

    test('底栏比默认底距矮：不往下压，保持默认', () {
      expect(
        bottom(<NoticeObstacle>[
          _bar(
            NoticeObstacleEdge.bottom,
            const Rect.fromLTWH(0, 780, 1000, 20),
          ),
        ]),
        50,
      );
    });

    test('进退场途中按显隐进度插值；收起完不算', () {
      const Rect r = Rect.fromLTWH(0, 640, 1000, 160);
      expect(
        bottom(<NoticeObstacle>[_bar(NoticeObstacleEdge.bottom, r, 0.5)]),
        50 + (172 - 50) * 0.5,
      );
      expect(
        bottom(<NoticeObstacle>[_bar(NoticeObstacleEdge.bottom, r, 0)]),
        50,
      );
    });

    test('不横在通知通道上的栏 / 顶栏不影响底距；多块取最高', () {
      expect(
        bottom(<NoticeObstacle>[
          // 只在左侧的竖条。
          _bar(
            NoticeObstacleEdge.bottom,
            const Rect.fromLTWH(0, 400, 200, 400),
          ),
          _bar(NoticeObstacleEdge.top, const Rect.fromLTWH(0, 0, 1000, 300)),
        ]),
        50,
      );
      expect(
        bottom(<NoticeObstacle>[
          _bar(
            NoticeObstacleEdge.bottom,
            const Rect.fromLTWH(0, 700, 1000, 100),
          ),
          _bar(
            NoticeObstacleEdge.bottom,
            const Rect.fromLTWH(0, 600, 1000, 60),
          ),
        ]),
        800 - 600 + 12,
      );
    });
  });

  group('noticeTopOffset（视频顶栏）', () {
    double top(double presence) => noticeTopOffset(
      fallback: 12,
      obstacles: <NoticeObstacle>[
        _bar(
          NoticeObstacleEdge.top,
          const Rect.fromLTWH(0, 0, 1, 56),
          presence,
        ),
      ],
      laneLeft: 0,
      laneRight: 1,
      gap: 8,
    );

    test('顶栏显示：落在栏下沿下方；收起：贴回安全区顶；过渡中平滑', () {
      expect(top(1), 64);
      expect(top(0), 12);
      expect(top(0.5), 12 + (64 - 12) * 0.5);
    });
  });

  testWidgets('页面底栏（FushiChromeReveal from: down）登记后，结果卡让到栏上方；栏收起后回落', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    addTearDown(FushiToast.debugReset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (BuildContext context, bool v, Widget? _) =>
                      FushiChromeReveal(
                        visible: v,
                        from: AxisDirection.down,
                        child: const SizedBox(
                          key: ValueKey<String>('bottom-bar'),
                          height: 180,
                        ),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FushiNoticeObstacles.instance.debugEntryCount, greaterThan(0));

    FushiToast.showMine(msg: '卡片已导出', status: MineToastStatus.failed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final Rect bar = tester.getRect(
      find.byKey(const ValueKey<String>('bottom-bar')),
    );
    final Rect card = tester.getRect(find.byType(FushiMineNoticeCard));
    expect(card.bottom, lessThanOrEqualTo(bar.top - 12 + 0.5));
    expect(card.overlaps(bar), isFalse, reason: '结果卡不许压在底栏上');

    visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // 登记表在帧后发通知（build / layout 阶段不能让 toast setState），toast 下一帧跟上。
    await tester.pump();
    final Rect after = tester.getRect(find.byType(FushiMineNoticeCard));
    expect(after.bottom, greaterThan(card.bottom), reason: '栏收起后卡片回落到默认底距');
    // 失败卡停 8 秒：用例内收掉，不留计时器给框架的收尾检查。
    FushiToast.debugReset();
    await tester.pump(const Duration(seconds: 1));
  });
}
