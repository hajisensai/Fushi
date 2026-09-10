import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/src/reader/reader_gallery_page.dart';

List<EpubImageRef> _images(int n) => <EpubImageRef>[
      for (int i = 0; i < n; i++)
        EpubImageRef(chapterIndex: i ~/ 2, orderInBook: i, src: 'img$i.png'),
    ];

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('模糊设置同步舞台与缩略图，揭开后再按 Enter 才打开查看器', (tester) async {
    final List<String> revealed = <String>[];
    final List<EpubImageRef> opened = <EpubImageRef>[];
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(3),
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: opened.add,
          onJumpTo: (_) {},
          blurImages: true,
          revealedImageKeys: const <String>{'img1.png'},
          onRevealImage: revealed.add,
        ),
      ),
    );
    await tester.pump();
    // 两张尚未揭开的缩略图 + 当前大图；已揭开的 img1 保持清晰。
    expect(find.byType(ImageFiltered), findsNWidgets(3));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(revealed, <String>['img0.png']);
    expect(opened, isEmpty);
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened.single.src, 'img0.png');

    // 切到新图仍遮罩；回到刚揭开的图不会重新模糊。
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('关闭图片模糊后所有插图直接显示', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderGalleryPage(
          images: _images(3),
          currentChapter: 0,
          fileForRef: (_) => null,
          onOpenImage: (_) {},
          onJumpTo: (_) {},
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('空书：显示空态文案，没有缩略图带', (tester) async {
    await tester.pumpWidget(_host(ReaderGalleryPage(
      images: const <EpubImageRef>[],
      currentChapter: 0,
      fileForRef: (_) => null,
      onOpenImage: (_) {},
      onJumpTo: (_) {},
    )));
    expect(
        find.byKey(const ValueKey<String>('fushi_gallery_jump')), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('初始定位到当前章首图；箭头 / 方向键切图；跳转回调带当前图', (tester) async {
    EpubImageRef? jumped;
    await tester.pumpWidget(_host(ReaderGalleryPage(
      images: _images(6),
      currentChapter: 2, // 首图下标 4
      fileForRef: (_) => null, // 无文件 → broken 图标，不触碰磁盘
      onOpenImage: (_) {},
      onJumpTo: (EpubImageRef r) => jumped = r,
    )));
    await tester.pump();
    expect(find.text('5 / 6'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('6 / 6'), findsOneWidget);

    // 末尾右箭头禁用；左方向键回退。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('5 / 6'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('fushi_gallery_jump')));
    expect(jumped?.orderInBook, 4);
  });

  testWidgets('缩略图带条目数 == 图片数；点缩略图切图', (tester) async {
    await tester.pumpWidget(_host(ReaderGalleryPage(
      images: _images(3),
      currentChapter: 0,
      fileForRef: (_) => null,
      onOpenImage: (_) {},
      onJumpTo: (_) {},
    )));
    await tester.pump();
    // 3 张缩略图 + 舞台 1 个 broken 图标 = 4 个 broken 图标。
    expect(find.byIcon(Icons.broken_image_outlined), findsNWidgets(4));
    final Finder thumbs = find.byType(AnimatedContainer);
    expect(thumbs, findsNWidgets(3));
    await tester.tap(thumbs.at(2));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
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
