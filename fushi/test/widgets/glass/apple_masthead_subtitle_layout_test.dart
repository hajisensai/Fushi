// 2026-11-26 用户截图（Cupertino，词典管理「配置 · Default」副标题）：
// 1. 宽屏 / 窄屏展开态：副标题按钮漂在页面正中（大标题与分段之间居中），
//    而不是 iOS 26 `navigationSubtitle` 那样紧贴大标题、靠前对齐。
// 2. 滚动收起后：副标题整行钉在栏下，scroll edge 实底高出一截空白带。
//
// 根因：`FushiMastheadFrame` Apple 大标题分支把 subtitle 与 bottom 一起塞进
// `CrossAxisAlignment.stretch` 的吸顶列——按钮被拉满宽、文字居中；吸顶列收起后
// 停在栏下沿，实底跟着把它算进去。修法：副标题独立成槽、靠前对齐，随大标题一起
// 上移淡出；收起后栏下只剩吸顶的 bottom。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

const double _statusBar = 47;
const Key _subtitleKey = ValueKey<String>('masthead-subtitle');

Widget _phone(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      extensions: const <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.standard, glassDesign: true),
      ],
    ),
    home: Builder(
      builder: (BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: _statusBar),
          viewPadding: const EdgeInsets.only(top: _statusBar),
        ),
        child: child,
      ),
    ),
  );
}

Widget _page() => Scaffold(
  body: FushiMastheadFrame(
    title: 'Dictionaries',
    implyBack: false,
    subtitle: TextButton(
      key: _subtitleKey,
      onPressed: () {},
      child: const Text('Default'),
    ),
    body: Builder(
      builder: (BuildContext context) => ListView.builder(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        itemCount: 60,
        itemBuilder: (BuildContext context, int i) =>
            SizedBox(height: 80, child: Text('row $i')),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('副标题紧贴大标题下方、靠前对齐，不被拉满宽居中', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(_page()));
    await tester.pumpAndSettle();

    final Rect title = tester.getRect(find.byType(FushiAppleLargeTitle));
    final Rect subtitle = tester.getRect(find.byKey(_subtitleKey));
    expect(
      subtitle.width,
      lessThan(390 / 2),
      reason: '副标题按钮不能被拉满宽（拉满宽后文字居中漂在页面正中）',
    );
    expect(
      (subtitle.left - title.left).abs(),
      lessThan(8),
      reason: '副标题与大标题同一靠前起点',
    );
    // 大标题行自带 8px 底部内边距，副标题从行下沿起排。
    expect(
      subtitle.top - title.bottom,
      inInclusiveRange(0, 12),
      reason: '副标题紧贴大标题行下方',
    );
  });

  testWidgets('收起后副标题随大标题滚走，栏下不留副标题那一截空白', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_phone(_page()));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(
      find.byKey(_subtitleKey).hitTestable(),
      findsNothing,
      reason: '淡尽的副标题滑到透明栏底下，不能再接点按',
    );
    final FushiAppleScrollEdgeBackdrop edge = tester
        .widget<FushiAppleScrollEdgeBackdrop>(
          find.byType(FushiAppleScrollEdgeBackdrop),
        );
    expect(
      edge.height,
      moreOrLessEquals(_statusBar + kToolbarHeight, epsilon: 0.5),
      reason: '没有吸顶行时，收起后实底只盖状态栏 + 栏行',
    );
  });
}
