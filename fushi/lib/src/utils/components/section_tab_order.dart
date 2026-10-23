import 'dart:async';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel, appProvider;
import 'package:fushi/src/models/preference_keys.dart'
    show kSectionTabOrderPrefKeyPrefix;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 库页顶部页签的用户自定义顺序（反馈 ndQ5eXLcqp：「视频除了在线源其他基本不会
// 用到，最多导入一下本地，很不巧这两个都排在最后面」）。
//
// 只在 [LibrarySectionTabs] 组件层做一次：宿主给页签一个稳定的 `orderId` 并给
// 整排一个 `orderKey`，长按 / 右键页签栏弹出排序面板，顺序存在
// `<kSectionTabOrderPrefKeyPrefix><orderKey>`。存的是页签 id 而不是下标：页签
// 随平台 / 模块开关增减时，存储里没有的（新增）页签按宿主原顺序追加在末尾，
// 存储里有但此刻不存在的直接忽略，顺序永远不会错位。只改**显示顺序**，选中
// 哪个、记住上次停在哪个仍是宿主自己的事。

/// 页签在顺序存储里的身份：宿主给的 [LibrarySectionTab.orderId]，没给时用值的
/// `toString()`（枚举就是 `Enum.name` 的限定写法，稳定）。
String sectionTabOrderId<T>(LibrarySectionTab<T> tab) =>
    tab.orderId ?? tab.value.toString();

/// 解析存储值；空 / 缺失 = 没排过。
List<String> parseSectionTabOrder(String? raw) => <String>[
  if (raw != null)
    for (final String id in raw.split(','))
      if (id.trim().isNotEmpty) id.trim(),
];

/// 纯函数：按 [storedIds] 重排 [tabs]。存储里没有的页签按原顺序追加在末尾，
/// 存储里有但 [tabs] 里没有的 id 忽略，重复 id 只认第一次。
List<LibrarySectionTab<T>> orderSectionTabs<T>(
  List<LibrarySectionTab<T>> tabs,
  List<String> storedIds,
) {
  if (storedIds.isEmpty) return tabs;
  final Map<String, LibrarySectionTab<T>> byId = <String, LibrarySectionTab<T>>{
    for (final LibrarySectionTab<T> tab in tabs) sectionTabOrderId(tab): tab,
  };
  final List<LibrarySectionTab<T>> out = <LibrarySectionTab<T>>[];
  final Set<String> placed = <String>{};
  for (final String id in storedIds) {
    final LibrarySectionTab<T>? tab = byId[id];
    if (tab != null && placed.add(id)) out.add(tab);
  }
  for (final LibrarySectionTab<T> tab in tabs) {
    if (placed.add(sectionTabOrderId(tab))) out.add(tab);
  }
  return out;
}

/// 页签顺序的读写口。生产走 [PreferencesRepository]；组件测试经
/// [SectionTabOrderScope] 注入内存实现。
abstract interface class SectionTabOrderStore {
  List<String> read(String orderKey);
  Future<void> write(String orderKey, List<String> ids);
}

class _PrefsSectionTabOrderStore implements SectionTabOrderStore {
  _PrefsSectionTabOrderStore(this._prefs);

  final PreferencesRepository _prefs;

  @override
  List<String> read(String orderKey) => parseSectionTabOrder(
    _prefs.getPref('$kSectionTabOrderPrefKeyPrefix$orderKey', defaultValue: '')
        as String?,
  );

  @override
  Future<void> write(String orderKey, List<String> ids) =>
      _prefs.setPref('$kSectionTabOrderPrefKeyPrefix$orderKey', ids.join(','));
}

/// 给子树指定页签顺序存储（组件测试 / 无 ProviderScope 的宿主）。
class SectionTabOrderScope extends InheritedWidget {
  const SectionTabOrderScope({
    required this.store,
    required super.child,
    super.key,
  });

  final SectionTabOrderStore store;

  static SectionTabOrderStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SectionTabOrderScope>()?.store;

  @override
  bool updateShouldNotify(SectionTabOrderScope oldWidget) =>
      store != oldWidget.store;
}

/// 当前上下文可用的顺序存储：显式 [SectionTabOrderScope] 优先；否则有
/// ProviderScope 且偏好已装载时走偏好；都没有（启动早期 / 裸组件）返回 null，
/// 页签按宿主顺序显示、不提供排序入口。
SectionTabOrderStore? resolveSectionTabOrderStore(BuildContext context) {
  final SectionTabOrderStore? scoped = SectionTabOrderScope.maybeOf(context);
  if (scoped != null) return scoped;
  final bool hasScope =
      context
          .getElementForInheritedWidgetOfExactType<
            UncontrolledProviderScope
          >() !=
      null;
  if (!hasScope) return null;
  final AppModel app = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  if (!app.isPreferencesReady) return null;
  return _PrefsSectionTabOrderStore(app.prefsRepo);
}

