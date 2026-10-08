import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';

/// BUG-2832：播放区被右侧字幕列表挤窄后，底栏传输键被 `FittedBox` 等比缩成米粒大、
/// 顶栏右组被横滚 `ListView` 裁成半个图标。这里钉住替代方案 [VideoControlBar]：
/// 按钮永远原尺寸，放不下先退紧凑形态、再按优先级收进「⋯」。
void main() {
  group('videoBottomBarCenterStart', () {
    test('空间充裕时居中', () {
      expect(
        videoBottomBarCenterStart(
          width: 1000,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 200,
        ),
        350,
      );
    });

    test('右簇宽到会被居中簇压住时，中簇左移贴住右簇左缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 700,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 250,
        ),
        150,
      );
    });

    test('左簇宽到会被压住时，中簇右移贴住左簇右缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 700,
          leftWidth: 250,
          centerWidth: 300,
          rightWidth: 100,
        ),
        250,
      );
    });

    test('空隙不够时贴左簇右缘', () {
      expect(
        videoBottomBarCenterStart(
          width: 500,
          leftWidth: 100,
          centerWidth: 300,
          rightWidth: 200,
        ),
        100,
      );
    });
  });

  group('planVideoControlBar', () {
    // 截图里的底栏：时间 / −10s / 上一句 / 播放 / 下一句 / +10s / 音量 / 倍速 / 加号。
    const List<VideoBarMeasure> bar = <VideoBarMeasure>[
      VideoBarMeasure(fullWidth: 110), // 0 时间（钉死）
      VideoBarMeasure(
        fullWidth: 70,
        compactWidth: 40,
        priority: 80,
        group: VideoBarHideGroup.seek,
      ), // 1 −10s
      VideoBarMeasure(
        fullWidth: 40,
        priority: 75,
        group: VideoBarHideGroup.cue,
      ), // 2 上一句
      VideoBarMeasure(fullWidth: 48), // 3 播放（钉死）
      VideoBarMeasure(
        fullWidth: 40,
        priority: 75,
        group: VideoBarHideGroup.cue,
      ), // 4 下一句
      VideoBarMeasure(
        fullWidth: 70,
        compactWidth: 40,
        priority: 80,
        group: VideoBarHideGroup.seek,
      ), // 5 +10s
      VideoBarMeasure(fullWidth: 40, priority: 70), // 6 音量
      VideoBarMeasure(fullWidth: 40, priority: 65), // 7 倍速
      VideoBarMeasure(fullWidth: 40, priority: 20), // 8 加号
    ];
    // 原样总宽 498，紧凑总宽 438。

    VideoBarPlan plan(double width) => planVideoControlBar(
      entries: bar,
      maxWidth: width,
      overflowButtonWidth: 40,
    );

    test('放得下就原样，不换紧凑也不收', () {
      expect(plan(498), VideoBarPlan.showAll);
      expect(plan(1000), VideoBarPlan.showAll);
    });

    test('无界宽度一律原样', () {
      expect(plan(double.infinity), VideoBarPlan.showAll);
    });

    test('原样放不下但紧凑放得下：只去掉 ±10s 的文字，一个都不收', () {
      expect(plan(497), const VideoBarPlan(compact: true));
      expect(plan(438), const VideoBarPlan(compact: true));
    });

    test('紧凑也放不下：从优先级最低的开始收，且为「⋯」留出宽度', () {
      // 438 - 40(加号) + 40(⋯) = 438 > 437 → 还得收倍速：398 + 40 = 438 - 40 = 398 ≤ 437。
      expect(plan(437), const VideoBarPlan(compact: true, hidden: <int>{8, 7}));
    });

    test('成对的按钮一起收：不会出现只剩 −10s 没有 +10s', () {
      // 收到 cue 组后：110+40+48+40+40 = 278；278 + 40 = 318。
      final VideoBarPlan p = plan(320);
      expect(p.hidden, containsAll(<int>[2, 4]));
      expect(p.hidden.contains(1), p.hidden.contains(5));
    });

    test('钉死项永不收，哪怕连它们都放不下', () {
      final VideoBarPlan p = plan(10);
      expect(p.hidden, isNot(contains(0)));
      expect(p.hidden, isNot(contains(3)));
      expect(p.hidden, containsAll(<int>[1, 2, 4, 5, 6, 7, 8]));
    });

    test('同优先级先收靠后的那个', () {
      const List<VideoBarMeasure> same = <VideoBarMeasure>[
        VideoBarMeasure(fullWidth: 40, priority: 50),
        VideoBarMeasure(fullWidth: 40, priority: 50),
        VideoBarMeasure(fullWidth: 40, priority: 50),
      ];
      expect(
        planVideoControlBar(
          entries: same,
          maxWidth: 119,
          overflowButtonWidth: 30,
        ).hidden,
        <int>{2},
      );
    });
  });

  group('videoControlItemBarPriority', () {
    test('返回 / 播放暂停 / 时间钉死', () {
      expect(videoControlItemBarPriority(VideoControlItem.back), isNull);
      expect(videoControlItemBarPriority(VideoControlItem.playPause), isNull);
      expect(
        videoControlItemBarPriority(VideoControlItem.positionIndicator),
        isNull,
      );
    });

    test('除钉死项外每个控件都有优先级，可收进「⋯」', () {
      for (final VideoControlItem item in VideoControlItem.values) {
        if (item == VideoControlItem.back ||
            item == VideoControlItem.playPause ||
            item == VideoControlItem.positionIndicator ||
            item == VideoControlItem.title) {
          continue;
        }
        expect(videoControlItemBarPriority(item), isNotNull, reason: '$item');
      }
    });

    test('成对的两个键同组同优先级', () {
      const List<List<VideoControlItem>> pairs = <List<VideoControlItem>>[
        <VideoControlItem>[
          VideoControlItem.seekBackward,
          VideoControlItem.seekForward,
        ],
        <VideoControlItem>[
          VideoControlItem.previousCue,
          VideoControlItem.nextCue,
        ],
        <VideoControlItem>[
          VideoControlItem.frameBackward,
          VideoControlItem.frameForward,
        ],
      ];
      for (final List<VideoControlItem> pair in pairs) {
        expect(videoControlItemBarHideGroup(pair[0]), isNotNull);
        expect(
          videoControlItemBarHideGroup(pair[0]),
          videoControlItemBarHideGroup(pair[1]),
        );
        expect(
          videoControlItemBarPriority(pair[0]),
          videoControlItemBarPriority(pair[1]),
        );
      }
    });
  });

  group('VideoControlBar 真布局', () {
    const Key timeKey = Key('time');
    const Key seekBackKey = Key('seek-back');
    const Key seekBackCompactKey = Key('seek-back-compact');
    const Key playKey = Key('play');
    const Key seekForwardKey = Key('seek-forward');
    const Key seekForwardCompactKey = Key('seek-forward-compact');
    const Key volumeKey = Key('volume');
    const Key plusKey = Key('plus');
    const Key moreKey = Key('more');

    late List<String> selected;
    late List<String> folded;
    late FocusNode plusFocus;

    Widget box(Key key, double width, {FocusNode? focusNode}) => Focus(
      focusNode: focusNode,
      // ColoredBox 才参与命中测试（裸 SizedBox 不吃命中），hitTestable 才找得到它。
      child: ColoredBox(
        key: key,
        color: const Color(0xFF000000),
        child: SizedBox(width: width, height: 40),
      ),
    );

    VideoBarMenuAction action(String label) => VideoBarMenuAction(
      icon: Icons.circle,
      label: label,
      onSelected: () => selected.add(label),
    );

    List<VideoBarEntry> bottomEntries() => <VideoBarEntry>[
      VideoBarEntry(child: box(timeKey, 110)),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 80,
        group: VideoBarHideGroup.seek,
        menuAction: action('−10s'),
        compactChild: box(seekBackCompactKey, 48),
        child: box(seekBackKey, 80),
      ),
      VideoBarEntry(cluster: VideoBarCluster.center, child: box(playKey, 48)),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 80,
        group: VideoBarHideGroup.seek,
        menuAction: action('+10s'),
        compactChild: box(seekForwardCompactKey, 48),
        child: box(seekForwardKey, 80),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.end,
        priority: 70,
        menuAction: action('volume'),
        onFolded: () => folded.add('volume'),
        child: box(volumeKey, 48),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.end,
        priority: 20,
        menuAction: action('plus'),
        onFolded: () => folded.add('plus'),
        child: box(plusKey, 48, focusNode: plusFocus),
      ),
    ];
    // 原样 414，紧凑 350。

    Future<void> pumpBar(
      WidgetTester tester,
      double width, {
      bool fill = true,
    }) async {
      selected = <String>[];
      folded = <String>[];
      plusFocus = FocusNode(debugLabel: 'plus');
      addTearDown(plusFocus.dispose);
      tester.view.physicalSize = const Size(1200, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              // fill: false 要的是宽松宽度约束（顶栏里 VideoTopBarSlots 给的就是 loose）。
              child: ConstrainedBox(
                constraints: fill
                    ? BoxConstraints.tightFor(width: width, height: 48)
                    : BoxConstraints(maxWidth: width, maxHeight: 48),
                child: VideoControlBar(
                  fill: fill,
                  moreButtonBuilder: (VoidCallback open) => GestureDetector(
                    onTap: open,
                    child: const ColoredBox(
                      key: moreKey,
                      color: Color(0xFF000000),
                      child: SizedBox(width: 48, height: 40),
                    ),
                  ),
                  entries: bottomEntries(),
                ),
              ),
            ),
          ),
        ),
      );
      // 焦点资格在布局得出结论后的帧尾同步，再泵一帧让它生效。
      await tester.pump();
    }

    bool visible(Key key) =>
        find.byKey(key).hitTestable().evaluate().isNotEmpty;

    void expectNoOverlapAndFullSize(WidgetTester tester, List<Key> keys) {
      final List<Rect> rects = <Rect>[
        for (final Key key in keys) tester.getRect(find.byKey(key)),
      ]..sort((Rect a, Rect b) => a.left.compareTo(b.left));
      for (int i = 0; i + 1 < rects.length; i++) {
        expect(rects[i].right, lessThanOrEqualTo(rects[i + 1].left + 0.01));
      }
      for (final Rect r in rects) {
        // 旧实现在这里是 FittedBox 缩小后的四成宽；按钮现在永远原尺寸。
        expect(r.height, 40);
      }
    }

    testWidgets('宽：全部原样，播放钉在几何正中，没有「⋯」', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      expect(visible(seekBackKey), isTrue);
      expect(visible(seekBackCompactKey), isFalse);
      expect(visible(moreKey), isFalse);
      expect(
        tester.getRect(find.byKey(playKey)).center.dx,
        moreOrLessEquals(500),
      );
      expect(tester.getRect(find.byKey(plusKey)).right, moreOrLessEquals(1000));
    });

    testWidgets('原样放不下：±10s 退成纯图标，一个都不收', (WidgetTester tester) async {
      await pumpBar(tester, 400);
      expect(visible(seekBackKey), isFalse);
      expect(visible(seekBackCompactKey), isTrue);
      expect(visible(seekForwardCompactKey), isTrue);
      expect(visible(plusKey), isTrue);
      expect(visible(moreKey), isFalse);
      expect(tester.getSize(find.byKey(seekBackCompactKey)).width, 48);
      expectNoOverlapAndFullSize(tester, <Key>[
        timeKey,
        seekBackCompactKey,
        playKey,
        seekForwardCompactKey,
        volumeKey,
        plusKey,
      ]);
    });

    testWidgets('再窄：低优先级的收进「⋯」，剩下的原尺寸不重叠', (WidgetTester tester) async {
      // 紧凑 350；收掉加号 302 + ⋯48 = 350 > 340 → 再收音量 254 + 48 = 302 ≤ 340。
      await pumpBar(tester, 340);
      expect(visible(plusKey), isFalse);
      expect(visible(volumeKey), isFalse);
      expect(visible(moreKey), isTrue);
      expect(visible(playKey), isTrue);
      expectNoOverlapAndFullSize(tester, <Key>[
        timeKey,
        seekBackCompactKey,
        playKey,
        seekForwardCompactKey,
        moreKey,
      ]);
      expect(tester.getRect(find.byKey(moreKey)).right, moreOrLessEquals(340));
    });

    testWidgets('被收起的按钮退出焦点遍历，放得下时回来', (WidgetTester tester) async {
      await pumpBar(tester, 340);
      expect(plusFocus.canRequestFocus, isFalse);
      await pumpBar(tester, 1000);
      expect(plusFocus.canRequestFocus, isTrue);
    });

    testWidgets('「⋯」按栏内顺序列出被收起的按钮，选中即执行', (WidgetTester tester) async {
      await pumpBar(tester, 340);
      await tester.tap(find.byKey(moreKey));
      await tester.pumpAndSettle();
      final Finder volumeItem = find.text('volume');
      final Finder plusItem = find.text('plus');
      expect(volumeItem, findsOneWidget);
      expect(plusItem, findsOneWidget);
      expect(find.text('−10s'), findsNothing);
      expect(
        tester.getRect(volumeItem).top,
        lessThan(tester.getRect(plusItem).top),
      );
      await tester.tap(plusItem);
      await tester.pumpAndSettle();
      expect(selected, <String>['plus']);
    });

    testWidgets('fill: false（顶栏按钮组）宽度收缩到实际显示的内容', (WidgetTester tester) async {
      await pumpBar(tester, 1000, fill: false);
      expect(
        tester.getSize(find.byType(VideoControlBar)).width,
        moreOrLessEquals(414),
      );
    });

    testWidgets('最小固有宽 = 钉死项 + 「⋯」（全部收起后的样子），最大 = 原样', (
      WidgetTester tester,
    ) async {
      // 外层顶栏按最小固有宽给每组保底；漏算「⋯」就会把别的组挤成半个「⋯」。
      await pumpBar(tester, 1000, fill: false);
      final RenderBox bar = tester.renderObject(find.byType(VideoControlBar));
      // 时间 110 + 播放 48 + ⋯ 48。
      expect(bar.getMinIntrinsicWidth(48), moreOrLessEquals(206));
      expect(bar.getMaxIntrinsicWidth(48), moreOrLessEquals(414));
    });

    testWidgets('onFolded 只对刚被收起的条目调一次', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      expect(folded, isEmpty);
      await pumpBar(tester, 340);
      expect(folded.toSet(), <String>{'volume', 'plus'});
      expect(folded, hasLength(2));
      // 结论不变时不重复通知。
      await tester.pump();
      expect(folded, hasLength(2));
    });
  });
}
