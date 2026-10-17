// FushiAdaptiveActionStrip：工具栏动作「默认展开、空间不足才收进 ⋯」（用户 2026-10-06）。
// 网页播放器顶栏 / 字幕列表页头 / 合集详情 / 设置页页头共用这一份。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_adaptive_action_strip.dart';
import 'package:material_ui/material_ui.dart';

const Key _moreKey = ValueKey<String>('strip-more');

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: AlignmentDirectional.topStart, child: child),
  ),
);

List<FushiAdaptiveAction> _actions(int n, List<String> taps) =>
    <FushiAdaptiveAction>[
      for (int i = 0; i < n; i++)
        FushiAdaptiveAction(
          key: ValueKey<String>('a$i'),
          foldedKey: ValueKey<String>('f$i'),
          icon: Icons.star,
          label: 'L$i',
          onPressed: () => taps.add('a$i'),
        ),
    ];

Finder _inline(int i) => find.byKey(ValueKey<String>('a$i'));

void main() {
  testWidgets('宽度够：全部平铺，没有「⋯」，命中区不小于 48', (WidgetTester tester) async {
    final List<String> taps = <String>[];
    await tester.pumpWidget(
      _host(
        FushiAdaptiveActionStrip(
          maxWidth: 600,
          moreKey: _moreKey,
          actions: _actions(6, taps),
        ),
      ),
    );
    for (int i = 0; i < 6; i++) {
      expect(_inline(i), findsOneWidget);
    }
    expect(find.byKey(_moreKey), findsNothing);
    expect(tester.getSize(_inline(0)).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(_inline(5));
    expect(taps, <String>['a5']);
  });

  testWidgets('宽度不够：从最低优先级（末尾）起收进「⋯」，高优先级仍平铺', (WidgetTester tester) async {
    final List<String> taps = <String>[];
    await tester.pumpWidget(
      _host(
        FushiAdaptiveActionStrip(
          maxWidth: 160,
          moreKey: _moreKey,
          actions: _actions(5, taps),
        ),
      ),
    );
    expect(_inline(0), findsOneWidget);
    expect(_inline(4), findsNothing);
    expect(find.byKey(_moreKey), findsOneWidget);
    await tester.tap(find.byKey(_moreKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('f4')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('f4')));
    await tester.pumpAndSettle();
    expect(taps, <String>['a4'], reason: '菜单项执行的是同一个回调');
  });

  testWidgets('foldFromStart：列表末尾优先级最高，先收最左的，「⋯」排在最前', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FushiAdaptiveActionStrip(
          maxWidth: 160,
          moreKey: _moreKey,
          foldFromStart: true,
          actions: _actions(5, <String>[]),
        ),
      ),
    );
    expect(_inline(4), findsOneWidget, reason: '最右（最常用）的最后收');
    expect(_inline(0), findsNothing);
    expect(
      tester.getRect(find.byKey(_moreKey)).right,
      lessThanOrEqualTo(tester.getRect(_inline(4)).left),
      reason: '「⋯」在平铺钮左边',
    );
  });

  testWidgets('inlineSlots：占多个槽位的动作按槽位数测宽，不低估', (WidgetTester tester) async {
    Widget build(double width) => _host(
      FushiAdaptiveActionStrip(
        maxWidth: width,
        moreKey: _moreKey,
        actions: <FushiAdaptiveAction>[
          const FushiAdaptiveAction(
            key: ValueKey<String>('a0'),
            icon: Icons.star,
            label: 'one',
            onPressed: null,
          ),
          FushiAdaptiveAction(
            key: const ValueKey<String>('wide'),
            icon: Icons.add,
            label: 'stepper',
            onPressed: null,
            inlineSlots: 3,
            inlineBuilder: (BuildContext _) =>
                const SizedBox(key: ValueKey<String>('stepper'), width: 136),
          ),
        ],
      ),
    );
    // 1 + 3 个槽位 = 8 + 4 * 52 = 216。
    await tester.pumpWidget(build(216));
    expect(find.byKey(const ValueKey<String>('stepper')), findsOneWidget);
    expect(find.byKey(_moreKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(build(180));
    expect(find.byKey(const ValueKey<String>('stepper')), findsNothing);
    expect(find.byKey(_moreKey), findsOneWidget);
  });

  testWidgets('foldedEntries 自定义收起后的菜单条目；禁用动作的菜单项也禁用', (
    WidgetTester tester,
  ) async {
    final List<String> picked = <String>[];
    await tester.pumpWidget(
      _host(
        FushiAdaptiveActionStrip(
          maxWidth: 0,
          moreKey: _moreKey,
          actions: <FushiAdaptiveAction>[
            FushiAdaptiveAction(
              icon: Icons.star,
              label: 'menu',
              onPressed: null,
              foldedEntries: (BuildContext _) => <PopupMenuEntry<VoidCallback>>[
                PopupMenuItem<VoidCallback>(
                  value: () => picked.add('x'),
                  child: const Text('custom-x'),
                ),
              ],
            ),
            const FushiAdaptiveAction(
              foldedKey: ValueKey<String>('off'),
              icon: Icons.delete,
              label: 'disabled',
              onPressed: null,
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byKey(_moreKey));
    await tester.pumpAndSettle();
    expect(find.text('custom-x'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<VoidCallback>>(
            find.byKey(const ValueKey<String>('off')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('custom-x'));
    await tester.pumpAndSettle();
    expect(picked, <String>['x']);
  });

  testWidgets('不用 LayoutBuilder：放进 IntrinsicWidth 也不炸（设置页页头会取固有宽度）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        IntrinsicWidth(
          child: FushiAdaptiveActionStrip(
            maxWidth: 600,
            actions: _actions(3, <String>[]),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_inline(2), findsOneWidget);
  });

  test('网页播放器顶栏两种风格都走自适应动作条，不再固定横排全部动作（源码守卫）', () {
    final String source = File(
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ).readAsStringSync();
    expect(source, contains('FushiAdaptiveActionStrip'));
    expect(source, contains('_webBarActions(m3e: true)'));
    expect(source, contains('_webBarActions(m3e: false)'));
    expect(source, isNot(contains('_m3eTopBarActions')));
  });
}