/// 弹出页签排序面板。[tabs] 是当前显示顺序；每次调整都经 [onChanged] 交回新的
/// 完整 id 顺序（立即生效、立即落库），[onReset] 清掉自定义顺序。
Future<void> showSectionTabOrderSheet<T>({
  required BuildContext context,
  required List<LibrarySectionTab<T>> tabs,
  required ValueChanged<List<LibrarySectionTab<T>>> onChanged,
  required VoidCallback onReset,
  required List<LibrarySectionTab<T>> defaultOrder,
}) {
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) => SectionTabOrderSheet<T>(
      tabs: tabs,
      onChanged: onChanged,
      onReset: onReset,
      defaultOrder: defaultOrder,
    ),
  );
}

/// 页签排序面板：每行一个页签，可拖（鼠标按下即拖、触屏长按拖），每行另有
/// 「上移 / 下移」按钮与同名读屏动作（键盘 / 手柄抓不住拖拽把手）。
class SectionTabOrderSheet<T> extends StatefulWidget {
  const SectionTabOrderSheet({
    required this.tabs,
    required this.onChanged,
    required this.onReset,
    required this.defaultOrder,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final ValueChanged<List<LibrarySectionTab<T>>> onChanged;
  final VoidCallback onReset;
  final List<LibrarySectionTab<T>> defaultOrder;

  @override
  State<SectionTabOrderSheet<T>> createState() =>
      _SectionTabOrderSheetState<T>();
}

class _SectionTabOrderSheetState<T> extends State<SectionTabOrderSheet<T>> {
  late List<LibrarySectionTab<T>> _tabs = <LibrarySectionTab<T>>[
    ...widget.tabs,
  ];

  void _reorder(int from, int to) {
    if (from == to) return;
    setState(() => _tabs.insert(to, _tabs.removeAt(from)));
    widget.onChanged(List<LibrarySectionTab<T>>.unmodifiable(_tabs));
  }

  void _move(int index, int delta) {
    final int target = index + delta;
    if (target < 0 || target >= _tabs.length) return;
    _reorder(index, target);
  }

  void _reset() {
    setState(() => _tabs = <LibrarySectionTab<T>>[...widget.defaultOrder]);
    widget.onReset();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FushiModalSheetFrame(
      title: t.section_tabs_order_title,
      subtitle: t.section_tabs_order_hint,
      leadingIcon: FushiIcons.dragIndicator,
      scrollable: true,
      body: FushiEntranceScope(
        child: FushiReorderableColumn(
          itemCount: _tabs.length,
          keyForIndex: (int index) => ValueKey<String>(
            'section-tab-order-${sectionTabOrderId(_tabs[index])}',
          ),
          onReorder: _reorder,
          itemBuilder: (BuildContext context, int index) {
            final LibrarySectionTab<T> tab = _tabs[index];
            final String id = sectionTabOrderId(tab);
            final bool canUp = index > 0;
            final bool canDown = index < _tabs.length - 1;
            return FushiStaggeredEntrance(
              index: index,
              child: Semantics(
                customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
                  if (canUp)
                    CustomSemanticsAction(label: t.move_up): () =>
                        _move(index, -1),
                  if (canDown)
                    CustomSemanticsAction(label: t.move_down): () =>
                        _move(index, 1),
                },
                child: FushiListItem(
                  key: ValueKey<String>('section-tab-order-row-$id'),
                  title: Text(tab.label),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiIconButton(
                        key: ValueKey<String>('section-tab-order-up-$id'),
                        icon: FushiIcons.expandLess,
                        size: 18,
                        tooltip: t.move_up,
                        enabled: canUp,
                        isWideTapArea: true,
                        onTap: () => _move(index, -1),
                      ),
                      FushiIconButton(
                        key: ValueKey<String>('section-tab-order-down-$id'),
                        icon: FushiIcons.expandMore,
                        size: 18,
                        tooltip: t.move_down,
                        enabled: canDown,
                        isWideTapArea: true,
                        onTap: () => _move(index, 1),
                      ),
                      ExcludeSemantics(
                        child: FushiIcon(
                          FushiIcons.dragIndicator,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      footer: Row(
        children: <Widget>[
          FushiTextButton(
            key: const ValueKey<String>('section-tab-order-reset'),
            onPressed: _reset,
            child: Text(t.section_tabs_order_reset),
          ),
          const Spacer(),
          FushiFilledButton(
            key: const ValueKey<String>('section-tab-order-done'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.section_tabs_order_done),
          ),
        ],
      ),
    );
  }
}
