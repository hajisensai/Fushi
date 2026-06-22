import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';

/// BUG-404：插画全屏画廊（`_FullScreenGallery`）必须自己持有键盘处理——
/// ESC 退出（不依赖整页 PageRoute 下不稳定的全局 `_handleGlobalEscape`），
/// 左右方向键复用现成 `_pageBy` 翻页（已 clamp + 同步顶栏计数）。
///
/// 这里是 widget 行为测试：构造真实 [IllustrationsViewerPage] 指向带真实
/// 图片文件的临时目录，从网格点进全屏画廊，再用 `sendKeyEvent` 驱动键盘，
/// 断言真实 pop / 计数变化 / 首尾 clamp，而非仅扫源码字符串。
///
/// `_extractImages` 用真实 `File.readAsBytes()`，标准 fake-async zone 里这些
/// IO 不会推进，故加载阶段必须在 [WidgetTester.runAsync] 内手动 pump 等其落定，
/// 再退出 runAsync 做键盘交互（动画用 `pump(Duration)` 推进，不用 pumpAndSettle）。
void main() {
  // 1x1 透明 PNG，确保 `Image.memory` / 文件解码不报错。
  final Uint8List onePxPng = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
    0x42, 0x60, 0x82,
  ]);

  late Directory extractDir;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    extractDir = Directory.systemTemp.createTempSync('hibiki_illust_kbd');
    // 写 3 张图片（命名带序号，listSync 顺序在同一目录内稳定）。
    for (int i = 0; i < 3; i++) {
      File('${extractDir.path}/img_$i.png').writeAsBytesSync(onePxPng);
    }
  });

  tearDown(() {
    // Windows 下解码句柄可能仍占用文件，删除失败不应让用例变红。
    try {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // 临时目录由 OS 回收。
    }
  });

  Widget buildApp() {
    return TranslationProvider(
      child: MaterialApp(
        home: IllustrationsViewerPage(
          bookTitle: 'Book',
          extractDir: extractDir.path,
        ),
      ),
    );
  }

  String counter(int current) =>
      t.image_page_counter(current: current, total: 3);

  /// 进入网格并点开首张插画进入全屏画廊（顶栏停在「1 / 3」）。
  Future<void> openGallery(WidgetTester tester) async {
    // 加载阶段含真实文件 IO：在 runAsync 内 pump 等三张图都落定。
    await tester.runAsync(() async {
      await tester.pumpWidget(buildApp());
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (tester.widgetList(find.byType(Image)).length >= 3) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(find.byType(Image), findsWidgets);

    await tester.tap(find.byType(Image).first);
    // 路由 push 转场动画（adaptivePageRoute）：定量推进，别 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(counter(1)), findsOneWidget);
  }

  /// `_pageBy` 的 `animateToPage` 是 220ms，推进足够时长让其落定。
  Future<void> settlePaging(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('arrowRight advances to next image and updates the counter', (
    WidgetTester tester,
  ) async {
    await openGallery(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settlePaging(tester);

    expect(find.text(counter(2)), findsOneWidget);
    expect(find.text(counter(1)), findsNothing);
  });

  testWidgets('arrowLeft goes back to the previous image', (
    WidgetTester tester,
  ) async {
    await openGallery(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settlePaging(tester);
    expect(find.text(counter(2)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settlePaging(tester);
    expect(find.text(counter(1)), findsOneWidget);
  });

  testWidgets('arrowLeft at first image clamps (no underflow)', (
    WidgetTester tester,
  ) async {
    await openGallery(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settlePaging(tester);

    // 仍停在第 1 张，未越界。
    expect(find.text(counter(1)), findsOneWidget);
  });

  testWidgets('arrowRight at last image clamps (no overflow)', (
    WidgetTester tester,
  ) async {
    await openGallery(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settlePaging(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settlePaging(tester);
    expect(find.text(counter(3)), findsOneWidget);

    // 再按一次仍停在最后一张。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settlePaging(tester);
    expect(find.text(counter(3)), findsOneWidget);
  });

  testWidgets('escape pops the full-screen gallery back to the grid', (
    WidgetTester tester,
  ) async {
    await openGallery(tester);
    // 画廊在栈顶：计数文案存在。
    expect(find.text(counter(1)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // maybePop 先 await route.popDisposition（microtask），再做 pop 转场动画；
    // 在 runAsync 内推进 microtask 队列，再 pump 完成转场。
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 画廊已退出，回到网格（顶栏计数消失，标题仍是书名）。
    expect(find.text(counter(1)), findsNothing);
    expect(find.text('Book'), findsWidgets);
  });
}
