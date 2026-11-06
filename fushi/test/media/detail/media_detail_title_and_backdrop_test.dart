// 详情页的两处重复 / 割裂（反馈 g7NgcM5F1b，所有 MediaDetailLayout 详情页共用）：
//  * 顶栏标题与 hero 大标题同屏重复：顶栏标题初始隐藏，正文滚过阈值后淡入；
//  * hero 底部一条带阴影的硬边：模糊封面的晕边没被裁剪，晕到 hero 之外压在下方内容上。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:material_ui/material_ui.dart';

const String _title = '君が一等星に光るまで 01';

// 1x1 透明 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

double _titleOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.byKey(const ValueKey<String>('fushi_page_header_title_fade')),
    )
    .opacity;

void main() {
  testWidgets('顶栏标题初始隐藏，滚过阈值后淡入，滚回去再隐藏', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiPageScaffold(
          title: _title,
          revealTitleAfterScroll: kMediaDetailTitleRevealOffset,
          body: ListView(
            children: <Widget>[
              for (int i = 0; i < 40; i++)
                SizedBox(height: 80, child: Text('row $i')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 0, reason: 'hero 里已有大标题，顶栏标题不该同屏出现');

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 1);

    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 0);
  });

  testWidgets('不传 revealTitleAfterScroll：标题恒显示（其它页面行为不变）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiPageScaffold(
          title: _title,
          body: ListView(children: const <Widget>[SizedBox(height: 2000)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_page_header_title_fade')),
      findsNothing,
    );
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('模糊封面背景被裁在 hero 框内（晕边不压到下方内容）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: MediaDetailBackdrop(image: MemoryImage(_png)),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byType(ImageFiltered),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
      reason: 'ImageFiltered 默认不裁剪，模糊晕边会画到 hero 底边之外形成「阴影硬边」',
    );
  });
  // BUG-3355（反馈 kVwc9NMu2x「漫画点开顶上有莫名的毛玻璃」）：AnimatedSwitcher 的
  // 默认布局给子项松约束，Image 不铺满、按宽高比缩成居中的一条竖图——两栏详情页
  // 顶部只剩窗口中间一块模糊竖条。两种背景（模糊封面 / 原样 fanart）都必须铺满。
  for (final double sigma in <double>[28, 0]) {
    testWidgets('背景图铺满整块（blurSigma=$sigma）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 700,
              height: 400,
              child: MediaDetailBackdrop(
                image: MemoryImage(_png),
                blurSigma: sigma,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byType(Image)), const Size(700, 400));
    });
  }

  // 手机单列 hero 是竖长容器：横版 fanart 铺满会被放大四五倍、再被两栏用的起始侧
  // 底色冲成白雾（反馈「看不到背景插画」）。露画面时只画在顶部与宽等高的带里。
  testWidgets('竖长容器里露画面的 fanart 只占顶部画面带', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 560,
            child: MediaDetailBackdrop(
              image: MemoryImage(_png),
              blurSigma: 0,
              artBand: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Finder image = find.byType(Image);
    expect(tester.getSize(image), const Size(400, 400));
    expect(tester.getTopLeft(image), Offset.zero);
    final Iterable<LinearGradient> gradients = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((DecoratedBox box) => box.decoration)
        .whereType<BoxDecoration>()
        .map((BoxDecoration d) => d.gradient)
        .whereType<LinearGradient>();
    expect(
      gradients.where(
        (LinearGradient g) => g.begin == AlignmentDirectional.centerStart,
      ),
      isEmpty,
      reason: '单列 hero 文字居中，两栏用的起始侧底色只会把画面冲淡',
    );
  });

  // PR #2337 审查：画面带曾按容器 height > width 自动判定，两栏整页背景（竖屏大屏 /
  // 桌面窄高窗）与宽式 hero 展开长简介后都高 > 宽，被误切成顶部一条带。判据改由
  // 调用方显式给（artBand），没传就铺满。
  testWidgets('未要求画面带时，竖长容器里露画面的 fanart 仍铺满', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 560,
            child: MediaDetailBackdrop(image: MemoryImage(_png), blurSigma: 0),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(Image)), const Size(400, 560));
  });

  testWidgets('宽式 hero 内容高于宽度时背景铺满，不切画面带', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 2000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaDetailHero(
              title: _title,
              backdrop: MemoryImage(_png),
              backdropBlur: 0,
              // 展开后的长简介：把 hero 撑到高 > 宽。
              footer: const SizedBox(height: 1200),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Size hero = tester.getSize(find.byType(MediaDetailBackdrop));
    expect(hero.width, greaterThanOrEqualTo(kMediaDetailHeroWideMinWidth));
    expect(hero.height, greaterThan(hero.width));
    expect(tester.getSize(find.byType(Image)), hero);
  });

  testWidgets('窄式 hero 露画面时只占顶部画面带', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 2000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaDetailHero(
              title: _title,
              backdrop: MemoryImage(_png),
              backdropBlur: 0,
              footer: const SizedBox(height: 800),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Size hero = tester.getSize(find.byType(MediaDetailBackdrop));
    expect(hero.height, greaterThan(hero.width));
    expect(tester.getSize(find.byType(Image)), Size(hero.width, hero.width));
  });

  testWidgets('竖长容器里的模糊封面仍铺满（只在色彩垫底，不受画面带影响）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 560,
            child: MediaDetailBackdrop(image: MemoryImage(_png)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(Image)), const Size(400, 560));
  });

  group('MediaDetailSynopsis', () {
    Future<void> pumpSynopsis(WidgetTester tester, int lines) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                child: MediaDetailSynopsis(
                  text: List<String>.generate(
                    lines,
                    (int i) => 'line $i',
                  ).join('\n'),
                ),
              ),
            ),
          ),
        );

    testWidgets('只超出一行不出折叠按钮', (WidgetTester tester) async {
      await pumpSynopsis(tester, 5);
      expect(
        find.byKey(const ValueKey<String>('media-detail-synopsis-toggle')),
        findsNothing,
      );
    });

    testWidgets('超出两行以上才出折叠按钮', (WidgetTester tester) async {
      await pumpSynopsis(tester, 6);
      expect(
        find.byKey(const ValueKey<String>('media-detail-synopsis-toggle')),
        findsOneWidget,
      );
    });
  });
}
