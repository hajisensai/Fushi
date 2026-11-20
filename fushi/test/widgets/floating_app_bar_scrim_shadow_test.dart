// BUG-3075：M3E 悬浮顶栏（FushiAppBar）滚动后，栏下沿的渐隐遮罩把返回圆 /
// 标题胶囊 / 动作胶囊落在栏外的悬浮投影整片盖掉，胶囊下半圈像被切平。
// 同时覆盖合集详情使用的 extendBodyBehindAppBar 分支，防止共享层回归。
//
// 根因：_buildFloating 的 Stack 里，普通 Scaffold 那支遮罩（栏下沿起画、顶边
// 不透明度 1）排在 `bar` 之后，绘制在胶囊之上。BUG-2977 已经让 AppBar 不再裁
// 投影，但投影随后又被遮罩盖住。守住：两种遮罩都画在栏之下；滚动后返回圆
// 正下方、栏下沿外仍看得见投影。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show kFushiFloatingCapsuleScale;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

const Color _kPage = Color(0xFFFFFFFF);

Widget _harness({required GlobalKey boundaryKey, required bool bodyBehindBar}) {
  return RepaintBoundary(
    key: boundaryKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: _kPage),
      home: Scaffold(
        extendBodyBehindAppBar: bodyBehindBar,
        appBar: FushiAppBar(
          // Material 下返回圆整体按 [kFushiFloatingCapsuleScale] 缩（56 → 48），
          // 在默认 56 高的栏里上下各空 4。工具栏取缩后的胶囊高，让返回圆照旧
          // 贴着栏下沿、投影越过栏下沿——这才是本测试要守的场景。
          toolbarHeight: kFushiPageChromeExtent * kFushiFloatingCapsuleScale,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {},
          ),
          title: const Text('无职转生'),
          actions: <Widget>[
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
          ],
        ),
        body: ListView.builder(
          itemCount: 40,
          itemBuilder: (BuildContext context, int index) => Container(
            height: 72,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: bodyBehindBar ? _kPage : const Color(0xFFE8EAF0),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final bool bodyBehindBar in <bool>[false, true]) {
    group('extendBodyBehindAppBar=$bodyBehindBar', () {
      testWidgets('BUG-3075 悬浮顶栏的栏下沿遮罩画在胶囊之下', (WidgetTester tester) async {
        await tester.pumpWidget(
          _harness(boundaryKey: GlobalKey(), bodyBehindBar: bodyBehindBar),
        );
        await tester.pump();

        final Element stackElement = tester.element(
          find
              .ancestor(of: find.byType(AppBar), matching: find.byType(Stack))
              .first,
        );
        final List<Element> children = <Element>[];
        stackElement.visitChildren(children.add);
        final int barIndex = children.indexWhere(
          (Element child) => child.widget is AppBar,
        );
        expect(barIndex, isNonNegative);
        final int scrimIndex = children.indexWhere(
          (Element child) => find
              .descendant(
                of: find.byElementPredicate((Element e) => e == child),
                matching: find.byType(FushiTopFadeScrim),
              )
              .evaluate()
              .isNotEmpty,
        );
        expect(scrimIndex, isNonNegative, reason: '栏下沿应有共享渐隐遮罩');
        expect(
          scrimIndex,
          lessThan(barIndex),
          reason: '遮罩必须先画、胶囊后画，否则胶囊投影在栏下沿被盖成一条直线',
        );
      });

      // 2026-11-15：顶栏改成二级页现行页头（无胶囊、无悬浮投影）。滚动后守的
      // 是：栏下沿遮罩淡入，返回键 / 页名 / 动作常驻栏内（页头大字不随滚动收走）。
      testWidgets('滚动后遮罩淡入，返回键 / 页名 / 动作留在栏内、不装胶囊', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(392, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _harness(boundaryKey: GlobalKey(), bodyBehindBar: bodyBehindBar),
        );
        await tester.pump();

        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();

        expect(find.byType(FushiPageChromeCircle), findsNothing);
        expect(find.byType(FushiPageChromeTitle), findsNothing);
        final Rect bar = tester.getRect(find.byType(AppBar));
        for (final Finder f in <Finder>[
          find.byIcon(Icons.arrow_back),
          find.text('无职转生'),
          find.byIcon(Icons.more_vert),
        ]) {
          final Rect r = tester.getRect(f);
          expect(r.top, greaterThanOrEqualTo(bar.top - 0.5), reason: '$f');
          expect(r.bottom, lessThanOrEqualTo(bar.bottom + 0.5), reason: '$f');
        }
        final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byType(FushiTopFadeScrim),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(fade.opacity, 1, reason: '内容滚到栏下后遮罩应淡入');
      });
    });
  }
}
