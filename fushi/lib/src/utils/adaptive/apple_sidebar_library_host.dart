import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Apple 宽窗侧栏里，当前模块下展开的一行分区（2026-11-24 用户拍板方案 A：
/// macOS 档侧栏把当前库页展开成「分区 + 在线」子项，内容区不再画分区胶囊行）。
///
/// 纯数据；渲染在 `AppleSidebarTabsShell`（与侧栏其它行同一套源列表规格）。
@immutable
class AppleSidebarLibraryRow {
  const AppleSidebarLibraryRow({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.depth = 1,
    this.tint,
    this.header = false,
  });

  /// 节标题行（「标签」）：不可点、不可聚焦，只画小标题。
  const AppleSidebarLibraryRow.header({required this.id, required this.label})
    : selected = false,
      onTap = _noop,
      icon = null,
      depth = 1,
      tint = null,
      header = true;

  static void _noop() {}

  /// 稳定身份（焦点 id 与比较用）。
  final String id;
  final String label;
  final IconData? icon;
  final bool selected;

  /// 缩进层级：1 = 模块下的分区，2 = 「在线」下的在线分区。
  final int depth;
  final VoidCallback onTap;

  /// 图标颜色（标签行：标签自己的颜色，Finder 标签式）；null = 侧栏强调色。
  final Color? tint;

  /// 是否节标题行（见 [AppleSidebarLibraryRow.header]）。
  final bool header;

  /// 只比可见内容（[onTap] 是闭包，每次构建都是新对象）。
  bool sameLook(AppleSidebarLibraryRow other) =>
      id == other.id &&
      label == other.label &&
      icon == other.icon &&
      selected == other.selected &&
      depth == other.depth &&
      tint == other.tint &&
      header == other.header;
}

/// 库页往侧栏登记分区行的宿主（首页外壳持有一个，经 [AppleSidebarLibraryScope]
/// 下发到各 tab；侧栏外壳监听它）。
///
/// - 每个库页布局以自己为 owner 登记（保活的 tab 同时挂着几个库页），只在自己
///   所在 tab 可见时登记、隐藏即撤回，所以任何时刻至多一份是「看得见的」；
/// - [sidebarMode] 由侧栏外壳报告：侧栏收成顶部标签栏（或根本不是侧栏布局）时
///   为 false，库页据此把分区画回内容区的胶囊行。
///
/// 登记与报告都推迟到帧末通知（布局 / 构建期间不能让监听者重建）。
class AppleSidebarLibraryHost extends ChangeNotifier {
  final Map<Object, List<AppleSidebarLibraryRow>> _entries =
      <Object, List<AppleSidebarLibraryRow>>{};

  /// 最近一次登记的 owner（看得见的那个库页）。
  Object? _visibleOwner;
  bool _sidebarMode = false;
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 侧栏此刻是否以侧栏形态展示（能承载分区子项）。
  bool get sidebarMode => _sidebarMode;

  /// 看得见的库页登记的标签节（[publishTags]），按 owner 存。
  final Map<Object, List<AppleSidebarLibraryRow>> _tagEntries =
      <Object, List<AppleSidebarLibraryRow>>{};
  Object? _visibleTagOwner;

  /// 看得见的库页登记的分区行 + 标签节；没有时为空。
  List<AppleSidebarLibraryRow> get rows {
    final List<AppleSidebarLibraryRow> sections =
        _entries[_visibleOwner] ?? const <AppleSidebarLibraryRow>[];
    final List<AppleSidebarLibraryRow> tags =
        _tagEntries[_visibleTagOwner] ??
        (_tagEntries.isEmpty
            ? const <AppleSidebarLibraryRow>[]
            : _tagEntries.values.last);
    if (tags.isEmpty) return sections;
    return <AppleSidebarLibraryRow>[...sections, ...tags];
  }

  /// 库页的标签栏登记 / 更新侧栏「标签」节（2026-11-24 方案 A 第 8 项：macOS 档
  /// 侧栏承载标签筛选与「管理标签…」，内容区不再画标签 chip）；[rows] 为 null =
  /// 撤回。与 [publish] 同一套「看得见才登记」约定；同一页里同时挂着两份工具行
  /// （宽 / 窄两套布局）时，撤回其中一份不会把另一份的标签节带走。
  void publishTags(Object owner, List<AppleSidebarLibraryRow>? rows) {
    if (rows == null) {
      if (_tagEntries.remove(owner) == null) return;
      if (_visibleTagOwner == owner) _visibleTagOwner = null;
      _scheduleNotify();
      return;
    }
    final List<AppleSidebarLibraryRow>? old = _tagEntries[owner];
    _tagEntries[owner] = rows;
    final bool ownerChanged = _visibleTagOwner != owner;
    _visibleTagOwner = owner;
    if (!ownerChanged && old != null && _sameLook(old, rows)) return;
    _scheduleNotify();
  }

  /// 侧栏外壳报告自己的形态（构建期间可调，通知推迟到帧末）。
  void reportSidebarMode(bool value) {
    if (_sidebarMode == value) return;
    _sidebarMode = value;
    _scheduleNotify();
  }

  /// [owner] 登记 / 更新自己的分区行；[rows] 为 null = 撤回。
  void publish(Object owner, List<AppleSidebarLibraryRow>? rows) {
    if (rows == null) {
      if (_entries.remove(owner) == null) return;
      if (_visibleOwner == owner) _visibleOwner = null;
      _scheduleNotify();
      return;
    }
    final List<AppleSidebarLibraryRow>? old = _entries[owner];
    _entries[owner] = rows;
    final bool ownerChanged = _visibleOwner != owner;
    _visibleOwner = owner;
    if (!ownerChanged && old != null && _sameLook(old, rows)) return;
    _scheduleNotify();
  }

  static bool _sameLook(
    List<AppleSidebarLibraryRow> a,
    List<AppleSidebarLibraryRow> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!a[i].sameLook(b[i])) return false;
    }
    return true;
  }

  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (!_disposed) notifyListeners();
      })
      ..ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 向首页各 tab 下发 [AppleSidebarLibraryHost]（只在 Apple 宽窗侧栏外壳里有）。
/// 纯数据通道，与设计系统分派无关。
class AppleSidebarLibraryScope
    extends InheritedNotifier<AppleSidebarLibraryHost> {
  const AppleSidebarLibraryScope({
    required AppleSidebarLibraryHost host,
    required super.child,
    super.key,
  }) : super(notifier: host);

  /// 最近的宿主并建立依赖（侧栏形态变化时重建）；不在侧栏外壳里为 null。
  static AppleSidebarLibraryHost? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppleSidebarLibraryScope>()
      ?.notifier;

  /// 同 [maybeOf]，不建立依赖（登记用）。
  static AppleSidebarLibraryHost? peek(BuildContext context) => context
      .getInheritedWidgetOfExactType<AppleSidebarLibraryScope>()
      ?.notifier;
}
