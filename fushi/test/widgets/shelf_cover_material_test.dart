import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
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

  // 2026-10-25 用户：合集扇形「克制一点，别出界、别和侧边重叠太多」。
  test('扇形角度上限按几何反推：转开后外角正好贴住允许的半宽', () {
    const double w = 120;
    const double itemW = w;
    const double itemH = 150;
    const double limit = w / 2 + w * kShelfFanOverhang;
    final double deg = shelfFanMaxDegrees(
      itemW: itemW,
      itemH: itemH,
      halfLimit: limit,
    );
    expect(deg, greaterThan(0));
    expect(deg, lessThanOrEqualTo(kShelfFanMaxDegrees));
    final double rad = deg * math.pi / 180;
    expect(
      itemW / 2 * math.cos(rad) + itemH * math.sin(rad),
      moreOrLessEquals(limit, epsilon: 0.01),
    );
    // 没有余量时不转；宽到怎么转都放得下时封顶。
    expect(
      shelfFanMaxDegrees(itemW: itemW, itemH: itemH, halfLimit: itemW / 2),
      0,
    );
    expect(
      shelfFanMaxDegrees(itemW: 10, itemH: 10, halfLimit: 1000),
      kShelfFanMaxDegrees,
    );
  });

  testWidgets('合集最前那本与单本同大（用户：单本和合集大小不协调）', (WidgetTester tester) async {
    Future<Size> frontSize(List<Widget>? behind) async {
      await tester.pumpWidget(
        harness(
          ShelfCoverFrame(stackedCovers: behind, child: cover('a')),
          material: ShelfCoverMaterial.glossyBook,
        ),
      );
      return tester.getSize(
        find
            .ancestor(
              of: find.byKey(const ValueKey<String>('cover-a')),
              matching: find.byType(ShelfMaterialSurface),
            )
            .first,
      );
    }

    final Size single = await frontSize(null);
    final Size pile = await frontSize(<Widget>[cover('b'), cover('c')]);
    expect(pile, single);
  });

  testWidgets('扇形悬停时最远那本也不超出格子允许的范围', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        FushiHoverLift(
          builder: (BuildContext _, bool __) => ShelfCoverFrame(
            stackedCovers: <Widget>[cover('b'), cover('c'), cover('d')],
            child: cover('a'),
          ),
        ),
        material: ShelfCoverMaterial.glossyBook,
      ),
    );
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ShelfCoverFrame)));
    await tester.pumpAndSettle();
    final Size slot = tester.getSize(find.byType(ShelfCoverPile));
    final double maxDeg = tester
        .widgetList<AnimatedRotation>(find.byType(AnimatedRotation))
        .map((AnimatedRotation r) => (r.turns * 360).abs())
        .reduce(math.max);
    final Size item = tester.getSize(find.byType(ShelfMaterialSurface).first);
    final double rad = maxDeg * math.pi / 180;
    final double reach =
        item.width / 2 * math.cos(rad) + item.height * math.sin(rad);
    expect(maxDeg, greaterThan(0));
    expect(
      reach,
      lessThanOrEqualTo(slot.width / 2 + slot.width * kShelfFanOverhang + 0.01),
    );
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

  testWidgets('专辑唱片材质：8dp 圆角、1:1、多张走右上叠层', (WidgetTester tester) async {
    expect(kShelfAlbumAspectRatio, 1);
    expect(
      shelfMaterialRadius(ShelfCoverMaterial.glossyAlbum),
      const BorderRadius.all(Radius.circular(8)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 150,
              child: AspectRatio(
                aspectRatio: kShelfAlbumAspectRatio,
                child: ShelfCoverMaterialScope(
                  material: ShelfCoverMaterial.glossyAlbum,
                  child: ShelfCoverFrame(
                    stackedCovers: <Widget>[cover('b'), cover('c')],
                    child: cover('a'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ShelfMaterialSurface), findsNWidgets(3));
    expect(find.byType(AnimatedRotation), findsNothing);
    expect(find.byType(ShelfContactShadow), findsOneWidget);
    final BuildContext ctx = tester.element(
      find.byKey(const ValueKey<String>('cover-a')),
    );
    expect(
      shelfCoverRadius(ctx),
      shelfMaterialRadius(ShelfCoverMaterial.glossyAlbum),
    );
    final Size front = tester.getSize(find.byType(ShelfMaterialSurface).last);
    expect(front.width, closeTo(front.height, 0.01));
  });

  testWidgets('简化档：无接触阴影 / 投影 / 扫光 / 叠层 / 勾选圈，悬停不抬', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 44,
            height: 62,
            child: ShelfCoverSelection(
              selectionMode: true,
              selected: true,
              child: FushiHoverLift(
                builder: (BuildContext _, bool __) => ShelfCoverFrame(
                  density: ShelfCoverDensity.compact,
                  stackedCovers: <Widget>[cover('b'), cover('c')],
                  child: cover('a'),
                ),
              ),
            ),
          ),
        ),
        material: ShelfCoverMaterial.glossyBook,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ShelfMaterialSurface), findsOneWidget);
    expect(find.byType(ShelfCoverPile), findsNothing);
    expect(find.byType(ShelfContactShadow), findsNothing);
    expect(find.byType(ShelfCoverSheen), findsNothing);
    expect(find.byKey(const ValueKey<String>('cover-b')), findsNothing);
    expect(find.byType(ShelfSelectionCheck), findsNothing);
    expect(find.byType(ShelfSelectedOverlay), findsOneWidget);
    final ShelfMaterialSurface surface = tester.widget<ShelfMaterialSurface>(
      find.byType(ShelfMaterialSurface),
    );
    expect(surface.compact, isTrue);
    BoxDecoration decoration() =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byType(ShelfMaterialSurface),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(decoration().boxShadow, isEmpty);
    // 圆角 / 内描边仍在：外轮廓取材质圆角。
    expect(
      decoration().borderRadius,
      shelfMaterialRadius(ShelfCoverMaterial.glossyBook),
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(ShelfMaterialSurface)));
    await tester.pumpAndSettle();
    expect(find.byType(ShelfCoverSheen), findsNothing);
    expect(decoration().boxShadow, isEmpty);
  });

  testWidgets('简化档没有材质 scope 时也不画叠层与投影', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(
          density: ShelfCoverDensity.compact,
          stackedBehind: cover('b'),
          child: cover('a'),
        ),
      ),
    );
    expect(find.byKey(const ValueKey<String>('cover-b')), findsNothing);
    expect(find.byType(ShelfMaterialSurface), findsNothing);
  });

  testWidgets('默认档仍画投影（简化档对照）', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        ShelfCoverFrame(child: cover('a')),
        material: ShelfCoverMaterial.glossyBook,
      ),
    );
    final AnimatedContainer box = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ShelfMaterialSurface),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((box.decoration! as BoxDecoration).boxShadow, isNotEmpty);
    expect(find.byType(ShelfCoverSheen), findsOneWidget);
  });

  for (final double width in <double>[60, 160, 320]) {
    testWidgets('16:9 剧照（海报材质横版）宽 $width 不溢出、按实际尺寸铺满', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: AspectRatio(
                  aspectRatio: kShelfLandscapeAspectRatio,
                  child: ShelfCoverMaterialScope(
                    material: ShelfCoverMaterial.glossyPoster,
                    child: FushiHoverLift(
                      builder: (BuildContext _, bool __) =>
                          ShelfCoverFrame(child: cover('a')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final Size surface = tester.getSize(find.byType(ShelfMaterialSurface));
      expect(surface.width, closeTo(width, 0.01));
      expect(surface.height, closeTo(width * 9 / 16, 0.01));
      expect(find.byType(ShelfContactShadow), findsOneWidget);
      // 接触阴影随封面宽度走（1.07 倍），不按 2:3 写死。
      final Size shadow = tester.getSize(
        find.descendant(
          of: find.byType(ShelfContactShadow),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(shadow.width, closeTo(width * 1.07, 0.01));
      // 悬停扫光在横版里同样铺满封面、不溢出。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(ShelfMaterialSurface)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ShelfCoverSheen)),
        Size(width, width * 9 / 16),
      );
      await tester.pumpAndSettle();
    });
  }

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
    // 进度条走 M3E 平直静止形态（与继续卡同一组件，2026-10-28）。
    final FushiLinearProgressIndicator bar = tester
        .widget<FushiLinearProgressIndicator>(
          find.byType(FushiLinearProgressIndicator),
        );
    expect(bar.value, 0.12);
    expect(bar.wavy, isFalse);
  });

  testWidgets('副行标签：色点 + 名字，不加 # 前缀，超出收成 +N', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        const ShelfCardMeta(
          title: '転生王女と天才令嬢の魔法革命',
          subtitle: '读完',
          trailing: ShelfMetaTags(
            tags: <ShelfMetaTag>[
              (label: '4⭐', color: Color(0xFF3F51B5)),
              (label: '百合', color: null),
              (label: '轻小说', color: Color(0xFFE91E63)),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('4⭐'), findsOneWidget);
    expect(find.text('百合'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.textContaining('#'), findsNothing, reason: '用户：「#4⭐」太抽象');
    expect(find.text('读完'), findsOneWidget);
  });

  testWidgets('副行尾部最多占六成宽，状态文字始终留得出地方', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        const ShelfCardMeta(
          title: 't',
          subtitle: '继续看 第19集',
          trailing: ShelfMetaTags(
            tags: <ShelfMetaTag>[(label: '一个非常非常非常长的标签名字', color: null)],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final double rowWidth = tester.getSize(find.byType(ShelfCardMeta)).width;
    final double tagsWidth = tester.getSize(find.byType(ShelfMetaTags)).width;
    expect(tagsWidth, lessThanOrEqualTo(rowWidth * 0.6 + 0.01));
    expect(tester.getSize(find.text('继续看 第19集')).width, greaterThan(0));
  });
}
