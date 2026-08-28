import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';

/// BUG-1901：番剧详情页的标题不能选中复制，下面的简介却可以
/// （用户 2026-08-28：「这个界面，不能复制文件名，下面的简介可以」）。
///
/// 根因不是 `SelectionArea` 的包裹范围问题——改前整个 `fushi/lib` 只有日志查看器一处
/// `SelectionArea`，与本页毫无祖先关系。真相是**逐 widget 手工选型**：谁被想起来写成
/// `SelectableText` 谁能选。改前全页 15 个文本元素只有简介和 facts 右列 2 个可选。
///
/// 逐个补 `SelectableText` 只是把这个特殊情况再复制 13 份，下次加字段照样漏。修法是
/// 页级 `SelectionArea`，让「可选」成为默认。
///
/// 本测试守的是**结构不变量**（每个正文文本都在同一个 SelectionArea 子树里），
/// 而不是某个 widget 用了什么类型——后者恰恰是这个 bug 的形态。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  VideoDiscoveryItem item() => VideoDiscoveryItem(
        reference: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '100',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: '薬屋のひとりごと 第2期',
          originalTitle: 'The Apothecary Diaries Season 2',
          year: 2025,
        ),
        overview: '这是一段在线作品简介。',
        score: 8.8,
        genres: const <String>['Drama', 'Mystery'],
      );

  VideoDiscoveryActions actions(VideoDiscoveryItem value) =>
      VideoDiscoveryActions(
        loadDetails: (_) async => VideoDiscoveryDetailData(
          item: value,
          facts: const <VideoDiscoveryFact>[
            VideoDiscoveryFact(label: '话数', value: '24'),
            VideoDiscoveryFact(
                label: '工作室', value: 'TOHO animation STUDIO · OLM'),
          ],
          people: const <VideoDiscoveryPerson>[
            VideoDiscoveryPerson(name: '演员甲', role: '主角'),
          ],
        ),
        watchStatus: (_) =>
            const Stream<VideoDiscoveryAcquisitionState>.empty(),
        onSearchResource: (_, __) async {},
        onSearchSubtitle: (_, __) async {},
        onSubscribe: (_, __) async {},
        onPlay: (_, __) async {},
      );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final VideoDiscoveryItem value = item();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: VideoDiscoveryDetailPage(item: value, actions: actions(value)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('标题、原标题、简介、元数据全部落在同一个 SelectionArea 子树内（BUG-1901）',
      (WidgetTester tester) async {
    await pumpPage(tester);

    final Finder area = find.byType(SelectionArea);
    expect(area, findsOneWidget,
        reason: '整页必须有且只有一个 SelectionArea —— 多个会把选区切碎');

    // 用户点名的那一条：标题。改前它是裸 Text 且没有任何 SelectionArea 祖先。
    for (final String text in <String>[
      '薬屋のひとりごと 第2期',
      'The Apothecary Diaries Season 2',
      '这是一段在线作品简介。',
      '24',
      'TOHO animation STUDIO · OLM',
      '演员甲',
    ]) {
      expect(
        find.descendant(of: area, matching: find.text(text)),
        findsOneWidget,
        reason: '「$text」必须在 SelectionArea 内，否则复制不了',
      );
    }
  });

  testWidgets('页内不再有自建选区的 SelectableText（否则切断跨元素拖选）',
      (WidgetTester tester) async {
    await pumpPage(tester);

    expect(
      find.byType(SelectableText),
      findsNothing,
      reason: '嵌套在 SelectionArea 里的 SelectableText 会自成独立选区，'
          '让「标题连着简介一起拖选」失效；统一交给页级 SelectionArea',
    );
  });

  testWidgets('SelectionArea 不吃按钮点击（回归守卫）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool searchedResource = false;
    bool subscribed = false;
    final VideoDiscoveryItem value = item();
    final VideoDiscoveryActions acts = VideoDiscoveryActions(
      loadDetails: (_) async => VideoDiscoveryDetailData(item: value),
      watchStatus: (_) => const Stream<VideoDiscoveryAcquisitionState>.empty(),
      onSearchResource: (_, __) async => searchedResource = true,
      onSearchSubtitle: (_, __) async {},
      onSubscribe: (_, __) async => subscribed = true,
      onPlay: (_, __) async {},
    );

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: VideoDiscoveryDetailPage(item: value, actions: acts),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-search-resource')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-subscribe')),
    );
    await tester.pumpAndSettle();

    expect(searchedResource, isTrue, reason: 'SelectionArea 不得吞掉子树里的按钮点击');
    expect(subscribed, isTrue);
  });
}
