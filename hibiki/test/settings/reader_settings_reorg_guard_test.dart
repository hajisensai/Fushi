import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_listening.dart';
import 'package:hibiki/src/settings/settings_schema_reading.dart';

/// TODO-725 守卫：阅读器设置面板重新归类/排序。
///
/// 这些断言锁住「数据结构」契约（ReaderPlacement.group/order），与渲染层无关：
/// - 翻页/滚动（view_mode）归「布局与显示」组（layout），且是该组首项；
/// - layout / behavior 两组的 order 在组内严格单调递增、无撞号；
/// - 手势类（滚轮/滑动/箭头/音量键）仍留在「阅读操作」（behavior），未被误移。
///
/// 不经 SettingsContext 直接调无参 destination builder 收集 placement——
/// [collectReaderItems] 与 [buildSettingsSchema] 的形参 context 在收集路径上
/// 从不被解引用（只读 const ReaderPlacement），故纯结构守卫与运行时一致。
void main() {
  /// 把若干 destination 里带 ReaderPlacement 的项按 group 聚合、按 order 升序。
  /// 等价于 [collectReaderItems] 对这些文件的部分（零 harness 依赖）。
  Map<ReaderGroup, List<SettingsItem>> collectFrom(
    List<SettingsDestination> destinations,
  ) {
    final Map<ReaderGroup, List<SettingsItem>> grouped =
        <ReaderGroup, List<SettingsItem>>{};
    for (final SettingsDestination destination in destinations) {
      for (final SettingsSection section in destination.sections) {
        for (final SettingsItem item in section.items) {
          final ReaderPlacement? placement = item.reader;
          if (placement == null) continue;
          grouped
              .putIfAbsent(placement.group, () => <SettingsItem>[])
              .add(item);
        }
      }
    }
    for (final List<SettingsItem> items in grouped.values) {
      items.sort((SettingsItem a, SettingsItem b) =>
          a.reader!.order.compareTo(b.reader!.order));
    }
    return grouped;
  }

  Map<ReaderGroup, List<SettingsItem>> collected() => collectFrom(
        <SettingsDestination>[
          buildReadingDestination(),
          buildListeningDestination(),
        ],
      );

  test('view_mode（翻页/滚动）归 layout 组且为该组首项（TODO-725）', () {
    final Map<ReaderGroup, List<SettingsItem>> grouped = collected();
    final List<SettingsItem> layout = grouped[ReaderGroup.layout]!;
    final List<String> layoutIds =
        layout.map((SettingsItem i) => i.id).toList();
    expect(layoutIds, contains('reading_display.view_mode'),
        reason: '翻页/滚动必须出现在「布局与显示」组');
    expect(layoutIds.first, 'reading_display.view_mode',
        reason: 'view_mode 是 layout 组排序后的首项（order 0）');
    // 不再属于 appearance 组。
    final List<SettingsItem> appearance =
        grouped[ReaderGroup.appearance] ?? <SettingsItem>[];
    expect(
      appearance.map((SettingsItem i) => i.id),
      isNot(contains('reading_display.view_mode')),
    );
  });

  test('字号/行高/缩进归 layout 组、appearance 组无 schema 项（TODO-774）', () {
    final Map<ReaderGroup, List<SettingsItem>> grouped = collected();
    final List<String> layoutIds =
        grouped[ReaderGroup.layout]!.map((SettingsItem i) => i.id).toList();
    for (final String id in <String>[
      'reading_display.font_size',
      'reading_display.line_height',
      'reading_display.text_indentation',
    ]) {
      expect(layoutIds, contains(id), reason: '$id 是字体/行高/缩进，应并入「布局与显示」组');
    }
    // appearance 组在 TODO-774 后已无任何 schema 项（grouped 中应缺失或为空）。
    final List<SettingsItem> appearance =
        grouped[ReaderGroup.appearance] ?? <SettingsItem>[];
    expect(appearance, isEmpty,
        reason: 'appearance 组已无 schema 项（3 项已迁到 layout）');
  });

  test('layout 组 order 连续无洞 {0..N}（TODO-774 撞号守卫）', () {
    final Map<ReaderGroup, List<SettingsItem>> grouped = collected();
    final List<int> orders = grouped[ReaderGroup.layout]!
        .map((SettingsItem i) => i.reader!.order)
        .toList();
    final Set<int> expected = <int>{
      for (int i = 0; i < orders.length; i++) i,
    };
    expect(orders.toSet(), expected,
        reason: 'layout 组 order 必须是连续无洞的 {0..${orders.length - 1}}：$orders');
  });

  test('手势类设置仍留在 behavior（阅读操作）组（TODO-725）', () {
    final Map<ReaderGroup, List<SettingsItem>> grouped = collected();
    final Set<String> behaviorIds =
        grouped[ReaderGroup.behavior]!.map((SettingsItem i) => i.id).toSet();
    for (final String id in <String>[
      'reading_controls.wheel_page_turn_interval',
      'reading_controls.swipe_page_turn_sensitivity',
      'reading_controls.reverse_arrow_page_turn',
      'reading_controls.invert_swipe_direction',
      'reading_controls.volume_page_turning',
    ]) {
      expect(behaviorIds, contains(id),
          reason: '$id 是阅读操作（behavior），不应被移到 layout');
    }
  });

  test('layout / behavior 组 order 组内严格单调、无撞号（TODO-725）', () {
    final Map<ReaderGroup, List<SettingsItem>> grouped = collected();
    for (final ReaderGroup group in <ReaderGroup>[
      ReaderGroup.layout,
      ReaderGroup.behavior,
    ]) {
      final List<SettingsItem> items = grouped[group]!;
      final List<int> orders =
          items.map((SettingsItem i) => i.reader!.order).toList();
      final Set<int> unique = orders.toSet();
      expect(unique.length, orders.length,
          reason: '$group 组 order 不得撞号：$orders');
      final List<int> sorted = List<int>.of(orders)..sort();
      expect(orders, sorted, reason: '$group 组应已按 order 升序');
    }
  });
}
