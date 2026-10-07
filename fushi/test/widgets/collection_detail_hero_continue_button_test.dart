import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_hero.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:material_ui/material_ui.dart';

// BUG-3063：合集详情 hero 的「继续」主按钮在手机宽度下，长条目名把内容撑出按钮
// ——左侧播放图标压到按钮左缘外、文字顶到右缘才省略、左右内边距不对称。
// 根因是它用了扩展 FAB（内容按无界宽度排版后居中溢出，不随可用宽度收缩），
// 修法是换成 M3E 尺寸档的填充按钮（文字 Flexible 收缩 + 省略号）。
// 这里钉住：手机宽度 390 / 360、深浅主题下，图标与文字都在按钮内，左右内边距
// 相等，长标题省略而不溢出；短标题按钮不被撑满。
void main() {
  const String longTitle = '[23卷] 無職転生 ~異世界行ったら本気だす~ 23 長い長いサブタイトルの続き';

  ThemeData theme(Brightness brightness) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
    textTheme: brightness == Brightness.dark
        ? Typography.material2021().white
        : Typography.material2021().black,
  );

  Future<void> pumpHero(
    WidgetTester tester, {
    required double width,
    required Brightness brightness,
    required String? subtitle,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(width * 3, 900 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(brightness),
        home: FushiGlassScope(
          child: Scaffold(
            body: SingleChildScrollView(
              // 与 media_collection_grid_detail_page 窄屏的 hPad 一致。
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CollectionDetailHeroCard(
                name: '無職転生',
                memberCount: 5,
                finished: 1,
                progress: 0.4,
                continueStarted: true,
                continueLabel: subtitle,
                onContinue: () {},
                onEditTags: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final Finder button = find.byKey(
    const ValueKey<String>('collection_detail_continue'),
  );

  for (final double width in <double>[390, 360]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('long title stays inside the button with symmetric padding '
          '(${width.toInt()}dp, ${brightness.name})', (
        WidgetTester tester,
      ) async {
        await pumpHero(
          tester,
          width: width,
          brightness: brightness,
          subtitle: longTitle,
        );
        expect(tester.takeException(), isNull);

        final Rect card = tester.getRect(find.byType(CollectionDetailHeroCard));
        final Rect btn = tester.getRect(button);
        final Rect icon = tester.getRect(
          find.descendant(of: button, matching: find.byType(FushiIcon)),
        );
        final Finder label = find.descendant(
          of: button,
          matching: find.textContaining(longTitle),
        );
        final Rect text = tester.getRect(label);

        // 按钮整体在 hero 卡片里。
        expect(btn.left, greaterThanOrEqualTo(card.left));
        expect(btn.right, lessThanOrEqualTo(card.right));
        // 图标与文字完整落在按钮内。
        expect(icon.left, greaterThan(btn.left));
        expect(icon.right, lessThan(btn.right));
        expect(text.left, greaterThan(icon.right));
        expect(text.right, lessThan(btn.right));
        // 左右内边距相等（M3E 按钮 leading / trailing space 对称）。
        final double leading = icon.left - btn.left;
        final double trailing = btn.right - text.right;
        expect(leading, greaterThanOrEqualTo(16));
        expect((leading - trailing).abs(), lessThanOrEqualTo(1));
        // 长标题被省略号截断，而不是撑出按钮。
        final RenderParagraph paragraph = tester.renderObject(label);
        expect(paragraph.didExceedMaxLines, isTrue);
      });
    }
  }

  testWidgets('short title hugs its content and stays centered', (
    WidgetTester tester,
  ) async {
    await pumpHero(
      tester,
      width: 390,
      brightness: Brightness.light,
      subtitle: '短い',
    );
    expect(tester.takeException(), isNull);
    final Rect card = tester.getRect(find.byType(CollectionDetailHeroCard));
    final Rect btn = tester.getRect(button);
    final Rect icon = tester.getRect(
      find.descendant(of: button, matching: find.byType(FushiIcon)),
    );
    final Rect text = tester.getRect(
      find.descendant(of: button, matching: find.textContaining('短い')),
    );
    expect(btn.width, lessThan(card.width - 64));
    expect((btn.center.dx - card.center.dx).abs(), lessThanOrEqualTo(1));
    expect(
      ((icon.left - btn.left) - (btn.right - text.right)).abs(),
      lessThanOrEqualTo(1),
    );
  });
}
