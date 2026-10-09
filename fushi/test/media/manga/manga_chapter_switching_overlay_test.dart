import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3221：换章装载期间正文上的加载指示。
///
/// 设 `FUSHI_PREVIEW_DIR` 时把真实像素存成 PNG（用户可见的视觉证据），不设只做
/// 行为断言。
void main() {
  Future<void> loadPreviewFont() async {
    const String path = 'C:/Windows/Fonts/NotoSansSC-VF.ttf';
    if (!File(path).existsSync()) return;
    final FontLoader loader = FontLoader('PreviewSans')
      ..addFont(
        Future<ByteData>.value(
          ByteData.view(File(path).readAsBytesSync().buffer),
        ),
      );
    await loader.load();
  }

  Widget harness({required bool visible, String? chapterName}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, fontFamily: 'PreviewSans'),
    home: RepaintBoundary(
      key: const ValueKey<String>('preview'),
      child: Stack(
        children: <Widget>[
          // 假页图：白底 + 几块黑色「分镜」，模拟真实漫画页上的对比度。
          Positioned.fill(
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < 3; i++)
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            border: Border.all(width: 3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: MangaChapterSwitchingOverlay(
              visible: visible,
              label: '正在加载章节…',
              chapterName: chapterName,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> savePng(WidgetTester tester, String name) async {
    final String? dir = Platform.environment['FUSHI_PREVIEW_DIR'];
    if (dir == null || dir.isEmpty) return;
    await tester.runAsync(() async {
      final RenderRepaintBoundary boundary = tester.renderObject(
        find.byKey(const ValueKey<String>('preview')),
      );
      final ui.Image image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      Directory(dir).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('换章中：遮罩 + 进度环 + 目标章名，且不吃指针', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(384 * 2.81, 853 * 2.81);
    tester.view.devicePixelRatio = 2.81;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadPreviewFont);

    int taps = 0;
    await tester.pumpWidget(
      GestureDetector(
        onTap: () => taps++,
        child: harness(visible: true, chapterName: '第 12 话 夏日祭'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('第 12 话 夏日祭'), findsOneWidget);
    expect(find.bySemanticsLabel('正在加载章节…'), findsOneWidget);
    final AnimatedOpacity fade = tester.widget(
      find.byKey(const ValueKey<String>('manga_chapter_switching')),
    );
    expect(fade.opacity, 1);
    await tester.tapAt(const Offset(40, 40));
    expect(taps, 1, reason: '加载层不挡指针（返回键 / 顶栏仍可用）');
    await savePng(tester, 'manga_chapter_switching_overlay');
  });

  testWidgets('没有在换章：整层透明，不画卡片', (WidgetTester tester) async {
    await tester.pumpWidget(harness(visible: false));
    await tester.pump(const Duration(milliseconds: 400));
    final AnimatedOpacity fade = tester.widget(
      find.byKey(const ValueKey<String>('manga_chapter_switching')),
    );
    expect(fade.opacity, 0);
    expect(find.text('正在加载章节…'), findsNothing);
  });
}
