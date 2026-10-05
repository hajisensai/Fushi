import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiThemeData;
import 'package:fushi/utils.dart';

import '../helpers/source_guard.dart';
import '../helpers/glass_unwrap.dart';

/// 书架 / 漫画 / 视频 / 游戏四个模块的顶栏分区导航统一走 [LibrarySectionTabs]
/// （唯一实现），形态是 MD3 primary tabs。
///
/// 历史（TODO-2937）：顶栏曾是 [SegmentedButton]，那是个**等宽**控件——每段被撑到
/// 最长段的宽度，于是四页因段数与文案长度不同而宽窄不一，靠一个统一最小段宽
/// (`kLibrarySectionTabMinSegmentWidth`) 硬垫成同宽。2026-08-24 改走 tabs 后这条
/// 补丁连同它守的不变式一起作废：tab 各自按文案取宽，四页观感一致由「同一个控件、
/// 同一套内边距与指示器」保证，不再需要估算出来的下限。
///
/// 本文件因此守两件**换控件之后**才成立、且直接对应用户报障的事：
/// * 同一段文案在任何顶栏配置、任何窗口宽度下渲染同宽（旧等宽方案做不到：一段的
///   宽度被同排最长段绑架，窄屏还会整体退化）；
/// * 四页都不许绕过共享组件自己拼一排导航。
void main() {
  setUp(() => LocaleSettings.setLocaleRaw('zh-CN'));
  tearDown(() => LocaleSettings.setLocaleRaw('en'));

  Future<void> pumpTabs(
    WidgetTester tester,
    List<String> labels, {
    required double width,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LibrarySectionTabs<int>(
              tabs: <LibrarySectionTab<int>>[
                for (int i = 0; i < labels.length; i++)
                  LibrarySectionTab<int>(value: i, label: labels[i]),
              ],
              selected: 0,
              onChanged: (int _) {},
              focusIdPrefix: 'uniform-test',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 相邻两段的中心距 = 两段各自占用横向空间的一半之和，是「这一格多宽」的可测代理。
  ///
  /// 不能直接量 [Tab] 的 rect：等宽布局下 [Tab] 自身仍是文案自然宽，被撑开的是它
  /// 外层由 TabBar 布局的格子——量 [Tab] 会得到一个**恒真**的断言（本文件早先的写法
  /// 正是这样，变异实测时等宽变异一次都没被抓到）。
  double centerGap(WidgetTester tester, String left, String right) =>
      tester.getRect(find.widgetWithText(Tab, right)).center.dx -
      tester.getRect(find.widgetWithText(Tab, left)).center.dx;

  const List<String> videoTabs = <String>[
    '首页',
    '系列',
    '全部视频',
    '发现',
    '来源',
    '设置',
  ];

  testWidgets('段宽由各自文案决定，不被同排最长段绑架', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 2026-10-04 全宽顶栏：宽窗口里各段等分铺满（`fill` 档，等分格放得下最长段
    // 才走这档，不会截字）；等分放不下时退到「按各自文案取宽、均摊余宽」的
    // natural 档。本条守的就是那一档——400 宽放不下 6 个等分格，却放得下各段
    // 自然宽 + 最小内边距。
    await pumpTabs(tester, videoTabs, width: 400);

    // 「系列」(2 字) → 「全部视频」(4 字) 的中心距，必须明显大于两个 2 字段之间的
    // 中心距。等宽控件下每格同宽、两个距离相等——那正是旧顶栏把 6 段撑到装不下、
    // 尾段被切掉的成因。
    final double shortToShort = centerGap(tester, '首页', '系列');
    final double shortToLong = centerGap(tester, '系列', '全部视频');

    expect(
      shortToLong,
      greaterThan(shortToShort + 8.0),
      reason: '4 字段应比 2 字段占更多横向空间；两者相等即说明退回了等宽布局',
    );
  });

  testWidgets('窄屏不裁字：摆不下的段收进「更多」，可见段文案完整', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 2026-10-04 全宽顶栏（用户：「移动端摆不下你想想办法」）：窄屏不再横滑截断，
    // 而是逐级收紧，仍不够就把尾段收进末尾「更多」下拉。旧等宽方案在窄屏把每格
    // 压到「可用宽 / 段数」并裁字（用户看到的「全部视」被切成半个胶囊）——这条
    // 不变式在新形态下依然要成立：凡是画出来的段，文案必须完整、整段在屏内。
    for (final double width in <double>[402, 220]) {
      await pumpTabs(tester, videoTabs, width: width);
      expect(tester.takeException(), isNull);

      final List<String> shown = <String>[
        for (final String label in videoTabs)
          if (find.widgetWithText(Tab, label).evaluate().isNotEmpty) label,
      ];
      for (final String label in shown) {
        final RenderParagraph text = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.widgetWithText(Tab, label),
            matching: find.text(label),
          ),
        );
        expect(
          text.size.width,
          greaterThanOrEqualTo(text.getMaxIntrinsicWidth(double.infinity) - 0.5),
          reason: '$width 宽下「$label」被压窄裁字',
        );
        final Rect rect = tester.getRect(find.widgetWithText(Tab, label));
        expect(rect.left, greaterThanOrEqualTo(-0.5));
        expect(rect.right, lessThanOrEqualTo(width + 0.5),
            reason: '$width 宽下「$label」被挤出屏外');
      }
      if (shown.length < videoTabs.length) {
        // 没画出来的段必须能从「更多」里够到，而不是凭空消失。
        expect(find.byIcon(Icons.expand_more), findsOneWidget,
            reason: '$width 宽下有段没画出来，却没有「更多」入口');
      }
    }
  });

  testWidgets('Apple 设计下窄屏四段不被渐隐截断（浏览页「在线源」）', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 2026-10-05 用户截图：手机上浏览页顶部「发现 / 在线源 / 扩展 / 下载」放得下，
    // 「在线源」却被 Tab 自带的渐隐切掉。根因：Apple 文字页签在 label 内边距
    // 之内文字两侧各还有一圈内衬（kFushiAppleTabContentInset），铺满判据漏算，
    // 判「等分放得下」，实际每格比文字窄。扫一段宽度，凡画出来的段都必须完整。
    const List<String> labels = <String>['发现', '在线源', '扩展', '下载'];
    for (double width = 240; width <= 420; width += 6) {
      await tester.binding.setSurfaceSize(Size(width, 400));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            textTheme: Typography.material2021().white,
            glass: FushiGlassMaterial.frosted,
            glassDesign: true,
          ),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: LibrarySectionTabs<int>(
                tabs: <LibrarySectionTab<int>>[
                  for (int i = 0; i < labels.length; i++)
                    LibrarySectionTab<int>(value: i, label: labels[i]),
                ],
                selected: 0,
                onChanged: (int _) {},
                focusIdPrefix: 'apple-inset-test',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final String label in labels) {
        final Finder text = find.text(label);
        if (text.evaluate().isEmpty) continue;
        final RenderParagraph paragraph =
            tester.renderObject<RenderParagraph>(text);
        expect(
          paragraph.size.width,
          greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5,
          ),
          reason: '$width 宽下「$label」被压窄（渐隐截断）',
        );
      }
    }
  });

  testWidgets('顶栏形态是 MD3 tabs，不是分段按钮', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTabs(
      tester,
      <String>['首页', '系列', '全部视频', '发现', '来源', '设置'],
      width: 1600,
    );

    // 2026-10-04 全宽顶栏：宽窗口里各段等分铺满整行（MD3 fixed tabs），不滚动。
    final TabBar bar = tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar)));
    expect(bar.isScrollable, isFalse, reason: '摆得下时铺满整行，不是贴左滚动');
    expect(
      bar.tabAlignment,
      TabAlignment.fill,
      reason: '全宽顶栏：各段等分可用宽度',
    );
    expect(
      centerGap(tester, '首页', '系列'),
      closeTo((1600 - kFushiM3eTabTrackInset * 2) / 6, 1),
      reason: '六段等分 1600 宽（扣掉 M3E 分段胶囊轨道两侧内缩）',
    );
    expect(
      find.byType(SegmentedButton<int>),
      findsNothing,
      reason: 'MD3：分段按钮是 section 级单选控件，不得替代导航 tabs',
    );
  });

  testWidgets('宿主拒绝切换时指示器不许停在未生效的分区上', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 900));

    // 宿主收下点击但**不改** selected——真实存在的分支：游戏页的「设置」段可由宿主
    // 改成打开别的页面而不切分区。TabBar 自己已经把指示器移过去了，若没有「controller
    // 只是 selected 的投影」这条校正，指示器会停在一个并未生效的分区上。
    final List<int> taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LibrarySectionTabs<int>(
              tabs: <LibrarySectionTab<int>>[
                for (int i = 0; i < videoTabs.length; i++)
                  LibrarySectionTab<int>(value: i, label: videoTabs[i]),
              ],
              selected: 0,
              onChanged: taps.add,
              focusIdPrefix: 'reject-test',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, '全部视频'));
    await tester.pumpAndSettle();

    expect(taps, <int>[2], reason: '点击必须照常上报给宿主');
    expect(
      tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).controller!.index,
      0,
      reason: '宿主没改 selected，指示器必须被拉回——controller 是 selected 的投影，'
          '不是第二份真相',
    );
  });

  testWidgets('controlled 形态共用宿主 TabController，不镜像出第二份选中态',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 900));

    // 宿主（下载页）自己持有 controller 驱动 TabBarView。导航组件必须共用**那一个**：
    // 镜像出第二个 controller 时，横滑 TabBarView 的连续进度传不到指示器上，指示器
    // 只能在宿主 index 越过一半跳变时跟着跳一下。
    final TabController host = TabController(length: 4, vsync: const TestVSync());
    addTearDown(host.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LibrarySectionTabs<int>.controlled(
              tabs: const <LibrarySectionTab<int>>[
                LibrarySectionTab<int>(value: 0, label: '资源'),
                LibrarySectionTab<int>(value: 1, label: '任务'),
                LibrarySectionTab<int>(value: 2, label: '订阅'),
                LibrarySectionTab<int>(value: 3, label: '设置'),
              ],
              controller: host,
              focusIdPrefix: 'controlled-test',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      identical(tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).controller, host),
      isTrue,
      reason: 'TabBar 必须挂在宿主那一个 controller 上，不得自建第二个',
    );

    // 点击必须直接落到宿主 controller（页内 TabBarView 靠它换页）。
    await tester.tap(find.widgetWithText(Tab, '订阅'));
    await tester.pumpAndSettle();
    expect(host.index, 2, reason: '点段必须真的驱动宿主 controller');

    // 反向：宿主自己换页（横滑 / 外部 animateTo）时指示器跟着走。
    host.animateTo(0);
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).controller!.index, 0);
  });

  testWidgets('fill 形态摆得下时铺满整行、摆不下时退回可滚动',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 「浏览」各页签的二级标签（小说 / 漫画 / 视频）要铺满整行，而不是挤在左边。
    Future<void> pumpFill(double width) async {
      await tester.binding.setSurfaceSize(Size(width, 600));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibrarySectionTabs<int>(
              tabs: const <LibrarySectionTab<int>>[
                LibrarySectionTab<int>(value: 0, label: '小说'),
                LibrarySectionTab<int>(value: 1, label: '漫画'),
                LibrarySectionTab<int>(value: 2, label: '视频'),
              ],
              selected: 0,
              onChanged: (int _) {},
              focusIdPrefix: 'fill-test',
              secondary: true,
              fill: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpFill(900);
    expect(tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).isScrollable, isFalse);
    // 三段等分整行：相邻两段中心距 = 行宽 / 3，末段中心在 5/6 处（贴左形态下
    // 三段全挤在左边一两百像素内）。
    // M3E 分段胶囊轨道两侧各内缩 kFushiM3eTabTrackInset。
    const double track = 900 - kFushiM3eTabTrackInset * 2;
    expect(centerGap(tester, '小说', '漫画'), closeTo(track / 3, 1));
    expect(
      tester.getRect(find.widgetWithText(Tab, '视频')).center.dx,
      closeTo(kFushiM3eTabTrackInset + track * 5 / 6, 1),
    );

    await pumpFill(120);
    expect(tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).isScrollable, isTrue,
        reason: '摆不下时必须退回可滚动，不能把段挤到截字');
    expect(tester.takeException(), isNull);
  });

  test('顶层页分区导航收敛到 LibrarySectionTabs（不许各写一份）', () {
    const Map<String, String> topBarSources = <String, String>{
      '书架/漫画': 'lib/src/pages/implementations/media_library_shell.dart',
      '视频': 'lib/src/pages/implementations/video_library_shell.dart',
      '游戏': 'lib/src/pages/implementations/game_shared.dart',
      // 下载页也是顶层 tab、也切四个独立目的地，同属这条收敛（它页内还有
      // TabBarView，走 controlled 形态共用同一个 TabController）。
      '下载': 'lib/src/pages/implementations/browse_page.dart',
    };
    for (final MapEntry<String, String> entry in topBarSources.entries) {
      final String src = File(entry.value).readAsStringSync();
      // 下载页的资源子页另有一个合法的 section 级内容域分段条；这里只检查
      // 顶层门头，防止把“顶层导航不得用分段按钮”误扩成整文件禁用。
      final String topBarSource = entry.key == '下载'
          ? methodBody(src, 'Widget _buildHeader(')
          : src;
      expect(
        topBarSource.contains('LibrarySectionTabs<'),
        isTrue,
        reason: '${entry.key} 顶栏（${entry.value}）应使用共享的 LibrarySectionTabs',
      );
      for (final String bypass in <String>[
        'FushiSegmentedStrip<',
        'SegmentedButton<',
        'TabBar(',
      ]) {
        expect(
          topBarSource.contains(bypass),
          isFalse,
          reason: '${entry.key} 顶栏（${entry.value}）不应绕过共享组件手拼一排导航'
              '（发现的 `$bypass`：焦点约定与几何会随调用点漂移）',
        );
      }
    }
  });

  test('可滚动顶栏必须显式接桌面鼠标拖滚', () {
    // Flutter 桌面默认 dragDevices 不含 mouse，`TabBar(isScrollable: true)` 自己
    // 只带「选中段自动滚入」，**不带**拖滚。旧的等宽段条外面本来就包着
    // HorizontalDragScrollable，换控件那次一起丢了：一旦溢出（窄窗 / 界面缩放 /
    // 德俄长文案），桌面用户拖不动，只剩键盘、手柄或点那半截 tab。
    //
    // 既有的 horizontal_drag_scroll_guard 判据是字面量 `scrollDirection: Axis.
    // horizontal`，`isScrollable: true` 这一形态结构上落在它的扫描面外——所以那次
    // 回归 CI 一声不响。这条补的就是那个缺口。
    final String src =
        File('lib/src/utils/components/library_section_tabs.dart')
            .readAsStringSync();
    // 2026-10-04 起可滚动与否随档位切换（`isScrollable: scrollable`），可滚动档
    // （fill: false / 等分放不下的 natural 档）仍在。
    expect(src.contains('isScrollable: scrollable'), isTrue,
        reason: '锚点过期：顶栏不再有可滚动档，请同步改本守卫');
    expect(
      src.contains('HorizontalDragScrollable('),
      isTrue,
      reason: '可滚动顶栏必须包 HorizontalDragScrollable，否则桌面鼠标拖不动溢出的段',
    );
  });
}
