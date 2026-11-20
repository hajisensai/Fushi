import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart'
    show kFushiHoverLiftOverflow;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverPlaceholder;
import 'package:material_ui/material_ui.dart';

// 拼贴改版（设计稿 G2 / V1 / M2 / M3 / C1）对色块组件本身的约束：
// - G2：大字水印装在盒子里、整段完整显示，只给带封面的块，可关；
// - V1：背景剧照按原比例靠右铺，悬停只放大不横移；悬停放大不越出布局宽度；
// - M3：唱片摆法（封面 + 唱片，悬停唱片转出）；
// - M2：无封面按标题生成封面；拼贴可「只有首块加大、其余等尺寸」；
// - C1：规整摆放下相邻块间距处处一致。
void main() {
  const ValueKey<String> blockKey = ValueKey<String>('block');

  Future<void> pumpBlock(
    WidgetTester tester,
    FushiCoverBlock block, {
    Size size = const Size(480, 220),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: blockKey,
              width: size.width,
              height: size.height,
              child: block,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> hover(WidgetTester tester) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(blockKey)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  Finder fitPaint(String text) => find.byWidgetPredicate(
    (Widget w) =>
        w is CustomPaint &&
        w.painter is FushiFitTitlePainter &&
        (w.painter! as FushiFitTitlePainter).text == text,
  );

  group('G2 装盒大字', () {
    test('取盒子放得下的最大字号；最小字号都放不下返回 null', () {
      const TextStyle style = TextStyle(
        fontWeight: FontWeight.w900,
        height: 0.92,
      );
      const Size box = Size(300, 120);
      final double? size = fushiFitTitleFontSize(
        text: 'Watermark title here',
        style: style,
        box: box,
        minSize: 10,
        maxSize: 200,
        direction: TextDirection.ltr,
      );
      expect(size, isNotNull);
      TextPainter layout(
        double s, {
        String text = 'Watermark title here',
        double? width,
      }) => TextPainter(
        text: TextSpan(
          text: text,
          style: style.copyWith(fontSize: s, letterSpacing: -0.04 * s),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width ?? box.width);
      final TextPainter fit = layout(size!);
      // 原型 `span { padding-top: .1em }`：总高 + 0.1 × 字号不超过盒高。
      expect(
        fit.height + size * kFushiFitTitleTopPad,
        lessThanOrEqualTo(box.height),
      );
      // 词不拆开：最长的词整个放得进盒宽。
      expect(fit.minIntrinsicWidth, lessThanOrEqualTo(box.width + 0.5));
      // 再大一档就放不下（取的是最大值）：要么超高，要么得把词拆开。
      final TextPainter bigger = layout(size * 1.05);
      expect(
        bigger.height + size * 1.05 * kFushiFitTitleTopPad > box.height ||
            bigger.minIntrinsicWidth > box.width + 0.5,
        isTrue,
      );
      fit.dispose();
      bigger.dispose();

      // 最小字号下单词都放不进盒宽时退回词内换行，仍完整显示（不是不画）。
      const String longWord = 'Supercalifragilisticexpialidocious';
      const Size narrow = Size(120, 200);
      final double? broken = fushiFitTitleFontSize(
        text: longWord,
        style: style,
        box: narrow,
        minSize: 10,
        maxSize: 100,
        direction: TextDirection.ltr,
      );
      expect(broken, isNotNull);
      final TextPainter brokenLayout = layout(
        broken!,
        text: longWord,
        width: narrow.width,
      );
      expect(brokenLayout.height, lessThanOrEqualTo(narrow.height));
      brokenLayout.dispose();

      expect(
        fushiFitTitleFontSize(
          text: 'A very long title that cannot fit in a tiny box at all',
          style: style,
          box: const Size(40, 12),
          minSize: 10,
          maxSize: 100,
          direction: TextDirection.ltr,
        ),
        isNull,
      );
    });

    testWidgets('水印整段画在盒子里（不出血、不裁成半个字），语义只读一遍标题', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      const String title = 'K-ON!! ORIGINAL SOUND TRACK';
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: title,
          art: FushiCoverBlockArt.square,
          covers: <Widget>[ColoredBox(color: Colors.teal)],
        ),
      );
      expect(fitPaint(title), findsOneWidget);
      final Rect canvas = tester.getRect(fitPaint(title));
      final FushiFitTitlePainter painter =
          tester.widget<CustomPaint>(fitPaint(title)).painter!
              as FushiFitTitlePainter;
      final Rect text = painter.titleRect(canvas.size).shift(canvas.topLeft);
      final Rect block = tester.getRect(find.byKey(blockKey));
      expect(canvas.left, greaterThanOrEqualTo(block.left));
      expect(text.left, greaterThanOrEqualTo(canvas.left - 0.5));
      expect(text.right, lessThanOrEqualTo(canvas.right + 0.5));
      expect(text.bottom, lessThanOrEqualTo(canvas.bottom + 0.5));
      expect(find.bySemanticsLabel(title), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('没封面（生成封面）或调用方关掉时不画水印', (WidgetTester tester) async {
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'No cover',
          art: FushiCoverBlockArt.square,
          covers: <Widget>[],
        ),
      );
      expect(fitPaint('No cover'), findsNothing);

      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'Stats',
          art: FushiCoverBlockArt.square,
          watermark: false,
          covers: <Widget>[ColoredBox(color: Colors.teal)],
        ),
      );
      expect(fitPaint('Stats'), findsNothing);
    });
  });

  group('M2 生成封面', () {
    test('取 1–2 个字形：拉丁取同一词前两个，其余取首个，跳过开头括号', () {
      expect(fushiGeneratedCoverInitials('SAKURA♪SONG 02'), 'SA');
      expect(fushiGeneratedCoverInitials('「超かぐや姫！」特典CD'), '超');
      expect(fushiGeneratedCoverInitials('blast!'), 'BL');
      expect(fushiGeneratedCoverInitials('K-ON!!'), 'K');
      expect(fushiGeneratedCoverInitials('  [  ] '), '');
    });

    test('色相由标题定：同标题恒同、不同标题分得开', () {
      expect(
        fushiGeneratedCoverHue('Here, the world!'),
        fushiGeneratedCoverHue('Here, the world!'),
      );
      final Set<double> hues = <double>{
        for (final String t in <String>['A', 'B', 'C', 'Blast!', 'Re:結束バンド'])
          fushiGeneratedCoverHue(t),
      };
      expect(hues.length, greaterThan(3));
    });

    testWidgets('covers 为空时画生成封面，不画图标占位', (WidgetTester tester) async {
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'SAKURA♪SONG 02',
          art: FushiCoverBlockArt.square,
          covers: <Widget>[],
        ),
      );
      expect(find.byType(FushiGeneratedCover), findsOneWidget);
      expect(find.byType(ShelfCoverPlaceholder), findsNothing);
      // 标题文字仍只有色块文字区那一份（封面大字是画出来的）。
      expect(find.text('SAKURA♪SONG 02'), findsOneWidget);
    });
  });

  group('V1 背景剧照', () {
    const ValueKey<String> backdropKey = ValueKey<String>('backdrop');

    testWidgets('槽宽 = 块高 × 宽高比，靠右；悬停只放大、右缘不内收', (WidgetTester tester) async {
      const Size size = Size(480, 220);
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'Backdrop',
          art: FushiCoverBlockArt.portrait,
          backdrop: ColoredBox(key: backdropKey, color: Colors.indigo),
          backdropAspectRatio: 16 / 9,
          covers: <Widget>[ColoredBox(color: Colors.teal)],
        ),
        size: size,
      );
      final Rect block = tester.getRect(find.byKey(blockKey));
      final Rect rest = tester.getRect(find.byKey(backdropKey));
      expect(rest.width, moreOrLessEquals(size.height * 16 / 9));
      expect(rest.height, moreOrLessEquals(size.height));
      expect(rest.right, moreOrLessEquals(block.right));

      await hover(tester);
      final Rect hovered = tester.getRect(find.byKey(backdropKey));
      expect(hovered.right, moreOrLessEquals(block.right, epsilon: 0.5));
      expect(hovered.width, greaterThan(rest.width));
    });

    testWidgets('不给比例且取不到图源时按 16:9', (WidgetTester tester) async {
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'Landscape',
          art: FushiCoverBlockArt.landscape,
          covers: <Widget>[ColoredBox(key: backdropKey, color: Colors.indigo)],
        ),
        size: const Size(600, 204),
      );
      expect(
        tester.getSize(find.byKey(backdropKey)).width,
        moreOrLessEquals(204 * 16 / 9),
      );
    });

    test('悬停放大后贴边块整块留在布局宽度内（两侧留出溢出量）', () {
      for (final ShellContentLayout? layout in <ShellContentLayout?>[
        null,
        ShellContentLayout.collage,
      ]) {
        for (final double width in <double>[900, 1260, 1700, 2200]) {
          final FushiCoverBlockPlacement placement =
              computeFushiCoverBlockPlacement(
                width: width,
                itemCount: 20,
                layout: layout,
                targetWidth: kFushiCoverBlockTargetWidthMedia,
              );
          expect(placement.inset, greaterThan(0));
          for (final FushiCoverBlockRow row in placement.rows) {
            for (final FushiCoverBlockCell cell in row.cells) {
              final double grow = cell.rect.width * kFushiHoverLiftOverflow;
              expect(
                cell.rect.left - grow,
                greaterThanOrEqualTo(-0.01),
                reason: '$layout $width #${cell.index}',
              );
              expect(
                cell.rect.right + grow,
                lessThanOrEqualTo(width + 0.01),
                reason: '$layout $width #${cell.index}',
              );
            }
          }
        }
      }
    });
  });

  group('M3 唱片摆法', () {
    const ValueKey<String> discKey = ValueKey<String>('disc');
    const ValueKey<String> coverKey = ValueKey<String>('cover');

    for (final Size size in <Size>[
      const Size(420, 204),
      const Size(220, 270),
    ]) {
      testWidgets(
        '${size.width}×${size.height}：封面 + 唱片 + 标题大字 + CD chip，悬停唱片转出',
        (WidgetTester tester) async {
          final SemanticsHandle semantics = tester.ensureSemantics();
          const String title = 'Fly Me to the Star';
          await pumpBlock(
            tester,
            const FushiCoverBlock(
              title: title,
              art: FushiCoverBlockArt.square,
              chip: 'CD',
              subtitle: 'should not show',
              disc: ColoredBox(key: discKey, color: Colors.black),
              covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
            ),
            size: size,
          );
          expect(find.byKey(discKey), findsOneWidget);
          expect(find.byKey(coverKey), findsOneWidget);
          expect(find.text('CD'), findsOneWidget);
          expect(find.text('should not show'), findsNothing);
          expect(fitPaint(title), findsOneWidget);
          expect(find.bySemanticsLabel(title), findsOneWidget);

          final Rect cover = tester.getRect(find.byKey(coverKey));
          final Rect discRest = tester.getRect(find.byKey(discKey));
          // 唱片在封面右侧（后方）。
          expect(discRest.center.dx, greaterThan(cover.center.dx));
          await hover(tester);
          final Rect discHover = tester.getRect(find.byKey(discKey));
          expect(discHover.center.dx, greaterThan(discRest.center.dx + 4));
          semantics.dispose();
        },
      );
    }

    testWidgets('唱片画在封面后面', (WidgetTester tester) async {
      await pumpBlock(
        tester,
        const FushiCoverBlock(
          title: 'Order',
          art: FushiCoverBlockArt.square,
          disc: ColoredBox(key: discKey, color: Colors.black),
          covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
        ),
        size: const Size(220, 270),
      );
      final List<Element> order = <Element>[];
      void visit(Element e) {
        final Key? k = e.widget.key;
        if (k == discKey || k == coverKey) order.add(e);
        e.visitChildren(visit);
      }

      tester.element(find.byKey(blockKey)).visitChildren(visit);
      expect(order.map((Element e) => e.widget.key), <Key>[discKey, coverKey]);
    });
  });

  group('M2 / C1 布局', () {
    const double spacing = kFushiCoverBlockSpacing;

    List<FushiCoverBlockRow> plan(
      double width,
      int count, {
      ShellContentLayout? layout = ShellContentLayout.collage,
      bool uniform = true,
      double? narrow,
    }) => computeFushiCoverBlockPlan(
      width: width,
      itemCount: count,
      layout: layout,
      targetWidth: kFushiCoverBlockTargetWidthMedia,
      narrowTargetWidth: narrow,
      isWideItem: (int i) => i % 5 == 2,
      uniformAfterHero: uniform,
    );

    test('只有首块加大（2 列 × 2 行），其余全部等尺寸，不出洞', () {
      for (final double width in <double>[1300, 1700, 2100]) {
        final List<FushiCoverBlockRow> rows = plan(width, 17);
        final List<FushiCoverBlockCell> cells = rows
            .expand((FushiCoverBlockRow r) => r.cells)
            .toList();
        expect(cells.length, 17);
        final FushiCoverBlockCell hero = cells.first;
        expect(hero.size, FushiCoverBlockSize.hero);
        final Iterable<FushiCoverBlockCell> rest = cells.skip(1);
        expect(
          rest.every(
            (FushiCoverBlockCell c) => c.size == FushiCoverBlockSize.regular,
          ),
          isTrue,
        );
        final Set<String> sizes = <String>{
          for (final FushiCoverBlockCell c in rest)
            '${c.rect.width.toStringAsFixed(3)}x${c.rect.height}',
        };
        expect(sizes.length, 1, reason: 'width $width');
        final Rect unit = rest.first.rect;
        expect(hero.rect.width, moreOrLessEquals(unit.width * 2 + spacing));
        expect(hero.rect.height, moreOrLessEquals(unit.height * 2 + spacing));
        // 首行（首块那一段）旁边两行都排满。
        final int columns = fushiCoverBlockColumns(
          width,
          kFushiCoverBlockTargetWidthMedia,
          spacing,
        );
        expect(rows.first.cells.length, 1 + (columns - 2) * 2);
      }
    });

    test('窄行（< 3 列）首块独占一行，其余等尺寸', () {
      final List<FushiCoverBlockRow> rows = plan(700, 5);
      expect(rows.first.cells.single.size, FushiCoverBlockSize.hero);
      expect(rows.first.cells.single.rect.width, 700);
      expect(
        rows
            .skip(1)
            .expand((FushiCoverBlockRow r) => r.cells)
            .every(
              (FushiCoverBlockCell c) => c.size == FushiCoverBlockSize.regular,
            ),
        isTrue,
      );
    });

    // C1：行内横向相邻、半高叠 / 首块旁两行纵向相邻、行与行之间，间距都等于
    // spacing（行间距由行的 bottom padding 给，也是 spacing）。
    void expectUniformGaps(List<FushiCoverBlockRow> rows, String reason) {
      for (final FushiCoverBlockRow row in rows) {
        final List<FushiCoverBlockCell> cells = row.cells;
        for (final FushiCoverBlockCell a in cells) {
          // 右侧最近的、纵向有重叠的邻居。
          FushiCoverBlockCell? right;
          FushiCoverBlockCell? below;
          for (final FushiCoverBlockCell b in cells) {
            if (identical(a, b)) continue;
            final bool vOverlap =
                b.rect.top < a.rect.bottom - 0.01 &&
                b.rect.bottom > a.rect.top + 0.01;
            final bool hOverlap =
                b.rect.left < a.rect.right - 0.01 &&
                b.rect.right > a.rect.left + 0.01;
            if (vOverlap && b.rect.left >= a.rect.right - 0.01) {
              if (right == null || b.rect.left < right.rect.left) right = b;
            }
            if (hOverlap && b.rect.top >= a.rect.bottom - 0.01) {
              if (below == null || b.rect.top < below.rect.top) below = b;
            }
          }
          if (right != null) {
            expect(
              right.rect.left - a.rect.right,
              moreOrLessEquals(spacing, epsilon: 0.01),
              reason: '$reason #${a.index}→#${right.index}',
            );
          }
          if (below != null) {
            expect(
              below.rect.top - a.rect.bottom,
              moreOrLessEquals(spacing, epsilon: 0.01),
              reason: '$reason #${a.index}↓#${below.index}',
            );
          }
        }
      }
    }

    test('规整排法下相邻块间距处处一致', () {
      for (final double width in <double>[380, 900, 1260, 1600, 2100]) {
        expectUniformGaps(plan(width, 23), 'uniform $width');
        expectUniformGaps(plan(width, 23, uniform: false), 'collage $width');
        expectUniformGaps(plan(width, 23, layout: null), 'grid $width');
        expectUniformGaps(
          plan(width, 23, uniform: false, narrow: 400),
          'justified collage $width',
        );
        expectUniformGaps(
          plan(width, 23, layout: null, narrow: 400),
          'justified $width',
        );
        expectUniformGaps(
          computeFushiCoverBlockPlacement(
            width: width,
            itemCount: 23,
            layout: ShellContentLayout.collage,
            targetWidth: kFushiCoverBlockTargetWidthMedia,
          ).rows,
          'placement $width',
        );
      }
    });

    test('规整摆放（aligned）不偏不转', () {
      final FushiCoverBlockPose pose = fushiCoverBlockPose(
        ShellBlockArrangement.aligned,
        index: 3,
        width: 400,
        rowWidth: 1200,
      );
      expect(pose, (dx: 0.0, dy: 0.0, rotation: 0.0));
    });
  });
}
