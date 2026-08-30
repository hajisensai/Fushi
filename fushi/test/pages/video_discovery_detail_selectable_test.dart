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
          related: <VideoDiscoveryItem>[
            VideoDiscoveryItem(
              reference: VideoMediaReference(
                providerId: 'tmdb',
                mediaId: '101',
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.tv,
                title: '相关作品甲',
                year: 2023,
              ),
            ),
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
    //
    // 注意这里**不包含**横向人物条/相关作品条里的文字：它们是懒加载列表，按
    // flutter#119355 必须排除在选区之外（见下面的 flutter#119355 守卫）。
    for (final String text in <String>[
      '薬屋のひとりごと 第2期',
      'The Apothecary Diaries Season 2',
      '这是一段在线作品简介。',
      '24',
      'TOHO animation STUDIO · OLM',
    ]) {
      expect(
        find.descendant(of: area, matching: find.text(text)),
        findsOneWidget,
        reason: '「$text」必须在 SelectionArea 内，否则复制不了',
      );
    }
  });

  // flutter#119355 —— 本仓已吃过两次的 release-only 崩溃（BUG-694、BUG-1582）。
  //
  // 触发链：SelectionArea 套 Scrollable → 选中文字 → 滚走（选区端点所在的 item 被
  // itemBuilder 回收）→ 再长按 → `_ScrollableSelectionContainerDelegate`
  // `._updateDragLocationsFromGeometries()` 无条件读 `endSelectionPoint!` 抛空断言。
  // debug 下 `assert(geometry.hasSelection)` 先一步拦住，所以 widget 测试**打不出
  // 那次空断言本身**（与 BUG-1582 记录的 headless 复现边界同因）。
  //
  // 因此守卫钉的是能消除触发条件的结构不变式：**页级 SelectionArea 的子树里，任何
  // 懒加载（builder-delegate）列表都必须落在一个禁用选区的 SelectionRegistrarScope
  // 下**——`SelectionContainer.maybeOf` 返回 null 就等于「这里的 Text 一个 Selectable
  // 都不注册」，被回收的 item 也就不可能是选区端点。
  //
  // 判据用运行时的框架 API（`SelectionContainer.maybeOf`）而不是源码文本扫描：
  // 它认的是语义（有没有可用的 registrar），不受写法、缩进、CRLF 影响，也自动覆盖
  // 以后新增的懒加载区块。
  testWidgets(
      '懒加载列表不得裸露在页级 SelectionArea 内（flutter#119355 / BUG-694 / BUG-1582）',
      (WidgetTester tester) async {
    await pumpPage(tester);

    final Element areaElement = tester.element(find.byType(SelectionArea));
    final List<Element> lazyLists = <Element>[];
    void visit(Element element) {
      final Widget widget = element.widget;
      if (widget is SliverMultiBoxAdaptorWidget &&
          widget.delegate is SliverChildBuilderDelegate) {
        lazyLists.add(element);
      }
      element.visitChildren(visit);
    }

    areaElement.visitChildren(visit);

    // 防「零断言空转」：本页确实有懒加载列表（人物条 + 相关作品条），守卫若一条都
    // 没扫到，说明遍历写错了或页面结构变了，必须失败而不是静默通过。
    expect(
      lazyLists.length,
      greaterThanOrEqualTo(2),
      reason: '本页应当至少有人物条与相关作品条两条懒加载横向列表；'
          '一条都没扫到说明守卫已经空转，先修守卫',
    );

    for (final Element element in lazyLists) {
      expect(
        SelectionContainer.maybeOf(element),
        isNull,
        reason: '懒加载列表 ${element.widget.runtimeType} 仍能拿到 SelectionRegistrar：'
            '它的 item 被 itemBuilder 回收后会把选区端点一起回收掉，'
            'release 下「选中→滚走→再长按」必崩（flutter#119355）。'
            '用 SelectionContainer.disabled 把整条排除在页级选区之外。',
      );
    }
  });

  testWidgets('横向卡片条内的文字不参与页级选区（flutter#119355 的正面表述）',
      (WidgetTester tester) async {
    await pumpPage(tester);

    // 人物条的文字仍然渲染在页面上……
    expect(find.text('演员甲'), findsOneWidget);
    // ……但它拿不到任何 SelectionRegistrar，也就不会注册 Selectable。
    expect(
      SelectionContainer.maybeOf(tester.element(find.text('演员甲'))),
      isNull,
      reason: '横向人物条是懒加载列表，必须整条排除在选区之外',
    );
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
