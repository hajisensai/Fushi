import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/utils.dart';

/// TODO-947：
/// 1. 根因 Bug——重排页（[ShelfReorderPage]）左上角退出按钮「未响应」：旧实现
///    `PopScope(canPop:false)` + `_finish()` 永远 `maybePop()` 形成无限递归，
///    返回键/勾选都退不出。本测试 pump 真页，点左上角返回，断言路由真的弹出。
/// 2. 交互重构——删掉书架/视频页头那个独立「编辑排序」(swap_vert) 按钮，改在标签栏
///    「多选模式」按钮旁挂一个「整理（拖动 + 合集）」入口。用源码守卫锁定。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
    '重排页左上角返回按钮真的弹出页面（不再 PopScope 无限递归卡死）',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);

      bool persisted = false;

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => ShelfReorderPage(
                            title: 'Edit order',
                            cellExtent: 180,
                            initialItems: const <ShelfReorderItem>[
                              ShelfReorderItem(
                                mediaType: 'epub',
                                entryKey: 'a',
                                card: SizedBox(width: 80, height: 120),
                              ),
                              ShelfReorderItem(
                                mediaType: 'epub',
                                entryKey: 'b',
                                card: SizedBox(width: 80, height: 120),
                              ),
                            ],
                            onPersist: (_) async {
                              persisted = true;
                            },
                          ),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ShelfReorderPage), findsOneWidget);

      // 点左上角返回（AppBar leading BackButton）。旧实现这里会陷入
      // maybePop → PopScope(canPop:false) → _finish → maybePop 死循环，页面退不出。
      final Finder back = find.byType(BackButton);
      expect(back, findsOneWidget, reason: 'AppBar 应有左上角返回按钮');
      await tester.tap(back);
      await tester.pumpAndSettle();

      expect(find.byType(ShelfReorderPage), findsNothing,
          reason: '左上角返回必须真退出重排页（不再卡死）');
      expect(persisted, isFalse, reason: '未拖动则不落盘');
    },
  );

  testWidgets('重排页勾选「完成」按钮也能退出（同根因覆盖）', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);

    bool persisted = false;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => ShelfReorderPage(
                          title: 'Edit order',
                          cellExtent: 180,
                          initialItems: const <ShelfReorderItem>[
                            ShelfReorderItem(
                              mediaType: 'epub',
                              entryKey: 'a',
                              card: SizedBox(width: 80, height: 120),
                            ),
                          ],
                          onPersist: (_) async {
                            persisted = true;
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ShelfReorderPage), findsOneWidget);

    // 勾选「完成」（AppBar action 的 check 图标）必须真退出。
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    expect(find.byType(ShelfReorderPage), findsNothing,
        reason: '「完成」也必须真退出重排页');
    expect(persisted, isFalse, reason: '未拖动则不落盘');
  });

  test('书架页头删掉独立「编辑排序」(swap_vert) 入口，整理入口移到标签栏', () {
    final String shelf =
        _read('lib/src/pages/implementations/reader_hibiki_history_page.dart');
    expect(
      RegExp(r'icon:\s*Icons\.swap_vert').hasMatch(shelf),
      isFalse,
      reason: '书架页头不再放独立「编辑排序」按钮',
    );
    expect(shelf.contains('onOrganize: _openShelfSort'), isTrue,
        reason: '整理（拖动）入口移到标签栏多选按钮旁');
    // 「组合成系列」批量入口在 part 文件 books.part.dart 的 _buildBatchActionBar 里，
    // 与整理入口（标签栏多选按钮旁）相邻可达，保留不动。
    final String books =
        _read('lib/src/pages/implementations/reader_history/books.part.dart');
    expect(books.contains('_batchCombineIntoSeries'), isTrue,
        reason: '组合成系列入口保留（多选合集与整理相邻）');
  });

  test('视频页头也删掉独立「编辑排序」(swap_vert) 入口，整理入口移到标签栏', () {
    final String video =
        _read('lib/src/pages/implementations/home_video_page.dart');
    expect(
      RegExp(r'icon:\s*Icons\.swap_vert').hasMatch(video),
      isFalse,
      reason: '视频页头不再放独立「编辑排序」按钮',
    );
    expect(video.contains('onOrganize: _openVideoSort'), isTrue,
        reason: '视频整理（拖动）入口移到标签栏多选按钮旁');
  });

  test('共享标签栏新增 onOrganize 入口（多选按钮旁的「整理」按钮）', () {
    final String bar =
        _read('lib/src/pages/implementations/tag_filter_bar.dart');
    expect(bar.contains('onOrganize'), isTrue,
        reason: '标签栏要暴露 onOrganize 回调（整理：拖动 + 合集）');
    expect(bar.contains('Icons.swap_vert'), isTrue,
        reason: '整理按钮用 swap_vert 图标，挂在多选按钮旁');
  });

  // -- TODO-947-2 PR2: shelf reorder page drag-merge wiring --------------
  group('ShelfReorderPage drag-merge (PR2)', () {
    testWidgets(
        'scatter A dropped on scatter B center -> onMerge(A,B), no reorder',
        (WidgetTester tester) async {
      final List<List<ShelfReorderItem>> merges = <List<ShelfReorderItem>>[];
      await _pumpReorder(
        tester,
        items: const <ShelfReorderItem>[
          ShelfReorderItem(
              mediaType: 'epub', entryKey: 'A', card: _LabelCard('A')),
          ShelfReorderItem(
              mediaType: 'epub', entryKey: 'B', card: _LabelCard('B')),
        ],
        onMerge: (ShelfReorderItem dragged, ShelfReorderItem target) async {
          merges.add(<ShelfReorderItem>[dragged, target]);
          return 7;
        },
      );
      await _dragCardTo(tester, 'A', 'B');
      expect(merges.length, 1);
      expect(merges.single[0].entryKey, 'A');
      expect(merges.single[1].entryKey, 'B');
    });

    testWidgets(
        'scatter A dropped on series card S center -> onMerge carries S.seriesId',
        (WidgetTester tester) async {
      final List<List<ShelfReorderItem>> merges = <List<ShelfReorderItem>>[];
      await _pumpReorder(
        tester,
        items: const <ShelfReorderItem>[
          ShelfReorderItem(
              mediaType: 'epub', entryKey: 'A', card: _LabelCard('A')),
          ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'S',
              seriesId: 42,
              card: _LabelCard('S')),
        ],
        onMerge: (ShelfReorderItem dragged, ShelfReorderItem target) async {
          merges.add(<ShelfReorderItem>[dragged, target]);
          return target.seriesId;
        },
      );
      await _dragCardTo(tester, 'A', 'S');
      expect(merges.length, 1);
      expect(merges.single[0].entryKey, 'A');
      expect(merges.single[1].entryKey, 'S');
      expect(merges.single[1].seriesId, 42);
    });

    testWidgets(
        'A already in same series as S -> canMergeInto=false, falls back to reorder',
        (WidgetTester tester) async {
      final List<List<ShelfReorderItem>> merges = <List<ShelfReorderItem>>[];
      bool persisted = false;
      await _pumpReorder(
        tester,
        items: const <ShelfReorderItem>[
          ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'A',
              seriesId: 9,
              card: _LabelCard('A')),
          ShelfReorderItem(
              mediaType: 'epub',
              entryKey: 'S',
              seriesId: 9,
              card: _LabelCard('S')),
        ],
        onMerge: (ShelfReorderItem dragged, ShelfReorderItem target) async {
          merges.add(<ShelfReorderItem>[dragged, target]);
          return target.seriesId;
        },
        onPersist: (_) async {
          persisted = true;
        },
      );
      await _dragCardTo(tester, 'A', 'S');
      expect(merges, isEmpty, reason: 'same-series drop does not merge');
      // Exit via the check action; same-series drop fell back to reorder ->
      // dirty -> persists on exit.
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(persisted, isTrue,
          reason: 'same-series drop degraded to reorder -> persisted on exit');
    });

    testWidgets(
        'no onMerge -> dropping on target center degrades to pure reorder (regression guard)',
        (WidgetTester tester) async {
      bool persisted = false;
      await _pumpReorder(
        tester,
        items: const <ShelfReorderItem>[
          ShelfReorderItem(
              mediaType: 'epub', entryKey: 'A', card: _LabelCard('A')),
          ShelfReorderItem(
              mediaType: 'epub', entryKey: 'B', card: _LabelCard('B')),
        ],
        onMerge: null,
        onPersist: (_) async {
          persisted = true;
        },
      );
      await _dragCardTo(tester, 'A', 'B');
      // No onMerge -> grid never receives merge callbacks -> drop on B center is
      // a pure reorder of A into B's slot. Exit to flush persist.
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(persisted, isTrue, reason: 'pure reorder A->B persisted on exit');
    });
  });
}

