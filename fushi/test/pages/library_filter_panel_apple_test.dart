// 库页「排序与筛选」面板（视频库 / 游戏库共用的 showLibraryFilterPanel）的
// Cupertino 版（用户 2026-11-24 截图：Apple 下整面是 M3E chip + 底部孤零零一颗
// 「清除筛选」）：
// - Apple 下不画任何 M3E chip；少档位（≤ 4）单选是分段控件行，多档位与排序是
//   弹出菜单行，多选维度是对勾行；
// - iOS 档是 sheet：导航栏左「清除」、中标题、右「完成」，没有底部按钮区；
//   macOS 档是锚在页头按钮下的 popover，「清除」在标题行；
// - 没有可清除的维度时「清除」禁用；改动经 update 即时生效（页面的持久化回调
//   被调用），「清除」复位筛选维度、不动排序。
// - M3E 不变：chip + 底部「清除」。

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_filter_panel.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_sheet_header.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

enum _Watch { all, unwatched, watching, watched }

enum _Sort { recent, name, imported, manual }

/// 页面状态的替身：维度值 + 「持久化」记账（页面真实的偏好写入由各自回调负责，
/// 这里只验证面板把改动经 update 交回了页面）。
class _State {
  _Sort sort = _Sort.recent;
  int year = 0;
  _Watch watch = _Watch.all;
  Set<String> spec = <String>{};
  final List<String> persisted = <String>[];

  bool get hasFilter => year != 0 || watch != _Watch.all || spec.isNotEmpty;

  void clear() {
    year = 0;
    watch = _Watch.all;
    spec = <String>{};
    persisted.add('clear');
  }
}

ThemeData _theme({required bool glass, required TargetPlatform platform}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      glassDesign: glass,
    ).copyWith(platform: platform);

List<Widget> _sections(_State s, LibraryFilterPanelUpdate update) => <Widget>[
  LibraryFilterChoiceSection<_Sort>(
    key: const ValueKey<String>('panel_sort'),
    title: 'Sort by',
    values: _Sort.values,
    selected: s.sort,
    allValue: _Sort.recent,
    allLabel: 'Recent',
    labelOf: (_Sort v) => v.name,
    appleMenu: true,
    onSelected: (_Sort v) => update(() {
      s.sort = v;
      s.persisted.add('sort:${v.name}');
    }),
  ),
  const LibraryFilterGroupBreak(),
  LibraryFilterChoiceSection<int>(
    key: const ValueKey<String>('panel_year'),
    title: 'Year',
    values: const <int>[0, 2026, 2024, 2023, 2021, 2015, -1],
    selected: s.year,
    allValue: 0,
    allLabel: 'All',
    labelOf: (int y) => y < 0 ? 'Unknown' : '$y',
    onSelected: (int y) => update(() => s.year = y),
  ),
  LibraryFilterChoiceSection<_Watch>(
    key: const ValueKey<String>('panel_watch'),
    title: 'Watched',
    values: _Watch.values,
    selected: s.watch,
    allValue: _Watch.all,
    allLabel: 'All',
    labelOf: (_Watch v) => v.name,
    onSelected: (_Watch v) => update(() {
      s.watch = v;
      s.persisted.add('watch:${v.name}');
    }),
  ),
  LibraryFilterMultiChoiceSection<String>(
    key: const ValueKey<String>('panel_spec'),
    title: 'Spec',
    values: const <String>['bd', 'dvd', '4k'],
    selected: s.spec,
    labelOf: (String v) => v.toUpperCase(),
    onChanged: (Set<String> next) => update(() => s.spec = next),
  ),
];

