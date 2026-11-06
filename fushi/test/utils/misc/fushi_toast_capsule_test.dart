// FushiToastCapsule：底部 FushiToast 与视频页左上角 OSD 共用的 M3E 通知胶囊。
// 视频 OSD 此前自画 6px 圆角、整块铺饱和语义色的旧卡（用户 2026-11-01 截图
// 「句子已收藏」），改为同一副全胶囊 + 语义图标色块后，这里钉住胶囊的长相契约。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget capsule, {
  Brightness brightness = Brightness.dark,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: brightness,
        ),
      ),
      home: Scaffold(body: Center(child: capsule)),
    ),
  );
}

BoxDecoration _capsuleDecoration(WidgetTester tester) {
  final Container outer = tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(FushiToastCapsule),
          matching: find.byType(Container),
        ),
      )
      .first;
  return outer.decoration! as BoxDecoration;
}

/// 图标色块（32×32 圆形）里的图标颜色。
Color _iconChipColor(WidgetTester tester) {
  final Container chip = tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(FushiToastCapsule),
          matching: find.byType(Container),
        ),
      )
      .firstWhere((Container c) => c.decoration is ShapeDecoration);
  final ShapeDecoration d = chip.decoration! as ShapeDecoration;
  expect(d.shape, isA<CircleBorder>());
  return d.color!;
}

void main() {
  testWidgets('全胶囊：圆角 24、底色用调用方给的表面色（不整块铺语义色）', (WidgetTester tester) async {
    const Color surface = Color(0xE6202124);
    await _pump(
      tester,
      const FushiToastCapsule(
        message: '句子已收藏',
        icon: Icons.favorite,
        severity: ToastSeverity.success,
        surfaceColor: surface,
        foregroundColor: Colors.white,
      ),
    );
    final BoxDecoration d = _capsuleDecoration(tester);
    expect(d.color, surface);
    expect(d.borderRadius, const BorderRadius.all(Radius.circular(24)));
    expect(d.boxShadow, isNotEmpty);
    // 语义（success）只落在图标色块上：深底取浅绿（tone 80）的 20%。
    expect(
      _iconChipColor(tester),
      const Color(0xFF7DDC8C).withValues(alpha: 0.2),
    );
    expect(find.text('句子已收藏'), findsOneWidget);
  });

  testWidgets('info 在非反色深底上取浅色主色，保证对比（视频 OSD 深色主题）', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const FushiToastCapsule(
        message: 'info',
        icon: Icons.info_outline,
        severity: ToastSeverity.info,
        surfaceColor: Color(0xFF1B1B1F),
        foregroundColor: Colors.white,
      ),
    );
    final BuildContext ctx = tester.element(find.byType(FushiToastCapsule));
    final ColorScheme cs = Theme.of(ctx).colorScheme;
    expect(cs.brightness, Brightness.dark);
    expect(_iconChipColor(tester), cs.primary.withValues(alpha: 0.2));
  });

  testWidgets('info 在反色浮条上仍是 inversePrimary（底部 toast 行为不变）', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      brightness: Brightness.light,
      Builder(
        builder: (BuildContext context) {
          final ColorScheme cs = Theme.of(context).colorScheme;
          return FushiToastCapsule(
            message: 'info',
            icon: Icons.info_outline,
            severity: ToastSeverity.info,
            surfaceColor: cs.inverseSurface,
            foregroundColor: cs.onInverseSurface,
          );
        },
      ),
    );
    final BuildContext ctx = tester.element(find.byType(FushiToastCapsule));
    final ColorScheme cs = Theme.of(ctx).colorScheme;
    expect(_iconChipColor(tester), cs.inversePrimary.withValues(alpha: 0.2));
  });

  testWidgets('progress 非空时在文字下画进度条，空时不画', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiToastCapsule(
        message: '下载字幕',
        progress: 0.4,
        surfaceColor: Color(0xFF1B1B1F),
        foregroundColor: Colors.white,
      ),
    );
    expect(find.byType(FushiLinearProgressIndicator), findsOneWidget);

    await _pump(
      tester,
      const FushiToastCapsule(
        message: '普通',
        surfaceColor: Color(0xFF1B1B1F),
        foregroundColor: Colors.white,
      ),
    );
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);
  });
}
