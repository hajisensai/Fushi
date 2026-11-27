import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5535：推入 / 弹出二级页时，被盖住的那一页在转场途中画快照
/// （[FushiCoveredPageSnapshot]），不逐帧实时重画整页。
///
/// 用 Apple 设计系统的主题（用户报掉帧时的设置：Cupertino 推入，旧页视差左移）。
/// 旧页在 UI 侧不重画（路由的 RepaintBoundary 层被复用），但桌面 Impeller 没有
/// raster cache，每帧都要把它整页的绘制命令重放一遍；快照把这部分换成贴一张图。
void main() {
  ThemeData theme() => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glassDesign: true,
  );

  SnapshotController controllerAbove(WidgetTester tester, Finder content) =>
      tester
          .widget<SnapshotWidget>(
            find
                .ancestor(
                  of: content,
                  matching: find.byType(SnapshotWidget, skipOffstage: false),
                )
                .first,
          )
          .controller;

  Widget page(String label) => Scaffold(body: Center(child: Text(label)));

  testWidgets('covered page is drawn from a snapshot during the push and pop '
      'transitions, from the third frame on', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    const Key home = ValueKey<String>('home');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: theme(),
        home: const _PaintCounter(key: home, child: Text('library')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isFalse,
    );

    unawaited(
      nav.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => page('detail')),
      ),
    );
    await tester.pump();
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isFalse,
      reason: '第 1 帧照常实时画（Hero 还没起飞、isCurrent 重建还在这一帧）',
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isTrue,
      reason: '第 2 帧画完后开拍',
    );
    final int before = _PaintCounter.paints;
    for (int f = 0; f < 20; f++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      _PaintCounter.paints - before,
      lessThanOrEqualTo(1),
      reason: '开拍后只为快照完整画一次，之后贴图',
    );
    await tester.pumpAndSettle();
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isFalse,
      reason: '转场落定回实时绘制',
    );

    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isTrue,
      reason: '返回途中重新露出的页同样画快照',
    );
    await tester.pumpAndSettle();
    expect(
      controllerAbove(
        tester,
        find.byKey(home, skipOffstage: false),
      ).allowSnapshotting,
      isFalse,
    );
    expect(find.text('library'), findsOneWidget);
  });

  testWidgets('snapshot starts only after the source Hero has become a '
      'placeholder', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    const Key source = ValueKey<String>('source-cover');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: theme(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Hero(
              tag: 'cover',
              child: SizedBox(key: source, width: 40, height: 60),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder sourceHero = find.byType(Hero).first;

    unawaited(
      nav.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: Center(
              child: Hero(
                tag: 'cover',
                child: SizedBox(width: 120, height: 180),
              ),
            ),
          ),
        ),
      ),
    );
    // 逐帧推进，直到开拍的那一帧：此时起点 Hero 必须已经换成占位（它的子树
    // 不在场），否则快照里会留下一个重影。
    for (int f = 0; f < 10; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (controllerAbove(tester, sourceHero).allowSnapshotting) break;
    }
    expect(controllerAbove(tester, sourceHero).allowSnapshotting, isTrue);
    expect(
      find.descendant(of: sourceHero, matching: find.byKey(source)),
      findsNothing,
      reason: '起点 Hero 已经起飞（占位），快照里不会有它',
    );
    await tester.pumpAndSettle();
  });
}

/// 数自己的子树被实时绘制了几次（画快照时不调用）。
class _PaintCounter extends SingleChildRenderObjectWidget {
  const _PaintCounter({super.key, super.child});

  static int paints = 0;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCounter();
}

class _RenderCounter extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    _PaintCounter.paints++;
    super.paint(context, offset);
  }
}
