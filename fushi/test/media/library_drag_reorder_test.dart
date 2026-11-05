import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/collections/collection_drag.dart';

/// 桌面库页「直拖重排 + 拖进合集」共享件（[LibraryDragReorderScope] +
/// [LibraryReorderCell]）的行为契约。
///
/// 网格：3 列 × 2 行、间距 20，下标 2 是合集卡（[CollectionDropTarget]），其余是
/// 散卡（[MediaCardDraggable]）。用鼠标指针拖，验证：
/// - 拖到卡上 → 按指针落在目标卡哪一半插前 / 插后，回调 `onReorder(from, to)`；
/// - 拖到卡与卡之间的缝 → 按最后的插入指示提交；
/// - 拖到合集卡正中 → 加入合集、不重排；合集卡边缘 → 仍是重排；
/// - 合集卡本身也能拖动重排；
/// - enabled=false（多选 / 筛选）→ 不重排，整张合集卡仍是「加入合集」；
/// - 触屏平台不建拖拽源。
void main() {
  const int collectionIndex = 2;
  const int itemCount = 6;

  MediaRef refOf(int i) => MediaRef(kind: MediaKind.epub, entryKey: 'book-$i');

  final List<(int, int)> reorders = <(int, int)>[];
  final List<MediaRef> intoCollection = <MediaRef>[];

  setUp(() {
    reorders.clear();
    intoCollection.clear();
  });

  Widget card(int i) => SizedBox.expand(
    child: ColoredBox(
      key: ValueKey<String>('card_$i'),
      color: Color(0xFF203040 + i * 0x101010),
    ),
  );

  Future<void> pumpGrid(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.windows,
    bool enabled = true,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              LibraryDragReorderScope(
                enabled: enabled,
                onReorder: (int from, int to) => reorders.add((from, to)),
                child: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 20,
                    childAspectRatio: 1.4,
                  ),
                  itemCount: itemCount,
                  itemBuilder: (BuildContext context, int i) =>
                      LibraryReorderCell(
                        index: i,
                        child: i == collectionIndex
                            ? CollectionDropTarget(
                                onMediaDropped: intoCollection.add,
                                child: card(i),
                              )
                            : MediaCardDraggable(
                                mediaRef: refOf(i),
                                label: 'Book $i',
                                child: card(i),
                              ),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect rectOf(WidgetTester tester, int i) =>
      tester.getRect(find.byKey(ValueKey<String>('card_$i')));

  /// 从卡 [from] 中心按下，用鼠标拖到 [target]，[beforeUp] 在松手前检查中间态。
  Future<void> mouseDrag(
    WidgetTester tester,
    int from,
    Offset target, {
    List<Offset> via = const <Offset>[],
    Future<void> Function()? beforeUp,
  }) async {
    final TestGesture gesture = await tester.startGesture(
      rectOf(tester, from).center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    for (final Offset p in via) {
      await gesture.moveTo(p);
      await tester.pump();
    }
    await gesture.moveTo(target);
    await tester.pump();
    // 再挪一像素：指示的判定跟着拖拽源的 onDragUpdate 走。
    await gesture.moveBy(const Offset(1, 0));
    await tester.pump();
    if (beforeUp != null) await beforeUp();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Offset at(Rect r, double fx, double fy) =>
      Offset(r.left + r.width * fx, r.top + r.height * fy);

  testWidgets('拖到目标卡右半 = 插到它后面', (WidgetTester tester) async {
    await pumpGrid(tester);
    final Rect target = rectOf(tester, 4);
    await mouseDrag(
      tester,
      0,
      at(target, 0.8, 0.5),
      beforeUp: () async {
        expect(
          find.byKey(const ValueKey<String>('library_reorder_insertion_after')),
          findsOneWidget,
          reason: '目标卡尾边要画插入竖条',
        );
      },
    );
    expect(reorders, <(int, int)>[(0, 4)]);
    expect(intoCollection, isEmpty);
  });

  testWidgets('拖到目标卡左半 = 插到它前面', (WidgetTester tester) async {
    await pumpGrid(tester);
    await mouseDrag(tester, 5, at(rectOf(tester, 3), 0.2, 0.5));
    expect(reorders, <(int, int)>[(5, 3)]);
  });

  testWidgets('松手在卡与卡之间的缝里：按最后的插入指示重排', (WidgetTester tester) async {
    await pumpGrid(tester);
    final Rect r0 = rectOf(tester, 0);
    final Rect r1 = rectOf(tester, 1);
    final Offset gap = Offset((r0.right + r1.left) / 2, r1.center.dy);
    await mouseDrag(tester, 5, gap, via: <Offset>[at(r1, 0.2, 0.5)]);
    expect(reorders, <(int, int)>[(5, 1)]);
  });

  testWidgets('离开格子太远松手不重排', (WidgetTester tester) async {
    await pumpGrid(tester);
    await mouseDrag(
      tester,
      0,
      const Offset(400, 590),
      via: <Offset>[at(rectOf(tester, 4), 0.8, 0.5)],
    );
    expect(reorders, isEmpty);
  });

  testWidgets('拖到合集卡正中 = 加入合集（高亮），不重排', (WidgetTester tester) async {
    await pumpGrid(tester);
    await mouseDrag(
      tester,
      0,
      rectOf(tester, collectionIndex).center,
      beforeUp: () async {
        expect(
          find.byKey(const ValueKey<String>('collection_drop_highlight')),
          findsOneWidget,
          reason: '合集卡要给出「放进合集」高亮',
        );
        expect(
          find.byKey(const ValueKey<String>('library_reorder_insertion_after')),
          findsNothing,
        );
        expect(
          find.byKey(
            const ValueKey<String>('library_reorder_insertion_before'),
          ),
          findsNothing,
        );
      },
    );
    expect(intoCollection, <MediaRef>[refOf(0)]);
    expect(reorders, isEmpty);
  });

  testWidgets('拖到合集卡边缘 = 插到合集卡前后，不加入合集', (WidgetTester tester) async {
    await pumpGrid(tester);
    await mouseDrag(
      tester,
      0,
      at(rectOf(tester, collectionIndex), 0.1, 0.5),
      beforeUp: () async {
        expect(
          find.byKey(const ValueKey<String>('collection_drop_highlight')),
          findsNothing,
        );
      },
    );
    expect(reorders, <(int, int)>[(0, 1)]);
    expect(intoCollection, isEmpty);
  });

  testWidgets('合集卡本身也能拖动重排（拖到合集卡上不会「放进自己」）', (WidgetTester tester) async {
    await pumpGrid(tester);
    await mouseDrag(tester, collectionIndex, at(rectOf(tester, 5), 0.8, 0.5));
    expect(reorders, <(int, int)>[(collectionIndex, 5)]);
    expect(intoCollection, isEmpty);
  });

  testWidgets('enabled=false：不重排，整张合集卡仍可拖进合集', (WidgetTester tester) async {
    await pumpGrid(tester, enabled: false);
    await mouseDrag(tester, 0, at(rectOf(tester, 4), 0.8, 0.5));
    expect(reorders, isEmpty);

    // 关掉重排后合集卡回到「整块都是加入合集」：贴着边缘落下也加入。
    await mouseDrag(tester, 1, at(rectOf(tester, collectionIndex), 0.1, 0.5));
    expect(intoCollection, <MediaRef>[refOf(1)]);
    expect(reorders, isEmpty);
  });

  testWidgets('触屏平台不建拖拽源（重排走长按菜单 → 排序模式）', (WidgetTester tester) async {
    await pumpGrid(tester, platform: TargetPlatform.android);
    expect(find.byType(Draggable<LibraryCardDrag>), findsNothing);
  });

  test('targetIndex：插前 / 插后换算成 removeAt+insert 的最终下标', () {
    expect(
      LibraryDragReorderScope.targetIndex(from: 0, target: 4, after: true),
      4,
    );
    expect(
      LibraryDragReorderScope.targetIndex(from: 0, target: 4, after: false),
      3,
    );
    expect(
      LibraryDragReorderScope.targetIndex(from: 5, target: 1, after: false),
      1,
    );
    expect(
      LibraryDragReorderScope.targetIndex(from: 5, target: 1, after: true),
      2,
    );
    // 落在自己两侧 = 原地。
    expect(
      LibraryDragReorderScope.targetIndex(from: 3, target: 3, after: true),
      3,
    );
    expect(
      LibraryDragReorderScope.targetIndex(from: 3, target: 4, after: false),
      3,
    );
  });
}
