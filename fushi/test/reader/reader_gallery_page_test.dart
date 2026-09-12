import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/src/reader/reader_gallery_page.dart';

/// n 张图，每章两张：img0/img1 → 第 1 章，img2/img3 → 第 2 章……
List<EpubImageRef> _images(int n) => <EpubImageRef>[
      for (int i = 0; i < n; i++)
        EpubImageRef(chapterIndex: i ~/ 2, orderInBook: i, src: 'img$i.png'),
    ];

Widget _host(Widget child) => MaterialApp(home: child);

/// 结构类用例用高窗：sliver 里滚出可见区（哪怕在 cacheExtent 内）的子项对
/// finder 是 offstage，三节全摆开需要比默认 600 高的视口。
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 打开页面会自动滚到当前章（专门的用例验证它）；结构类断言先回到顶部，
/// 否则前面章的节头 / 卡片被惰性 sliver 卸掉，findsNothing 是正确行为而非 bug。
Future<void> _pumpAtTop(WidgetTester tester) async {
  await tester.pump();
  final ScrollController? controller =
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller;
  controller?.jumpTo(0);
  await tester.pump();
}

Finder _card(String src) =>
    find.byKey(ValueKey<String>('fushi_gallery_card_$src'));
Finder _section(int chapter) =>
    find.byKey(ValueKey<String>('fushi_gallery_section_$chapter'));
Finder get _placeholders => find.text('Not reached yet');

/// 卡片描边宽度：键盘焦点 = 2，普通 = 1。
double _cardBorderWidth(WidgetTester tester, String src) {
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find.descendant(of: _card(src), matching: find.byType(AnimatedContainer)),
  );
  final ShapeDecoration decoration = container.decoration! as ShapeDecoration;
  return (decoration.shape as RoundedRectangleBorder).side.width;
}

