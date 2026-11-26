import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/host_platform.dart';

/// 托盘菜单里的一项动作。
///
/// 顺序 = 菜单里的展示顺序（分组见 [DesktopTrayEntry.group]）：
/// 显示窗口 ｜ 查词三件套 ｜ 各库页 ｜ 设置 ｜ 退出。
enum DesktopTrayEntry {
  /// 显示主窗口（菜单默认项，粗体；单击托盘图标做的也是它）。
  show(group: 0, revealWindow: true),

  /// 打开查词页并聚焦搜索框（与全局「打开查词页」热键同一条路径）。
  lookup(
    group: 1,
    revealWindow: true,
    homeTab: HomeTab.dictionaries,
    module: ModuleId.lookup,
  ),

  /// 查剪贴板里的文字：弹应用外查词窗，**不**把主窗口带出来。
  clipboardLookup(group: 1, revealWindow: false),

  /// 截屏识字（与「截屏识字」全局热键 / 应用外悬浮球按钮同一条路径）。
  screenOcr(group: 1, revealWindow: false),

  books(
    group: 2,
    revealWindow: true,
    homeTab: HomeTab.books,
    module: ModuleId.books,
  ),
  manga(
    group: 2,
    revealWindow: true,
    homeTab: HomeTab.manga,
    module: ModuleId.manga,
  ),
  video(
    group: 2,
    revealWindow: true,
    homeTab: HomeTab.video,
    module: ModuleId.video,
  ),
  music(
    group: 2,
    revealWindow: true,
    homeTab: HomeTab.music,
    module: ModuleId.music,
  ),
  srs(group: 2, revealWindow: true, homeTab: HomeTab.srs, module: ModuleId.srs),

  settings(group: 3, revealWindow: true, homeTab: HomeTab.settings),

  /// 退出 Fushi（走与关窗口同一条落盘退出链）。
  exit(group: 4, revealWindow: false);

  const DesktopTrayEntry({
    required this.group,
    required this.revealWindow,
    this.homeTab,
    this.module,
  });

  /// 分组号：相邻两项分组不同就在中间画分隔线。
  final int group;

  /// 点了要先把主窗口带回前台。原生侧在菜单命令返回的同一调用栈里做（托盘交互
  /// 刚给了本进程前台权），不等 Dart 绕一圈。
  final bool revealWindow;

  /// 落到哪个首页 tab；null = 不是导航项。
  final HomeTab? homeTab;

  /// 门控模块：用户在「功能模块」里关掉它，菜单里就不出现。
  final ModuleId? module;

  /// 通道上的 id（原生侧原样回传）。
  String get id => name;

  static DesktopTrayEntry? tryParse(Object? id) {
    for (final DesktopTrayEntry entry in values) {
      if (entry.id == id) return entry;
    }
    return null;
  }
}

/// 菜单上的一行：一项动作或一条分隔线。
@immutable
class DesktopTrayMenuItem {
  const DesktopTrayMenuItem.entry(DesktopTrayEntry this.entry, this.label)
    : separator = false;

  const DesktopTrayMenuItem.separator()
    : entry = null,
      label = '',
      separator = true;

  final DesktopTrayEntry? entry;
  final String label;
  final bool separator;

  Map<String, Object> toWire() => separator
      ? const <String, Object>{'separator': true}
      : <String, Object>{
          'id': entry!.id,
          'label': label,
          'isDefault': entry == DesktopTrayEntry.show,
          'revealWindow': entry!.revealWindow,
        };

  @override
  bool operator ==(Object other) =>
      other is DesktopTrayMenuItem &&
      other.entry == entry &&
      other.label == label &&
      other.separator == separator;

  @override
  int get hashCode => Object.hash(entry, label, separator);
}

/// 按模块开关与能力拼出托盘菜单。纯函数，便于测试。
///
/// - 模块被关掉的导航项不出现（与长按图标快捷方式同口径）。
/// - [screenOcrAvailable]：截屏识字的执行体（常驻悬浮球宿主）装上了才给这一项。
/// - [clipboardLookupAvailable]：应用外查词窗可用才给剪贴板查词。
/// - 分组之间一条分隔线；空组不留多余分隔线。
List<DesktopTrayMenuItem> buildDesktopTrayMenu({
  required bool Function(ModuleId module) isModuleEnabled,
  required String Function(DesktopTrayEntry entry) labelOf,
  required bool screenOcrAvailable,
  required bool clipboardLookupAvailable,
}) {
  final List<DesktopTrayMenuItem> items = <DesktopTrayMenuItem>[];
  int? lastGroup;
  for (final DesktopTrayEntry entry in DesktopTrayEntry.values) {
    final ModuleId? module = entry.module;
    if (module != null && !isModuleEnabled(module)) continue;
    if (entry == DesktopTrayEntry.screenOcr && !screenOcrAvailable) continue;
    if (entry == DesktopTrayEntry.clipboardLookup &&
        !clipboardLookupAvailable) {
      continue;
    }
    if (lastGroup != null && lastGroup != entry.group) {
      items.add(const DesktopTrayMenuItem.separator());
    }
    lastGroup = entry.group;
    items.add(DesktopTrayMenuItem.entry(entry, labelOf(entry)));
  }
  return items;
}

