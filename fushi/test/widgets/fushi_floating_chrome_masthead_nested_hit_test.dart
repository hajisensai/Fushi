// BUG-5544 / 反馈 ki-PPMWRKt（Windows 1206x720，MD3 页头大字外壳，视频媒体库）：列表滚下去
// 再往回轻滑唤回顶栏后，页头下的标签筛选栏看得见却点不动，只有滚回最顶端才能
// 选中 / 取消标签。
//
// 根因：嵌套 [FushiFloatingChromeOverlay] 里，页头收短 `collapse` 的那段上移
// （`Transform.translate`）包在 ExcludeSemantics / IgnorePointer / 淡出里面。外面
// 这几层仍按 `outer` 原位的 size 判命中，[RenderTransform] 只平移绘制：桌面宽窗
// collapse ≈ 62 px 超过整行高度，上移后的标签行整行落在命中盒外。
//
// 两套设计系统各钉一处：
// - MD3：滚到页头完全收缩后，tap 嵌套行里的标签必须触发回调。
// - Apple：嵌套行随内容滚到导航栏背后（不吸顶），藏在槽位上沿以上的那截不得
//   被点穿；槽位里还露出的部分照常可点。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

const Key _tagKey = ValueKey<String>('nested-tag');
const Key _nestedRowKey = ValueKey<String>('nested-row');

ThemeData _theme({required bool apple}) => ThemeData(
  extensions: <ThemeExtension<dynamic>>[
    if (apple)
      const FushiGlassTheme(FushiGlassMaterial.standard, glassDesign: true),
  ],
);

Widget _harness({
  required bool apple,
  required FushiFloatingChromeController controller,
  required FushiShellActionsSlot slot,
  required ScrollController scroll,
  required VoidCallback onTag,
}) {
  return MaterialApp(
    theme: _theme(apple: apple),
    home: Scaffold(
      body: FushiShellTitleScope(
        title: 'Video',
        child: FushiFloatingChromeScope(
          controller: controller,
          child: FushiFloatingChromeOverlay(
            masthead: true,
            chrome: FushiFloatingChromeBar(
              tabs: const SizedBox.shrink(),
              slot: slot,
            ),
            child: FushiFloatingChromeOverlay(
              // 视频库的标签筛选栏形态：一行 48 px 的标签。
              chrome: SizedBox(
                key: _nestedRowKey,
                height: 48,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 24),
                    SizedBox(
                      key: _tagKey,
                      width: 120,
                      height: 48,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTag,
                        child: const Text('tag'),
                      ),
                    ),
                  ],
                ),
              ),
              child: Builder(
                builder: (BuildContext context) => ListView.builder(
                  controller: scroll,
                  padding: EdgeInsets.only(
                    top: FushiFloatingChromeInset.of(context),
                  ),
                  itemCount: 60,
                  itemBuilder: (BuildContext context, int i) =>
                      SizedBox(height: 120, child: Text('item $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pumpHarness(
    WidgetTester tester, {
    required bool apple,
    required ScrollController scroll,
    required VoidCallback onTag,
  }) async {
    tester.view.physicalSize = const Size(1206, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    addTearDown(slot.dispose);
    await tester.pumpWidget(
      _harness(
        apple: apple,
        controller: controller,
        slot: slot,
        scroll: scroll,
        onTag: onTag,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('MD3 宽窗：页头完全收缩后，嵌套标签行照常可点', (WidgetTester tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    int taps = 0;
    await pumpHarness(
      tester,
      apple: false,
      scroll: scroll,
      onTag: () => taps++,
    );

    final double restTop = tester.getTopLeft(find.byKey(_tagKey)).dy;
    // 往下滚一大段（顶栏收起），再往回轻滑唤回顶栏：页头停在完全收缩态。
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(300), reason: '前提：内容仍在页头底下');

    final double collapsedTop = tester.getTopLeft(find.byKey(_tagKey)).dy;
    expect(
      restTop - collapsedTop,
      greaterThan(48),
      reason: '前提：页头收缩把标签行上移超过整行高度（反馈里整行点不动的形态）',
    );

    await tester.tap(find.byKey(_tagKey));
    await tester.pump();
    expect(taps, 1, reason: '收缩后上移的标签行必须在它画出来的位置接点击');
    // 标签行上半截（原先窄窗的死区）也要接得住。
    await tester.tapAt(
      tester.getTopLeft(find.byKey(_tagKey)) + const Offset(10, 4),
    );
    await tester.pump();
    expect(taps, 2);
  });

  testWidgets('Apple 宽窗：嵌套行随内容滚到导航栏背后，藏起的那截不被点穿', (WidgetTester tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    int taps = 0;
    await pumpHarness(tester, apple: true, scroll: scroll, onTag: () => taps++);

    final Offset restTopLeft = tester.getTopLeft(find.byKey(_tagKey));
    // 滚一小段：标签行上移 24 px。槽位上沿在标签上方 nestedGap（8 px）处，于是
    // 标签上沿 16 px 藏到槽位（导航栏）以上，下面 32 px 还露在槽位里。
    scroll.jumpTo(24);
    await tester.pumpAndSettle();
    final double shift =
        restTopLeft.dy - tester.getTopLeft(find.byKey(_tagKey)).dy;
    expect(shift, moreOrLessEquals(24), reason: '前提：Apple 嵌套行随内容滚走');

    // 槽位里还露出的下半截照常可点。
    await tester.tapAt(restTopLeft + const Offset(10, 12));
    await tester.pump();
    expect(taps, 1, reason: '露在槽位里的那截标签照常可点');

    // 已经滚到槽位上沿以上（导航栏背后）的那截不接点击。
    await tester.tapAt(restTopLeft + const Offset(10, -20));
    await tester.pump();
    expect(taps, 1, reason: '藏在导航栏背后的嵌套行不得被点穿');
  });
}
