// BUG-3075：M3E 悬浮顶栏（FushiAppBar）滚动后，栏下沿的渐隐遮罩把返回圆 /
// 标题胶囊 / 动作胶囊落在栏外的悬浮投影整片盖掉，胶囊下半圈像被切平。
// 同时覆盖合集详情使用的 extendBodyBehindAppBar 分支，防止共享层回归。
//
// 根因：_buildFloating 的 Stack 里，普通 Scaffold 那支遮罩（栏下沿起画、顶边
// 不透明度 1）排在 `bar` 之后，绘制在胶囊之上。BUG-2977 已经让 AppBar 不再裁
// 投影，但投影随后又被遮罩盖住。守住：两种遮罩都画在栏之下；滚动后返回圆
// 正下方、栏下沿外仍看得见投影。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
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

      testWidgets('BUG-3075 滚动后返回圆的投影越过栏下沿、不被遮罩截平', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(392, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final GlobalKey boundaryKey = GlobalKey();
        await tester.pumpWidget(
          _harness(boundaryKey: boundaryKey, bodyBehindBar: bodyBehindBar),
        );
        await tester.pump();

        // 往下滚：内容进到栏底下，遮罩淡入（返回圆常驻，标题 / 动作随滚动收起）。
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();

        final Rect bar = tester.getRect(find.byType(AppBar));
        final Rect circle = tester.getRect(find.byType(FushiPageChromeCircle));
        expect(circle.bottom, lessThanOrEqualTo(bar.bottom));

        final ByteData bytes = (await tester.runAsync(() async {
          final RenderRepaintBoundary boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final ui.Image image = await boundary.toImage();
          final ByteData? data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        }))!;
        int luminanceAt(Offset p) {
          final int i = (p.dy.round() * 392 + p.dx.round()) * 4;
          return bytes.getUint8(i) +
              bytes.getUint8(i + 1) +
              bytes.getUint8(i + 2);
        }

        // 栏下沿外 2 px：返回圆正下方（投影里）与同一行远离任何胶囊处（只有
        // 不透明的遮罩 = 页面底色）对比。投影被遮罩盖住时两者一样白。
        final double y = bar.bottom + 2;
        final int underCircle = luminanceAt(Offset(circle.center.dx, y));
        final int awayFromChrome = luminanceAt(Offset(bar.width * 0.75, y));
        expect(
          awayFromChrome,
          greaterThanOrEqualTo(3 * 250),
          reason: '对照点应是页面底色',
        );
        expect(
          underCircle,
          lessThan(awayFromChrome - 6),
          reason: '返回圆正下方、栏下沿之外应仍是投影（比底色暗），而不是被遮罩切平',
        );
      });
    });
  }
}
