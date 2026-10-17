import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_chrome_hit_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoControlsChromeRegion;

/// 视频页「点在控件上还是点在画面上」走真实 hit-test（[videoPointerHitsChrome]）。
///
/// 回归形态：M3E 浮动底栏比旧几何判据的那条「按钮行高」带高，连点 +10s 的上半截被
/// 当成双击画面 → 切全屏。这里用一个 600×400 的假播放区复现几何：底栏区域 120 高
/// （远高于旧判据的 56），浮层按钮放在画面中部，逐点断言判据。
void main() {
  const Key seekForwardKey = Key('seek-forward');
  const Key floatingButtonKey = Key('floating-button');

  Future<void> pumpSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Stack(
            children: <Widget>[
              // 画面：铺满的 translucent 手势层（对应 media_kit 的点画面路由）。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {},
                ),
              ),
              // 底栏：120 高的控件区域，按钮只占中间一小块，其余是空隙。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 120,
                child: VideoControlsChromeRegion(
                  child: Center(
                    child: InkWell(
                      key: seekForwardKey,
                      onTap: () {},
                      child: const SizedBox(width: 60, height: 30),
                    ),
                  ),
                ),
              ),
              // 不属于 media_kit 控制条的浮层按钮（侧边动作栏 / 自动连播卡这类）。
              Positioned(
                left: 20,
                top: 150,
                child: InkWell(
                  key: floatingButtonKey,
                  onTap: () {},
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool hitsChrome(WidgetTester tester, Offset position) =>
      videoPointerHitsChrome(
        globalPosition: position,
        viewId: tester.view.viewId,
      );

  testWidgets('画面空白处不是控件', (WidgetTester tester) async {
    await pumpSurface(tester);
    expect(hitsChrome(tester, const Offset(300, 120)), isFalse);
  });

  testWidgets('底栏按钮与按钮间空隙都是控件', (WidgetTester tester) async {
    await pumpSurface(tester);
    expect(
      hitsChrome(tester, tester.getCenter(find.byKey(seekForwardKey))),
      isTrue,
    );
    expect(
      hitsChrome(tester, const Offset(40, 380)),
      isTrue,
      reason: '底栏区域内按钮旁的空隙也算控制条',
    );
  });

  testWidgets('旧几何带（底边 56px）之外的底栏上半截仍是控件', (WidgetTester tester) async {
    await pumpSurface(tester);
    // 400 - 56 = 344 以上：旧判据在这里判「画面」，连点两次即双击全屏。
    expect(hitsChrome(tester, const Offset(300, 300)), isTrue);
  });

  testWidgets('控制条外的浮层按钮是控件', (WidgetTester tester) async {
    await pumpSurface(tester);
    expect(
      hitsChrome(tester, tester.getCenter(find.byKey(floatingButtonKey))),
      isTrue,
    );
  });
}