void main() {
  testWidgets('按章分组渲染：节头 / 计数 / 当前阅读位置标记 / 未读章占位卡', (tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await _pumpAtTop(tester);

    expect(_section(0), findsOneWidget);
    expect(_section(1), findsOneWidget);
    expect(_section(2), findsOneWidget);
    expect(find.text('CHAPTER 1'), findsOneWidget);
    expect(find.text('CHAPTER 3'), findsOneWidget);
    // 第 1、2 章已读到 = 4 张解锁；第 3 章两张锁着。
    expect(find.text('Unlocked 4 / 6'), findsOneWidget);
    expect(_placeholders, findsNWidgets(2));
    expect(
      find.text('Unlocks automatically once you reach Chapter 3'),
      findsNWidgets(2),
    );
    // 当前章有插图 → 标记画在它的节头上，且只有一处。
    expect(find.text('Current reading position'), findsOneWidget);
    expect(
      find.descendant(
        of: _section(1),
        matching: find.text('Current reading position'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('chapterLabelFor 提供章名时节头用它', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(2),
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          chapterLabelFor: (int i) => 'Prologue $i',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PROLOGUE 0'), findsOneWidget);
  });

  testWidgets('当前章没有插图：独立标记条插在前后章之间', (tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: const <EpubImageRef>[
            EpubImageRef(chapterIndex: 0, orderInBook: 0, src: 'a.png'),
            EpubImageRef(chapterIndex: 4, orderInBook: 1, src: 'b.png'),
          ],
          currentChapter: 2,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await _pumpAtTop(tester);
    expect(find.text('Current reading position'), findsOneWidget);
    // 标记条在第 1 章节头之下、第 5 章节头之上。
    final double marker =
        tester.getTopLeft(find.text('Current reading position')).dy;
    expect(marker, greaterThan(tester.getTopLeft(find.text('CHAPTER 1')).dy));
    expect(marker, lessThan(tester.getTopLeft(find.text('CHAPTER 5')).dy));
  });

  testWidgets('点占位卡 → 「仍要查看」揭开：写回 onRevealImage、计数 +1、占位卡变缩略图', (tester) async {
    final List<String> revealed = <String>[];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          onRevealImage: revealed.add,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(_card('img4.png'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_locked_reveal')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_locked_reveal')),
    );
    await tester.pumpAndSettle();

    expect(revealed, <String>['img4.png']);
    expect(find.text('Unlocked 5 / 6'), findsOneWidget);
    expect(_placeholders, findsOneWidget);
    // 揭开的卡现在是缩略图（无文件 → broken 图标），再点进查看器而不是弹窗。
    await tester.tap(_card('img4.png'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_viewer')),
      findsOneWidget,
    );
    expect(find.text('5 / 5'), findsOneWidget);
  });

  testWidgets('点占位卡 → 「回到最近已看」把焦点落到最后一张已解锁卡', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pump();

    await tester.tap(_card('img5.png'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_locked_back')),
    );
    await tester.pumpAndSettle();
    expect(_cardBorderWidth(tester, 'img3.png'), 2);
    expect(_cardBorderWidth(tester, 'img2.png'), 1);
    // 弹窗关了、没有揭开任何图。
    expect(find.text('Unlocked 4 / 6'), findsOneWidget);
  });

  testWidgets('「已解锁」过滤只列已解锁卡（含刚揭开的），未读章节头消失', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          revealedImageKeys: const <String>{'img5.png'},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Unlocked 5 / 6'), findsOneWidget);

    await tester.tap(find.text('Unlocked'));
    await tester.pumpAndSettle();
    expect(_placeholders, findsNothing);
    expect(_card('img4.png'), findsNothing);
    expect(_card('img5.png'), findsOneWidget);
    expect(_section(2), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(_placeholders, findsOneWidget);
  });

  testWidgets('blurImages 开：全部未揭开的图都锁着，占位提示换成模糊说明', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(4),
          currentChapter: 5,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          blurImages: true,
          revealedImageKeys: const <String>{'img1.png'},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Unlocked 1 / 4'), findsOneWidget);
    expect(_placeholders, findsNWidgets(3));
    expect(find.text('Image blur is on; reveal to view'), findsNWidgets(3));
  });

  testWidgets('打开时自动滚到当前阅读章那一节', (tester) async {
    // 第 1 章 20 张（5 列 × 4 行）把第 2 章推出首屏。
    final List<EpubImageRef> images = <EpubImageRef>[
      for (int i = 0; i < 20; i++)
        EpubImageRef(chapterIndex: 0, orderInBook: i, src: 'a$i.png'),
      const EpubImageRef(chapterIndex: 1, orderInBook: 20, src: 'b0.png'),
      const EpubImageRef(chapterIndex: 1, orderInBook: 21, src: 'b1.png'),
    ];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: images,
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ScrollController controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    expect(controller.offset, greaterThan(0));
    expect(_section(1), findsOneWidget);
    expect(_section(0), findsNothing, reason: '第 1 章节头已滚出视口、未构建');

    // 手动滚回顶部后，「跳到当前阅读位置」再次定位过去。
    controller.jumpTo(0);
    await tester.pump();
    expect(_section(0), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_position')),
    );
    await tester.pumpAndSettle();
    expect(_section(1), findsOneWidget);
    expect(_section(0), findsNothing);
  });

  testWidgets('查看器：点已解锁卡打开；←/→ 与滚轮切图、Enter 交给 onOpenImage、Esc 关', (
    tester,
  ) async {
    final List<EpubImageRef> opened = <EpubImageRef>[];
    EpubImageRef? jumped;
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: opened.add,
          onJumpTo: (EpubImageRef r) => jumped = r,
        ),
      ),
    );
    await _pumpAtTop(tester);

    await tester.tap(_card('img0.png'));
    await tester.pumpAndSettle();
    final Finder viewer = find.byKey(
      const ValueKey<String>('fushi_gallery_viewer'),
    );
    expect(viewer, findsOneWidget);
    expect(find.text('1 / 4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('2 / 4'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(find.text('3 / 4'), findsOneWidget);
    // 锁着的 img4/img5 不在查看器序列里：末尾停在第 4 张。
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.text('4 / 4'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('3 / 4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened.single.src, 'img2.png');
    await tester.tap(find.byKey(const ValueKey<String>('fushi_gallery_jump')));
    expect(jumped?.src, 'img2.png');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(viewer, findsNothing);
    // 查看器关掉后焦点跟到了刚看的那张卡。
    expect(_cardBorderWidth(tester, 'img2.png'), 2);
  });

  testWidgets('网格键盘：方向键移焦、Enter 打开焦点卡、Esc 关页面', (tester) async {
    final List<EpubImageRef> opened = <EpubImageRef>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderGalleryPage(
                      images: _images(6),
                      currentChapter: 1,
                      fileForRef: (_) => null,
                      onOpenImage: opened.add,
                      onJumpTo: (_) {},
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_cardBorderWidth(tester, 'img0.png'), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_cardBorderWidth(tester, 'img1.png'), 2);
    expect(_cardBorderWidth(tester, 'img0.png'), 1);
    // ↓ 跨到下一节同一列（第 2 章第 2 张 = img3）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_cardBorderWidth(tester, 'img3.png'), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_cardBorderWidth(tester, 'img1.png'), 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_viewer')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderGalleryPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('空书：空态文案，无过滤 / 定位控件', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: const <EpubImageRef>[],
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    expect(find.text('No illustrations in this book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_filter')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_position')),
      findsNothing,
    );
    expect(find.byType(CustomScrollView), findsNothing);
  });

  testWidgets('一张都没解锁时切「已解锁」显示专用空态', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(2),
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          blurImages: true,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Unlocked'));
    await tester.pumpAndSettle();
    expect(find.text('No unlocked illustrations yet'), findsOneWidget);
  });

  test('fileForRef 允许返回 File（类型契约）', () {
    final ReaderGalleryPage page = ReaderGalleryPage(
      images: _images(1),
      currentChapter: 0,
      fileForRef: (EpubImageRef r) => File(r.src),
      onOpenImage: (_) {},
      onJumpTo: (_) {},
    );
    expect(page.fileForRef(_images(1).first)?.path, 'img0.png');
  });
}
