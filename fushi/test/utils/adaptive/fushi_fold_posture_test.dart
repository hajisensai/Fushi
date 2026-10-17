import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/fushi_fold_posture.dart';
import 'package:fushi/src/utils/adaptive/fushi_tabletop_split.dart';

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

  group('resolveFushiTabletopSplit', () {
    const FushiFoldState tabletop = FushiFoldState(
      posture: FushiFoldPosture.tabletop,
      hinge: Rect.fromLTWH(0, 300, 800, 20),
    );

    test('按区域原点把窗口坐标换算成本地切分', () {
      final FushiTabletopSplitGeometry? g = resolveFushiTabletopSplit(
        fold: tabletop,
        origin: const Offset(0, 40),
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
          origin: Offset.zero,
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
          origin: Offset.zero,
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
