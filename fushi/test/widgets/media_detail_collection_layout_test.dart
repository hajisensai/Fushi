import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';

import '../helpers/source_guard.dart';

/// BUG-3190：作品资料（系列详情）页的三条反馈。
///
/// ① 加载骨架恒画旧的单列样式（封面在左 + 整宽条目），两栏详情页一加载先闪旧版式；
/// ② 横版 fanart 被 16 的模糊 + 72% 底色压成一片色雾（「海报没了 / 在毛玻璃后面」）；
/// ③ hero 的「⋯」与右上角管理菜单重复，「标签」「补齐缺集」左右各一份。
void main() {
  Future<void> pumpSkeleton(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MediaDetailSkeleton())),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder coverBlock() => find.byWidgetPredicate(
    (Widget w) => w is FushiSkeleton && w.width == 150 && w.height == 225,
  );

  testWidgets('① 两栏宽度：骨架左栏是居中封面的窄式 hero，右栏是集卡', (WidgetTester tester) async {
    await pumpSkeleton(tester, const Size(1600, 900));
    expect(coverBlock(), findsOneWidget, reason: '左栏 2:3 封面居中，与加载后同形');
    final Offset cover = tester.getCenter(coverBlock());
    expect(cover.dx, closeTo(kMediaDetailSidePaneWidth / 2, 1));
    // 右栏集卡缩略图块在左栏之外。
    final Finder thumbs = find.byWidgetPredicate(
      (Widget w) => w is FushiSkeleton && w.width == 168 && w.height == 96,
    );
    expect(thumbs, findsWidgets);
    expect(
      tester.getTopLeft(thumbs.first).dx,
      greaterThan(kMediaDetailSidePaneWidth),
    );
  });

  testWidgets('① 手机宽度：窄式 hero 居中，下接条目', (WidgetTester tester) async {
    await pumpSkeleton(tester, const Size(390, 844));
    expect(coverBlock(), findsOneWidget);
    expect(tester.getCenter(coverBlock()).dx, closeTo(195, 1));
  });

  testWidgets('② 横版 fanart 原样露出（不模糊），封面垫底仍模糊', (WidgetTester tester) async {
    expect(kCollectionHeroBackdropBlur, 0);
    final Uint8List bytes = (await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFFFF0000),
      );
      final ui.Image raw = await recorder.endRecording().toImage(4, 4);
      final ByteData? png = await raw.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return png!.buffer.asUint8List();
    }))!;
    final ImageProvider image = MemoryImage(bytes);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaDetailBackdrop(
          image: image,
          blurSigma: collectionHeroBackdropBlur(backdrop: image),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaDetailBackdrop(
          image: image,
          blurSigma: collectionHeroBackdropBlur(),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  test('③ hero 不再挂「⋯」，右上角菜单不重复 hero 的「标签 / 补齐缺集」', () {
    final String page = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    final String hero = methodBody(page, 'Widget _buildHero(');
    expect(hero.contains('moreItems:'), isFalse);
    final String appBar = maskComments(
      methodBody(page, 'PreferredSizeWidget _buildAppBar('),
    );
    expect(appBar.contains('t.tag_label'), isFalse);
    expect(appBar.contains('t.collection_episode_fill_missing'), isFalse);
    final String secondary = methodBody(
      page,
      'List<Widget> _heroSecondaryActions(',
    );
    expect(secondary.contains('t.tag_label'), isTrue);
    expect(secondary.contains('t.collection_episode_fill_missing'), isTrue);
  });

  test('宽屏可切「海报横幅」版式：开关只在两栏宽度出现，切到后整页走单列', () {
    final String page = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    expect(
      page.contains("ValueKey<String>('collection-detail-layout-toggle')"),
      isTrue,
    );
    expect(
      page.contains('twoPaneMinWidth: _posterLayout'),
      isTrue,
      reason: '海报横幅 = 宽屏也走单列（hero 连同 fanart 横幅在顶）',
    );
    expect(
      page.contains('setVideoDetailPosterLayout('),
      isTrue,
      reason: '用户的选择跨作品记住',
    );
  });
}
