import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 库页条目材质（2026-10-25 定版）：光面书皮 / 光面海报 / 透明卡盒 + 扇形 /
/// 叠层 + 接触阴影 + 悬停扫光，封面下文字块 [ShelfCardMeta] 承接原角标信息。
void main() {
  Widget harness(
    Widget child, {
    ShelfCoverMaterial? material,
    bool eink = false,
  }) {
    final Widget scoped = material == null
        ? child
        : ShelfCoverMaterialScope(material: material, child: child);
    return MaterialApp(
      theme: ThemeData(
        extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
      ),
      home: Scaffold(
        body: Center(child: SizedBox(width: 120, height: 170, child: scoped)),
      ),
    );
  }

  Widget cover(String id) => ColoredBox(
    key: ValueKey<String>('cover-$id'),
    color: const Color(0xFF336699),
  );

  testWidgets('没有材质 scope 时封面框保持原样', (WidgetTester tester) async {
    await tester.pumpWidget(harness(ShelfCoverFrame(child: cover('a'))));
    expect(find.byType(ShelfMaterialSurface), findsNothing);
    expect(find.byType(ShelfContactShadow), findsNothing);
  });

  testWidgets('光面书皮：单张封面带接触阴影，圆角取材质', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(child: cover('a')),
        material: ShelfCoverMaterial.glossyBook,
      ),
    );
    expect(find.byType(ShelfMaterialSurface), findsOneWidget);
    expect(find.byType(ShelfContactShadow), findsOneWidget);
    final BuildContext ctx = tester.element(
      find.byKey(const ValueKey<String>('cover-a')),
    );
    expect(
      shelfCoverRadius(ctx),
      shelfMaterialRadius(ShelfCoverMaterial.glossyBook),
    );
  });

  testWidgets('墨水屏下不走材质', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(child: cover('a')),
        material: ShelfCoverMaterial.glossyBook,
        eink: true,
      ),
    );
    expect(find.byType(ShelfMaterialSurface), findsNothing);
  });

  testWidgets('书 / 卡盒多本是扇形：最多 4 本，后层转开', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(
          stackedCovers: <Widget>[
            cover('b'),
            cover('c'),
            cover('d'),
            cover('e'),
          ],
          child: cover('a'),
        ),
        material: ShelfCoverMaterial.gameCase,
      ),
    );
    expect(find.byType(ShelfMaterialSurface), findsNWidgets(4));
    expect(find.byKey(const ValueKey<String>('cover-e')), findsNothing);
    final Iterable<double> turns = tester
        .widgetList<AnimatedRotation>(find.byType(AnimatedRotation))
        .map((AnimatedRotation r) => r.turns);
    expect(turns.where((double t) => t != 0), hasLength(3));
  });

  testWidgets('海报多季是右上叠层：最多 3 季', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(
          stackedCovers: <Widget>[cover('b'), cover('c'), cover('d')],
          child: cover('a'),
        ),
        material: ShelfCoverMaterial.glossyPoster,
      ),
    );
    expect(find.byType(ShelfMaterialSurface), findsNWidgets(3));
    expect(find.byType(AnimatedRotation), findsNothing);
    final List<Offset> slides = tester
        .widgetList<AnimatedSlide>(find.byType(AnimatedSlide))
        .map((AnimatedSlide s) => s.offset)
        .toList();
    // 后层往右上错开（x 正、y 负）。
    expect(slides.every((Offset o) => o.dx > 0 && o.dy < 0), isTrue);
  });

  testWidgets('悬停时柔光扫过、接触阴影收窄', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        FushiHoverLift(
          builder: (BuildContext _, bool __) =>
              ShelfCoverFrame(child: cover('a')),
        ),
        material: ShelfCoverMaterial.glossyPoster,
      ),
    );
    ShelfCoverSheen sheen() =>
        tester.widget<ShelfCoverSheen>(find.byType(ShelfCoverSheen));
    ShelfContactShadow shadow() =>
        tester.widget<ShelfContactShadow>(find.byType(ShelfContactShadow));
    expect(sheen().active, isFalse);
    expect(shadow().lifted, isFalse);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(ShelfMaterialSurface)));
    await tester.pumpAndSettle();
    expect(sheen().active, isTrue);
    expect(shadow().lifted, isTrue);
  });

  testWidgets('文字块：副行承接角标信息，错误语气用 error 色', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        const ShelfCardMeta(
          title: '新装版 タイム・リープ',
          subtitle: '对齐失败 · 12%',
          leadingIcon: Icons.warning_amber_rounded,
          tone: ShelfMetaTone.error,
          progress: 0.12,
        ),
      ),
    );
    expect(find.text('新装版 タイム・リープ'), findsOneWidget);
    final Text sub = tester.widget<Text>(find.text('对齐失败 · 12%'));
    final BuildContext ctx = tester.element(find.text('对齐失败 · 12%'));
    expect(sub.style?.color, Theme.of(ctx).colorScheme.error);
    expect(find.byType(FractionallySizedBox), findsOneWidget);
  });
}