/// Simple labelled card (fixed center text, find.text-friendly).
class _LabelCard extends StatelessWidget {
  const _LabelCard(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Center(child: Text(label));
}

/// Pump a real [ShelfReorderPage] with deterministic geometry (cellExtent 200 +
/// aspect 1 -> 3 cols of 200x200 in a 700-wide viewport). Wrapped in a Navigator
/// so the page's PopScope/exit-persist path runs for real.
Future<void> _pumpReorder(
  WidgetTester tester, {
  required List<ShelfReorderItem> items,
  required ShelfReorderMerge? onMerge,
  Future<void> Function(List<ShelfReorderItem>)? onPersist,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(700, 700);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ShelfReorderPage(
              title: 'Edit order',
              cellExtent: 200,
              childAspectRatio: 1,
              initialItems: items,
              onMerge: onMerge,
              onPersist: onPersist ?? (_) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Mouse immediate-drag card [from] onto the center of card [target] (lands in
/// target cell center mergeRadius zone). Two-step moveTo to mimic real movement.
Future<void> _dragCardTo(
  WidgetTester tester,
  String from,
  String target,
) async {
  final Offset start = tester.getCenter(find.text(from));
  final Offset end = tester.getCenter(find.text(target));
  final TestGesture gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(Offset.lerp(start, end, 0.5)!);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}
