import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart'
    show EpubImageRef, kEpubCoverChapterIndex;
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:image/image.dart' as img;

/// n 张图，每章两张：img0/img1 → 第 1 章，img2/img3 → 第 2 章……
List<EpubImageRef> _images(int n) => <EpubImageRef>[
      for (int i = 0; i < n; i++)
        EpubImageRef(
          chapterIndex: i ~/ 2,
          orderInBook: i,
          src: 'img$i.png',
          revealKey: 'img$i.png',
        ),
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
/// 锁着的卡 = 盖在真缩略图上的高斯模糊层（maskedIllustrationCover，墨水屏才换
/// 实心遮板；测试主题非墨水屏）。整页只有遮罩会用到 ImageFiltered。
Finder get _maskedCards => find.byType(ImageFiltered);
Finder _maskedCard(String src) =>
    find.descendant(of: _card(src), matching: find.byType(ImageFiltered));

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
    expect(_maskedCards, findsNWidgets(2));
    expect(_maskedCard('img4.png'), findsOneWidget);
    expect(_maskedCard('img5.png'), findsOneWidget);
    // 解锁条件不再印在卡片上（卡片是糊掉的原图），点开才说。
    expect(
      find.text('Unlocks automatically once you reach Chapter 3'),
      findsNothing,
    );
    await tester.tap(_card('img4.png'));
    await tester.pumpAndSettle();
    expect(
      find.text('Unlocks automatically once you reach Chapter 3'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_locked_back')),
    );
    await tester.pumpAndSettle();
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
            EpubImageRef(
              chapterIndex: 0,
              orderInBook: 0,
              src: 'a.png',
              revealKey: 'a.png',
            ),
            EpubImageRef(
              chapterIndex: 4,
              orderInBook: 1,
              src: 'b.png',
              revealKey: 'b.png',
            ),
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

  testWidgets('点锁着的卡 → 「仍要查看」揭开：写回 onRevealImage、计数 +1、模糊层撤掉', (tester) async {
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
    expect(_maskedCards, findsOneWidget);
    expect(_maskedCard('img4.png'), findsNothing);
    // 揭开的卡现在是缩略图（无文件 → broken 图标），再点进查看器而不是弹窗。
    await tester.tap(_card('img4.png'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_viewer')),
      findsOneWidget,
    );
    expect(find.text('5 / 5'), findsOneWidget);
  });

  testWidgets('点锁着的卡 → 「回到最近已看」把焦点落到最后一张已解锁卡', (tester) async {
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
    expect(_maskedCards, findsNothing);
    expect(_card('img4.png'), findsNothing);
    expect(_card('img5.png'), findsOneWidget);
    expect(_section(2), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(_maskedCards, findsOneWidget);
  });

  // BUG-2559：画廊的「还没读到」以前只比章号，书架端插图库比章号 + 章内偏移。
  // 于是当前章读到一半时，同一张插图在两处一个遮一个不遮——用户看到的就是
  // 「阅读器里糊的图和书架上糊的图不一样」。
  testWidgets('当前章内：阅读位置之后的插图锁着，之前的不锁', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: const <EpubImageRef>[
            EpubImageRef(
              chapterIndex: 1,
              orderInBook: 0,
              src: 'early.png',
              revealKey: 'early.png',
              normCharOffset: 2000,
            ),
            EpubImageRef(
              chapterIndex: 1,
              orderInBook: 1,
              src: 'late.png',
              revealKey: 'late.png',
              normCharOffset: 8000,
            ),
          ],
          currentChapter: 1,
          currentNormCharOffset: 5000,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(_maskedCard('early.png'), findsNothing);
    expect(_maskedCard('late.png'), findsOneWidget);
    expect(find.text('Unlocked 1 / 2'), findsOneWidget);
  });

  testWidgets('章内偏移缺省（0）时退回章首语义，本章插图都算已读到', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: const <EpubImageRef>[
            EpubImageRef(
              chapterIndex: 1,
              orderInBook: 0,
              src: 'head.png',
              revealKey: 'head.png',
            ),
            EpubImageRef(
              chapterIndex: 1,
              orderInBook: 1,
              src: 'late.png',
              revealKey: 'late.png',
              normCharOffset: 8000,
            ),
          ],
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pump();

    // 章首那张（偏移 0）不遮；靠后那张在「刚进本章」时仍算没读到。
    expect(_maskedCard('head.png'), findsNothing);
    expect(_maskedCard('late.png'), findsOneWidget);
  });

  testWidgets('正文没引用的封面挂在封面节，节头不写成「第 0 章」', (tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: const <EpubImageRef>[
            EpubImageRef(
              chapterIndex: kEpubCoverChapterIndex,
              orderInBook: 0,
              src: 'cover.jpg',
              revealKey: 'cover.jpg',
            ),
            EpubImageRef(
              chapterIndex: 0,
              orderInBook: 1,
              src: 'p1.png',
              revealKey: 'p1.png',
            ),
          ],
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await _pumpAtTop(tester);

    // 节头文案大写化渲染。
    expect(find.text('COVER'), findsOneWidget);
    expect(find.text('CHAPTER 0'), findsNothing);
    // 封面排在正文之前，且永远算已读到。
    expect(_maskedCard('cover.jpg'), findsNothing);
  });

  testWidgets('blurImages 开：全部未揭开的图都锁着，弹窗提示换成模糊说明', (tester) async {
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
    expect(_maskedCards, findsNWidgets(3));
    expect(_maskedCard('img1.png'), findsNothing);
    await tester.tap(_card('img0.png'));
    await tester.pumpAndSettle();
    expect(find.text('Image blur is on; reveal to view'), findsOneWidget);
  });

  testWidgets('整章滚过视口后该章一张卡都不再挂在树上（含末行）', (tester) async {
    // 6 章 × 20 张：拉到底后前几章整节都在 cacheExtent 之外。自定义槽位布局若把
    // firstIndex clamp 到末行，RenderSliverGrid 就永远给每个滚过的章挂着末行
    // 缩略图——几十章的书拉到底 = 几十行常驻内存。
    final List<EpubImageRef> images = <EpubImageRef>[
      for (int c = 0; c < 6; c++)
        for (int i = 0; i < 20; i++)
          EpubImageRef(
            chapterIndex: c,
            orderInBook: c * 20 + i,
            src: 'c${c}_$i.png',
            revealKey: 'c${c}_$i.png',
          ),
    ];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: images,
          currentChapter: 5,
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
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    // skipOffstage:false 才抓得到「挂着但看不见」的卡。
    expect(
      find.byKey(
        const ValueKey<String>('fushi_gallery_card_c0_19.png'),
        skipOffstage: false,
      ),
      findsNothing,
      reason: '第 1 章末行不得因 firstIndex clamp 而常驻',
    );
    expect(
      find.byKey(
        const ValueKey<String>('fushi_gallery_card_c0_0.png'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(_card('c5_19.png'), findsOneWidget, reason: '末章末行照常挂着');
  });

  testWidgets('打开时自动滚到当前阅读章那一节', (tester) async {
    // 第 1 章 20 张（5 列 × 4 行）把第 2 章推出首屏。
    final List<EpubImageRef> images = <EpubImageRef>[
      for (int i = 0; i < 20; i++)
        EpubImageRef(
          chapterIndex: 0,
          orderInBook: i,
          src: 'a$i.png',
          revealKey: 'a$i.png',
        ),
      const EpubImageRef(
        chapterIndex: 1,
        orderInBook: 20,
        src: 'b0.png',
        revealKey: 'b0.png',
      ),
      const EpubImageRef(
        chapterIndex: 1,
        orderInBook: 21,
        src: 'b1.png',
        revealKey: 'b1.png',
      ),
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

  testWidgets('长按卡片 → 菜单「跳转到此插图」走 onJumpTo（锁着的卡也有跳转入口）', (
    tester,
  ) async {
    final List<String> jumped = <String>[];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (EpubImageRef ref) => jumped.add(ref.src),
        ),
      ),
    );
    await tester.pump();

    // 锁着的卡进不去查看器，此前也就没有任何跳转入口——菜单正是补这一半。
    await tester.longPress(_card('img4.png'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
      findsOneWidget,
    );
    // 锁着 → 给「仍要查看」，不给「恢复遮罩」。
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_reveal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_relock')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
    );
    await tester.pumpAndSettle();
    expect(jumped, <String>['img4.png']);
  });

  testWidgets('长按已揭开的卡 →「恢复遮罩」：回写 onUnrevealImage、计数 -1、模糊层回来', (
    tester,
  ) async {
    final List<String> unrevealed = <String>[];
    final Set<String> hostRevealed = <String>{'img4.png'};
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
          revealedImageKeys: hostRevealed,
          onUnrevealImage: unrevealed.add,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Unlocked 5 / 6'), findsOneWidget);
    expect(_maskedCard('img4.png'), findsNothing);

    await tester.longPress(_card('img4.png'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_relock')),
    );
    await tester.pumpAndSettle();

    expect(unrevealed, <String>['img4.png']);
    expect(find.text('Unlocked 4 / 6'), findsOneWidget);
    // 宿主会话集由宿主自己删（本测试不删），页面仍须立刻遮回去。
    expect(_maskedCard('img4.png'), findsOneWidget);
  });

  testWidgets('已读到 + 总开关关：没有遮罩理由的图不给「恢复遮罩」', (tester) async {
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

    // img2 属于当前章：已经读到、总开关又关着 —— 撤销揭开不会让它重新遮上。
    await tester.longPress(_card('img2.png'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_relock')),
      findsNothing,
    );
  });

  testWidgets('iOS 刘海 / 灵动岛：顶栏整条让开状态栏，按钮可点', (tester) async {
    _useTallWindow(tester);
    const double statusBar = 59;
    tester.view.viewPadding = const FakeViewPadding(top: statusBar * 1);
    tester.view.padding = const FakeViewPadding(top: statusBar * 1);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);

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

    // 关闭 / 定位 / 过滤三个控件此前整条压在状态栏底下，点不到。
    for (final Finder control in <Finder>[
      find.byKey(const ValueKey<String>('fushi_gallery_close')),
      find.byKey(const ValueKey<String>('fushi_gallery_position')),
      find.byKey(const ValueKey<String>('fushi_gallery_filter')),
    ]) {
      expect(
        tester.getTopLeft(control).dy,
        greaterThanOrEqualTo(statusBar),
        reason: '顶栏控件必须整条落在状态栏之下',
      );
    }
  });

  testWidgets('菜单键唤出卡片菜单；关闭后焦点回网格，方向键仍能移焦', (tester) async {
    final List<String> jumped = <String>[];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: 1,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (EpubImageRef ref) => jumped.add(ref.src),
        ),
      ),
    );
    await _pumpAtTop(tester);

    // 方向键落焦到第一张卡 → 菜单键（长按的键盘等价）唤出菜单。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_cardBorderWidth(tester, 'img0.png'), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
    );
    await tester.pumpAndSettle();
    expect(jumped, <String>['img0.png']);

    // 菜单吃掉的焦点必须还回来：不还，方向键就再也移不动焦点了。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      _cardBorderWidth(tester, 'img1.png'),
      2,
      reason: '菜单关闭后方向键应继续在网格里移焦',
    );
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

  // BUG-2496：坏图（写着 <html> 字节的 .jpg）解码失败不再是致命 FlutterError——
  // 舞台与缩略图都退回 broken 占位，只在诊断段留一条带路径的痕迹。
  // Image.file 的解码是真 IO + isolate，fake async 送不到完成事件，pump 放进 runAsync。
  testWidgets('坏图文件：解码失败走 errorBuilder 占位，不抛未捕获 FlutterError', (tester) async {
    final Directory dir = Directory.systemTemp.createTempSync('fushi_gallery_bad_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File bad = File('${dir.path}/bad.jpg')
      ..writeAsStringSync('<html><body>not an image</body></html>');
    final int diagBefore = ErrorLogService.instance.diagnosticEntries.length;

    await tester.runAsync(() async {
      await tester.pumpWidget(_host(ReaderGalleryPage(
        images: _images(2),
        currentChapter: 0,
        fileForRef: (_) => bad,
        onOpenImage: (_) {},
        onJumpTo: (_) {},
      )));
      // 等解码真的失败并回调到 errorBuilder（同一 completer 上的两张缩略图）。
      for (int i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byIcon(Icons.broken_image_outlined).evaluate().length >= 2) {
          break;
        }
      }
      // 网格形态下查看器默认关着：点第一张卡打开，舞台 errorBuilder + 相邻图
      // precacheImage 的 onError 才会各走一次。
      await tester.tap(_card('img0.png'));
      for (int i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byIcon(Icons.broken_image_outlined).evaluate().length >= 3) {
          break;
        }
      }
    });

    expect(tester.takeException(), isNull,
        reason: '坏图解码失败必须被 errorBuilder 接住，不得逃成未捕获 FlutterError');
    // 2 张缩略图（网格仍在查看器之下）+ 舞台 = 3 个 broken 占位。
    expect(find.byIcon(Icons.broken_image_outlined), findsNWidgets(3));
    final List<ErrorLogEntry> diag =
        ErrorLogService.instance.diagnosticEntries.sublist(diagBefore);
    final Set<String> sources =
        diag.map((ErrorLogEntry e) => e.source).toSet();
    // 舞台 / 缩略图 errorBuilder + 相邻图 precacheImage 的 onError 各留一条痕迹。
    expect(sources, contains('ReaderGalleryPage.stage.coverDecode'));
    expect(sources, contains('ReaderGalleryPage.thumb.coverDecode'));
    expect(sources, contains('ReaderGalleryPage.precache.coverDecode'),
        reason: 'precacheImage 不接 onError 会自己 FlutterError.reportError');
    expect(
        diag
            .where((ErrorLogEntry e) => e.source.endsWith('.coverDecode'))
            .every((ErrorLogEntry e) => e.error.contains(bad.path)),
        isTrue,
        reason: '诊断痕迹必须带路径，不然坏文件无从定位');
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

  // ── BUG-2589：横版图占两列 / 书架端无阅读位置 ──────────────────────

  /// 写一张 [width]×[height] 的真 PNG（缩略图要能解码，探针要读到尺寸）。
  File writePng(Directory dir, String name, int width, int height) {
    final File file = File('${dir.path}/$name');
    file.writeAsBytesSync(
        img.encodePng(img.Image(width: width, height: height)));
    return file;
  }

  /// 开页并等 isolate 里的宽高比探测落定（真 IO，pump 放进 runAsync）。
  Future<void> pumpUntilProbed(WidgetTester tester, Widget page,
      {required String wideSrc}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_host(page));
      // isolate 起得慢时（本机并发跑测试）要多等一会；上限 10s。
      for (int i = 0; i < 500; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final Iterable<Element> found = _card(wideSrc).evaluate();
        if (found.isNotEmpty &&
            tester.getSize(_card(wideSrc)).width > 300) {
          break;
        }
      }
    });
    await tester.pump();
    expect(tester.getSize(_card(wideSrc)).width, greaterThan(300),
        reason: '宽高比探测应在 10s 内落定并把横版图放大到两列');
  }

  testWidgets('横版插图占两列、竖版占一列，行内按阅读顺序排；放不下就另起一行', (tester) async {
    _useTallWindow(tester);
    final Directory dir =
        Directory.systemTemp.createTempSync('fushi_gallery_wide_');
    addTearDown(() => dir.deleteSync(recursive: true));
    // img0 横版（2:1），其余竖版（1:2）；全在第 1 章。
    final Map<String, File> files = <String, File>{
      'img0.png': writePng(dir, 'img0.png', 2, 1),
      for (int i = 1; i < 7; i++)
        'img$i.png': writePng(dir, 'img$i.png', 1, 2),
    };
    final List<EpubImageRef> images = <EpubImageRef>[
      for (int i = 0; i < 7; i++)
        EpubImageRef(
          chapterIndex: 0,
          orderInBook: i,
          src: 'img$i.png',
          revealKey: 'img$i.png',
        ),
    ];
    await pumpUntilProbed(
      tester,
      ReaderGalleryPage(
        images: images,
        currentChapter: 0,
        fileForRef: (EpubImageRef r) => files[r.src],
        onOpenImage: (_) {},
        onJumpTo: (_) {},
      ),
      wideSrc: 'img0.png',
    );

    // 1200 宽：网格宽 1168 → 5 列、格宽 224（目标宽 1168/5 夹在 200~360）。
    final Size wide = tester.getSize(_card('img0.png'));
    final Size narrow = tester.getSize(_card('img1.png'));
    expect(narrow.width, moreOrLessEquals(224, epsilon: 0.5));
    expect(wide.width, moreOrLessEquals(224 * 2 + 12, epsilon: 0.5),
        reason: '横版图 = 两格宽 + 一个间距');
    expect(wide.height, moreOrLessEquals(narrow.height, epsilon: 0.5),
        reason: '行高不变，横版图只横跨、不加高');
    // 同行按阅读顺序：img1 紧贴在 img0 右侧；img4 放不下（第 1 行只剩 0 列）
    // 落到第 2 行行首。
    final Offset wideTop = tester.getTopLeft(_card('img0.png'));
    final Offset narrowTop = tester.getTopLeft(_card('img1.png'));
    expect(narrowTop.dy, moreOrLessEquals(wideTop.dy, epsilon: 0.5));
    expect(narrowTop.dx, moreOrLessEquals(wideTop.dx + wide.width + 12, epsilon: 0.5));
    final Offset row2 = tester.getTopLeft(_card('img4.png'));
    expect(row2.dx, moreOrLessEquals(wideTop.dx, epsilon: 0.5));
    expect(row2.dy, moreOrLessEquals(wideTop.dy + wide.height + 12, epsilon: 0.5));

    // 键盘 ↑/↓ 按槽位几何找最近列：img5（第 2 行第 2 列）↑ → 第 1 行离第 2 列
    // 最近的是 img0（起始列 0，距 1）与 img1（列 2，距 1）并列，取先出现的 img0；
    // img0 ↓ → 第 2 行行首 img4。
    // 焦点从无到有的第一下落在第一张，再 → 五下到 img5（点卡会开查看器，不能用）。
    for (int i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(_cardBorderWidth(tester, 'img5.png'), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_cardBorderWidth(tester, 'img0.png'), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_cardBorderWidth(tester, 'img4.png'), 2);
    expect(_cardBorderWidth(tester, 'img0.png'), 1);
  });

  testWidgets('currentChapter 为 null（书架端没读过的书）：不按进度遮、无标记与定位键', (tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(6),
          currentChapter: null,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(_maskedCards, findsNothing);
    expect(find.text('Unlocked 6 / 6'), findsOneWidget);
    expect(find.text('Current reading position'), findsNothing);
    expect(find.byKey(const ValueKey<String>('fushi_gallery_position')),
        findsNothing);
    // 过滤控件照常在（总开关开着时仍有锁着的图可过滤）。
    expect(find.byKey(const ValueKey<String>('fushi_gallery_filter')),
        findsOneWidget);
  });

  testWidgets('currentChapter 为 null 但总开关开：未揭开的图照旧锁着', (tester) async {
    _useTallWindow(tester);
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(4),
          currentChapter: null,
          blurImages: true,
          revealedImageKeys: const <String>{'img1.png'},
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(_maskedCards, findsNWidgets(3));
    expect(_maskedCard('img1.png'), findsNothing);
    expect(find.text('Unlocked 1 / 4'), findsOneWidget);
  });
}