Future<void> _pumpHost(
  WidgetTester tester,
  _State state, {
  required bool glass,
  required TargetPlatform platform,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: _theme(glass: glass, platform: platform),
        home: FushiGlassScope(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: Builder(
                builder: (BuildContext context) => FushiIconButton(
                  key: const ValueKey<String>('open_panel'),
                  tooltip: 'Sort and filter',
                  icon: Icons.filter_list,
                  onTap: () => showLibraryFilterPanel(
                    context: context,
                    title: 'Sort and filter',
                    clearLabel: 'Clear filters',
                    clearKey: const ValueKey<String>('panel_clear'),
                    onClearAll: state.clear,
                    canClear: () => state.hasFilter,
                    sections: (BuildContext _, LibraryFilterPanelUpdate u) =>
                        _sections(state, u),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 焦点驱动打开：页头按钮聚焦后 Enter（FushiIconButton 经 FushiActionOrigin
  // 派发，macOS 档拿得到锚点）。
  Focus.of(
    tester.element(
      find.descendant(
        of: find.byKey(const ValueKey<String>('open_panel')),
        matching: find.byType(Icon),
      ),
    ),
  ).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester) =>
    tester
        .widget<FushiTextButton>(
          find.byKey(const ValueKey<String>('panel_clear')),
        )
        .onPressed !=
    null;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('Apple iOS 档：sheet 导航栏「清除 / 标题 / 完成」，无 chip、无底部按钮区', (
    WidgetTester tester,
  ) async {
    final _State state = _State();
    await _pumpHost(
      tester,
      state,
      glass: true,
      platform: TargetPlatform.iOS,
      size: const Size(400, 900),
    );

    expect(find.byType(FushiAppleSheetHeader), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FushiAppleSheetHeader),
        matching: find.byKey(const ValueKey<String>('panel_clear')),
      ),
      findsOneWidget,
      reason: '「清除」在 sheet 导航栏左端，不在底部',
    );
    expect(
      find.descendant(
        of: find.byType(FushiAppleSheetHeader),
        matching: find.text(t.dialog_done),
      ),
      findsOneWidget,
    );
    expect(find.text('Clear filters'), findsNothing, reason: '没有底部「清除筛选」');
    expect(find.byType(FushiChoiceChip), findsNothing);
    expect(find.byType(FushiFilterChip), findsNothing);

    // 少档位单选 = 分段控件行；多档位 / 排序 = 弹出菜单行。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('panel_watch')),
        matching: find.byType(AdaptiveSettingsSegmentedRow<int>),
      ),
      findsOneWidget,
    );
    for (final String key in <String>['panel_sort', 'panel_year']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(GlassSettingsPopUpButton),
        ),
        findsOneWidget,
        reason: '$key 是「标题 …… 当前值 ⌃⌄」菜单行',
      );
    }
    // 排序 / 筛选维度分两组，多选维度自成一组。
    expect(find.byType(AdaptiveSettingsSection), findsNWidgets(3));

    expect(_enabled(tester), isFalse, reason: '没有生效的筛选时「清除」禁用');

    // 改看完状态：经 update 交回页面（持久化回调被调用），面板跟着重画。
    // 分段行按宽度可能排在行内 / 标题下 / 退成菜单，这里经控件自己的
    // onChanged 选「watched」（第 4 档），验证改动经 update 交回页面。
    tester
        .widget<AdaptiveSettingsSegmentedRow<int>>(
          find.byType(AdaptiveSettingsSegmentedRow<int>),
        )
        .onChanged(3);
    await tester.pumpAndSettle();
    expect(state.watch, _Watch.watched);
    expect(state.persisted, contains('watch:watched'));
    expect(_enabled(tester), isTrue);

    // 多选对勾行：整行点按切换。
    await tester.tap(find.text('4K'));
    await tester.pumpAndSettle();
    expect(state.spec, <String>{'4k'});

    await tester.tap(find.byKey(const ValueKey<String>('panel_clear')));
    await tester.pumpAndSettle();
    expect(state.watch, _Watch.all);
    expect(state.spec, isEmpty);
    expect(state.sort, _Sort.recent, reason: '清除只复位筛选维度，不动排序');
    expect(_enabled(tester), isFalse);

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    expect(find.byType(FushiAppleSheetHeader), findsNothing, reason: '「完成」关闭');
  });

  testWidgets('Apple macOS 档：锚在按钮下的 popover，「清除」在标题行；Esc 关闭', (
    WidgetTester tester,
  ) async {
    final _State state = _State()..year = 2024;
    await _pumpHost(
      tester,
      state,
      glass: true,
      platform: TargetPlatform.macOS,
      size: const Size(1400, 900),
    );

    expect(find.byType(FushiAppleSheetHeader), findsNothing);
    expect(find.byType(FushiChoiceChip), findsNothing);
    expect(find.byType(FushiFilterChip), findsNothing);
    final Rect anchor = tester.getRect(
      find.byKey(const ValueKey<String>('open_panel')),
    );
    final Rect clear = tester.getRect(
      find.byKey(const ValueKey<String>('panel_clear')),
    );
    final Rect title = tester.getRect(find.text('Sort and filter').last);
    expect(clear.top, greaterThan(anchor.bottom), reason: '面板在按钮下方');
    expect(
      (clear.center.dy - title.center.dy).abs(),
      lessThan(2),
      reason: '「清除」与标题同一行，不是底部按钮区',
    );
    expect(_enabled(tester), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('panel_watch')),
        matching: find.byType(AdaptiveSettingsSegmentedRow<int>),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('panel_clear')), findsNothing);
  });

  testWidgets('M3E 不变：chip 分组 + 底部「清除筛选」', (WidgetTester tester) async {
    final _State state = _State();
    await _pumpHost(
      tester,
      state,
      glass: false,
      platform: TargetPlatform.android,
      size: const Size(400, 900),
    );
    expect(find.byType(FushiChoiceChip), findsWidgets);
    expect(find.byType(FushiFilterChip), findsNWidgets(3));
    expect(find.byType(GlassSettingsPopUpButton), findsNothing);
    expect(find.byType(FushiAppleSheetHeader), findsNothing);
    expect(find.text('Clear filters'), findsOneWidget);
    expect(_enabled(tester), isTrue, reason: 'M3E「清除」恒可点（行为不变）');
  });
}