/// 主窗口的系统托盘图标（Windows 通知区域）。
///
/// 原生侧（`windows/runner/tray_icon.cpp` + `flutter_window.cpp` 的
/// `app.fushi/tray`）只管 Win32：挂图标、弹原生菜单、拦「关闭到托盘」的 SC_CLOSE；
/// 菜单内容、语言、开关都由这里推过去。
///
/// 关闭到托盘只拦**用户的关闭手势**（标题栏关闭按钮、Alt+F4、任务栏「关闭窗口」，
/// 都是 SC_CLOSE），安装器 / taskkill 的裸 WM_CLOSE 照旧走落盘退出链。
///
/// 只有 Windows：macOS 有 Dock 常驻，Linux 托盘要额外的 AppIndicator 运行库。
class DesktopTray {
  @visibleForTesting
  DesktopTray({required this.platformSupported, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('app.fushi/tray');

  static final DesktopTray instance = DesktopTray(
    platformSupported: hostPlatform.isWindows,
  );

  final MethodChannel _channel;
  final bool platformSupported;

  void Function(DesktopTrayEntry entry)? _onEntry;
  VoidCallback? _onHiddenToTray;
  VoidCallback? _onActivate;
  String? _lastSignature;
  List<DesktopTrayMenuItem>? _items;
  String _tooltip = 'Fushi';
  bool _closeToTray = false;

  /// 根 widget 挂载时装上回调。原生回调只在这之后才有意义，所以通道处理器也在
  /// 这里装。
  void attach({
    required void Function(DesktopTrayEntry entry) onEntry,
    required VoidCallback onHiddenToTray,
    VoidCallback? onActivate,
  }) {
    if (!platformSupported) return;
    _onEntry = onEntry;
    _onHiddenToTray = onHiddenToTray;
    _onActivate = onActivate;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  void detach() {
    if (!platformSupported) return;
    _onEntry = null;
    _onHiddenToTray = null;
    _onActivate = null;
    _channel.setMethodCallHandler(null);
  }

  @visibleForTesting
  Future<Object?> handleNativeCallForTest(MethodCall call) =>
      _handleNativeCall(call);

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onMenuItem':
        final DesktopTrayEntry? entry = DesktopTrayEntry.tryParse(
          call.arguments,
        );
        if (entry != null) _onEntry?.call(entry);
      case 'onActivate':
        _onActivate?.call();
      case 'onHiddenToTray':
        _onHiddenToTray?.call();
    }
    return null;
  }

  /// 把菜单 / 提示 / 关闭到托盘开关推给原生侧。根 build 每次重建都会调，按签名
  /// 去重，只有内容真的变了才过一次通道。
  void sync({
    required List<DesktopTrayMenuItem> items,
    required String tooltip,
    required bool closeToTray,
  }) {
    if (!platformSupported) return;
    _items = items;
    _tooltip = tooltip;
    _closeToTray = closeToTray;
    _push();
  }

  /// 设置页切「关闭时最小化到托盘」：立刻生效，不等根 widget 下一次重建。
  void setCloseToTray(bool closeToTray) {
    if (!platformSupported) return;
    _closeToTray = closeToTray;
    _push();
  }

  void _push() {
    final List<DesktopTrayMenuItem>? items = _items;
    // 菜单还没拼出来（app 未初始化完）就不挂图标：此时关闭照旧退出。
    if (items == null) return;
    final String signature = <String>[
      _tooltip,
      '$_closeToTray',
      for (final DesktopTrayMenuItem item in items)
        item.separator ? '-' : '${item.entry!.id}=${item.label}',
    ].join('\n');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    unawaited(_configure(items, tooltip: _tooltip, closeToTray: _closeToTray));
  }

  Future<void> _configure(
    List<DesktopTrayMenuItem> items, {
    required String tooltip,
    required bool closeToTray,
  }) async {
    try {
      await _channel.invokeMethod<bool>('configure', <String, Object>{
        'visible': true,
        'tooltip': tooltip,
        'closeToTray': closeToTray,
        'items': <Map<String, Object>>[
          for (final DesktopTrayMenuItem item in items) item.toWire(),
        ],
      });
    } on PlatformException catch (e) {
      // 下次重建再试一次，而不是永远卡在「以为发过了」。
      _lastSignature = null;
      debugPrint('[Fushi] tray configure failed: $e');
    } on MissingPluginException {
      _lastSignature = null;
    }
  }

  /// 托盘气泡（Windows 10/11 显示成系统通知）。
  Future<void> showNotification({
    required String title,
    required String body,
  }) async {
    if (!platformSupported) return;
    try {
      await _channel.invokeMethod<void>('showNotification', <String, String>{
        'title': title,
        'body': body,
      });
    } on PlatformException catch (e) {
      debugPrint('[Fushi] tray notification failed: $e');
    } on MissingPluginException {
      return;
    }
  }
}
