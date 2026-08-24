import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

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
    await pumpTabs(tester, videoTabs, width: 1600);

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

  testWidgets('窄屏靠滚动容纳，段几何不变（不压窄、不裁字）', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpTabs(tester, videoTabs, width: 1600);
    final double wide = centerGap(tester, '系列', '全部视频');

    // 手机竖屏宽：整排放不下。旧等宽方案在这一档把每格压到「可用宽 / 段数」并裁字
    // （用户看到的「全部视」被切成半个胶囊）；tabs 保持各段几何、整排横向滚动。
    await pumpTabs(tester, videoTabs, width: 402);
    final double narrow = centerGap(tester, '系列', '全部视频');

    expect(
      narrow,
      moreOrLessEquals(wide, epsilon: 0.5),
      reason: '窄屏不得改变单段几何——放不下要滚动，不是把每段压窄',
    );
  });

  testWidgets('顶栏形态是 MD3 tabs，不是分段按钮', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTabs(
      tester,
      <String>['首页', '系列', '全部视频', '发现', '来源', '设置'],
      width: 1600,
    );

    final TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isTrue, reason: '段数可变，滚动是正常形态而非降级');
    expect(
      bar.tabAlignment,
      TabAlignment.start,
      reason: '首段必须与页头标题左缘对齐（默认 startOffset 会留 52px 缩进）',
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
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
      0,
      reason: '宿主没改 selected，指示器必须被拉回——controller 是 selected 的投影，'
          '不是第二份真相',
    );
  });

  test('四模块顶栏分区导航收敛到 LibrarySectionTabs（不许各写一份）', () {
    const Map<String, String> topBarSources = <String, String>{
      '书架/漫画': 'lib/src/pages/implementations/media_library_shell.dart',
      '视频': 'lib/src/pages/implementations/video_library_shell.dart',
      '游戏': 'lib/src/pages/implementations/game_shared.dart',
    };
    for (final MapEntry<String, String> entry in topBarSources.entries) {
      final String src = File(entry.value).readAsStringSync();
      expect(
        src.contains('LibrarySectionTabs<'),
        isTrue,
        reason: '${entry.key} 顶栏（${entry.value}）应使用共享的 LibrarySectionTabs',
      );
      for (final String bypass in <String>[
        'FushiSegmentedStrip<',
        'SegmentedButton<',
        'TabBar(',
      ]) {
        expect(
          src.contains(bypass),
          isFalse,
          reason: '${entry.key} 顶栏（${entry.value}）不应绕过共享组件手拼一排导航'
              '（发现的 `$bypass`：焦点约定与几何会随调用点漂移）',
        );
      }
    }
  });
}
