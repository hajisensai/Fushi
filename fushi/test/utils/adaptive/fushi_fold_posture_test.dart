import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/fushi_fold_posture.dart';
import 'package:fushi/src/utils/adaptive/fushi_tabletop_split.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

const Size _window = Size(800, 600);

DisplayFeature _fold(Rect bounds, DisplayFeatureState state) =>
    DisplayFeature(bounds: bounds, type: DisplayFeatureType.fold, state: state);

void main() {
  group('resolveFushiFoldState', () {
    test('无折痕 / 只有挖孔 → flat', () {
      expect(
        resolveFushiFoldState(
          displayFeatures: const <DisplayFeature>[],
          windowSize: _window,
        ).posture,
        FushiFoldPosture.flat,
      );
      expect(
        resolveFushiFoldState(
          displayFeatures: const <DisplayFeature>[
            DisplayFeature(
              bounds: Rect.fromLTWH(380, 0, 40, 30),
              type: DisplayFeatureType.cutout,
              state: DisplayFeatureState.unknown,
            ),
          ],
          windowSize: _window,
        ).posture,
        FushiFoldPosture.flat,
      );
    });

    test('柔性折痕完全展开不分隔内容 → flat（大屏折叠屏展平时按平板排）', () {
      final FushiFoldState s = resolveFushiFoldState(
        displayFeatures: <DisplayFeature>[
          _fold(
            const Rect.fromLTWH(400, 0, 0, 600),
            DisplayFeatureState.postureFlat,
          ),
        ],
        windowSize: _window,
      );
      expect(s.posture, FushiFoldPosture.flat);
      expect(s.hinge, isNull);
    });

    test('竖向折痕半开 → book，带折痕矩形', () {
      const Rect bounds = Rect.fromLTWH(400, 0, 0, 600);
      final FushiFoldState s = resolveFushiFoldState(
        displayFeatures: <DisplayFeature>[
          _fold(bounds, DisplayFeatureState.postureHalfOpened),
        ],
        windowSize: _window,
      );
      expect(s.posture, FushiFoldPosture.book);
      expect(s.hinge, bounds);
    });

    test('横向折痕半开 → tabletop', () {
      final FushiFoldState s = resolveFushiFoldState(
        displayFeatures: <DisplayFeature>[
          _fold(
            const Rect.fromLTWH(0, 300, 800, 0),
            DisplayFeatureState.postureHalfOpened,
          ),
        ],
        windowSize: _window,
      );
      expect(s.posture, FushiFoldPosture.tabletop);
    });

    test('物理铰链（双屏设备）即使平放也分隔内容', () {
      final FushiFoldState s = resolveFushiFoldState(
        displayFeatures: const <DisplayFeature>[
          DisplayFeature(
            bounds: Rect.fromLTWH(388, 0, 24, 600),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
        windowSize: _window,
      );
      expect(s.posture, FushiFoldPosture.book);
    });

    test('折痕没有横贯窗口（分屏 / 自由窗口只碰到一段）→ flat', () {
      final FushiFoldState s = resolveFushiFoldState(
        displayFeatures: <DisplayFeature>[
          _fold(
            const Rect.fromLTWH(400, 200, 0, 400),
            DisplayFeatureState.postureHalfOpened,
          ),
        ],
        windowSize: _window,
      );
      expect(s.posture, FushiFoldPosture.flat);
    });

    testWidgets('FushiFoldState.of 读 MediaQuery.displayFeatures', (
      WidgetTester tester,
    ) async {
      FushiFoldState? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: _window,
            displayFeatures: <DisplayFeature>[
              _fold(
                const Rect.fromLTWH(400, 0, 0, 600),
                DisplayFeatureState.postureHalfOpened,
              ),
            ],
          ),
          child: Builder(
            builder: (BuildContext context) {
              seen = FushiFoldState.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen?.isBook, isTrue);
    });
  });

  group('fushiHingeGutterPx', () {
    test('非书本姿态 0；柔性折痕居中也是 0', () {
      expect(
        fushiHingeGutterPx(fold: FushiFoldState.flat, contentCenterX: 400),
        0,
      );
      expect(
        fushiHingeGutterPx(
          fold: const FushiFoldState(
            posture: FushiFoldPosture.book,
            hinge: Rect.fromLTWH(400, 0, 0, 600),
          ),
          contentCenterX: 400,
        ),
        0,
      );
    });

    test('物理铰链：缝 = 铰链宽 + 2×中线偏差，整条铰链都落在缝里', () {
      const FushiFoldState duo = FushiFoldState(
        posture: FushiFoldPosture.book,
        hinge: Rect.fromLTWH(388, 0, 24, 600),
      );
      expect(fushiHingeGutterPx(fold: duo, contentCenterX: 400), 24);
      final double gutter = fushiHingeGutterPx(fold: duo, contentCenterX: 390);
      expect(gutter, 44);
      // 以内容中线 390 对称展开的缝 [368, 412] 必须盖住铰链 [388, 412]。
      expect(390 - gutter / 2 <= 388 && 390 + gutter / 2 >= 412, isTrue);
    });
  });

  group('resolveFushiTabletopSplit', () {
    const FushiFoldState tabletop = FushiFoldState(
      posture: FushiFoldPosture.tabletop,
      hinge: Rect.fromLTWH(0, 300, 800, 20),
    );

    test('按本地折痕切分', () {
      final FushiTabletopSplitGeometry? g = resolveFushiTabletopSplit(
        fold: tabletop,
        localHinge: const Rect.fromLTWH(0, 260, 800, 20),
        size: const Size(800, 560),
      );
      expect(g, isNotNull);
      expect(g!.topHeight, 260);
      expect(g.hingeHeight, 20);
    });

    test('非桌面姿态 / 任一块太矮 → 不切分', () {
      expect(
        resolveFushiTabletopSplit(
          fold: FushiFoldState.flat,
          localHinge: const Rect.fromLTWH(0, 300, 800, 0),
          size: _window,
        ),
        isNull,
      );
      expect(
        resolveFushiTabletopSplit(
          fold: const FushiFoldState(
            posture: FushiFoldPosture.tabletop,
            hinge: Rect.fromLTWH(0, 540, 800, 0),
          ),
          localHinge: const Rect.fromLTWH(0, 540, 800, 0),
          size: _window,
        ),
        isNull,
        reason: '下半块只剩 60px，放不下控件',
      );
    });
  });

  group('FushiTabletopSplit', () {
    Widget host(List<DisplayFeature> features, Widget top) => MediaQuery(
      data: MediaQueryData(size: _window, displayFeatures: features),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: FushiTabletopSplit(
          top: top,
          bottomBuilder: (BuildContext _) =>
              const SizedBox.expand(key: ValueKey<String>('bottom')),
        ),
      ),
    );

    testWidgets('桌面姿态下切成上下两块，姿态切换不重建 top 的状态', (WidgetTester tester) async {
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const Widget top = _Counter(key: ValueKey<String>('top'));

      await tester.pumpWidget(host(const <DisplayFeature>[], top));
      expect(find.byKey(const ValueKey<String>('bottom')), findsNothing);
      final _CounterState state = tester.state<_CounterState>(
        find.byType(_Counter),
      );
      state.bump();

      await tester.pumpWidget(
        host(<DisplayFeature>[
          _fold(
            const Rect.fromLTWH(0, 300, 800, 0),
            DisplayFeatureState.postureHalfOpened,
          ),
        ], top),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('bottom')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('top'))).height,
        300,
      );
      expect(
        identical(tester.state<_CounterState>(find.byType(_Counter)), state),
        isTrue,
        reason: 'top 子树（视频 surface）随姿态切换必须原地保留',
      );
      expect(tester.state<_CounterState>(find.byType(_Counter)).count, 1);

      await tester.pumpWidget(host(const <DisplayFeature>[], top));
      expect(find.byKey(const ValueKey<String>('bottom')), findsNothing);
      expect(tester.state<_CounterState>(find.byType(_Counter)).count, 1);
    });
  });

  // 界面缩放 ≠ 1 时（FushiAppUiScale 把 MediaQuery 几何 ×1/s），折痕矩形必须与
  // MediaQuery.size 处在同一坐标空间：不靠消费页包 FushiAppUiScaleNeutralizer 才对。
  group('界面缩放下的折痕坐标', () {
    const Size physical = Size(800, 600);

    void setUpView(WidgetTester tester, List<DisplayFeature> features) {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = 1;
      tester.view.displayFeatures = features;
      addTearDown(tester.view.reset);
    }

    Widget fromView(WidgetTester tester, Widget child) => MediaQuery.fromView(
      view: tester.view,
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    );

    testWidgets('scale=2：hinge 与 MediaQuery.size 同比例换算，仍判 book', (
      WidgetTester tester,
    ) async {
      setUpView(tester, <DisplayFeature>[
        _fold(
          const Rect.fromLTWH(400, 0, 0, 600),
          DisplayFeatureState.postureHalfOpened,
        ),
      ]);
      FushiFoldState? seen;
      Size? seenSize;
      double? seenGutter;
      await tester.pumpWidget(
        fromView(
          tester,
          FushiAppUiScale(
            scale: 2,
            child: Builder(
              builder: (BuildContext context) {
                seen = FushiFoldState.of(context);
                seenSize = MediaQuery.sizeOf(context);
                seenGutter = fushiHingeGutterPx(
                  fold: seen!,
                  contentCenterX: seenSize!.width / 2,
                );
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      expect(seenSize, const Size(400, 300));
      expect(seen?.isBook, isTrue);
      expect(seen?.hinge, const Rect.fromLTWH(200, 0, 0, 300));
      expect(seenGutter, 0, reason: '折痕正在画布中线，不应多让缝');
    });

    testWidgets('scale=0.5：横向折痕仍判 tabletop（未换算时会因越界被漏判）', (
      WidgetTester tester,
    ) async {
      setUpView(tester, <DisplayFeature>[
        _fold(
          const Rect.fromLTWH(0, 300, 800, 0),
          DisplayFeatureState.postureHalfOpened,
        ),
      ]);
      FushiFoldState? seen;
      await tester.pumpWidget(
        fromView(
          tester,
          FushiAppUiScale(
            scale: 0.5,
            child: Builder(
              builder: (BuildContext context) {
                seen = FushiFoldState.of(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      expect(seen?.isTabletop, isTrue);
      expect(seen?.hinge, const Rect.fromLTWH(0, 600, 1600, 0));
    });

    testWidgets('Neutralizer 下还原成窗口坐标', (WidgetTester tester) async {
      setUpView(tester, <DisplayFeature>[
        _fold(
          const Rect.fromLTWH(400, 0, 0, 600),
          DisplayFeatureState.postureHalfOpened,
        ),
      ]);
      FushiFoldState? seen;
      await tester.pumpWidget(
        fromView(
          tester,
          FushiAppUiScale(
            scale: 1.5,
            child: FushiAppUiScaleNeutralizer(
              child: Builder(
                builder: (BuildContext context) {
                  seen = FushiFoldState.of(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      _expectRect(seen?.hinge, const Rect.fromLTWH(400, 0, 0, 600));
    });

    testWidgets('FushiTabletopSplit 在 scale=2 且带顶部偏移时按本地坐标切分', (
      WidgetTester tester,
    ) async {
      setUpView(tester, <DisplayFeature>[
        _fold(
          const Rect.fromLTWH(0, 300, 800, 0),
          DisplayFeatureState.postureHalfOpened,
        ),
      ]);
      await tester.pumpWidget(
        fromView(
          tester,
          FushiAppUiScale(
            scale: 2,
            child: Column(
              children: <Widget>[
                // 画布坐标里 20 高的横幅 = 窗口里 40px。
                const SizedBox(height: 20),
                Expanded(
                  child: FushiTabletopSplit(
                    minTopHeight: 50,
                    minBottomHeight: 50,
                    top: const SizedBox.expand(key: ValueKey<String>('top')),
                    bottomBuilder: (BuildContext _) =>
                        const SizedBox.expand(key: ValueKey<String>('bottom')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('bottom')), findsOneWidget);
      // 窗口里折痕在 y=300、区域从 y=40 开始 → 本地（画布单位）(300-40)/2 = 130。
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('top'))).height,
        130,
        reason: 'getSize 报的是本地（画布单位）尺寸',
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('bottom'))).dy,
        300,
        reason: '下半块必须从窗口里的折痕位置开始',
      );
    });
  });
}

/// 浮点换算（÷1.5 再 ×1.5）不保证逐位相等，按 1e-9 比较四边。
void _expectRect(Rect? actual, Rect expected) {
  expect(actual, isNotNull);
  expect(actual!.left, closeTo(expected.left, 1e-9));
  expect(actual.top, closeTo(expected.top, 1e-9));
  expect(actual.right, closeTo(expected.right, 1e-9));
  expect(actual.bottom, closeTo(expected.bottom, 1e-9));
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  void bump() => count++;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
