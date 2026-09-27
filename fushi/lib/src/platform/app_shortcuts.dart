import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 长按 app 图标弹出的系统快捷方式（Android launcher shortcuts / iOS Home Screen
/// quick actions）。
///
/// 两端都不另起投递通道：快捷方式点下去就是一条 `fushi://shortcut/<id>` URL，
/// Android 以 ACTION_VIEW intent 进 `receive_intent`，iOS 由 SceneDelegate 把
/// `UIApplicationShortcutItem` 换成同一条 URL 交给 `url_events`，最终都落在
/// main.dart 的 `handleIncomingUrl`——与 OAuth / AnkiMobile 回跳同一个入口。
///
/// 列表是**动态**发布的（而不是 Android `shortcuts.xml` / iOS Info.plist 静态
/// 声明），因为它要跟着两样东西走：用户在「功能模块」里关掉的模块不该出现在
/// 图标菜单里；标签要跟 app 内语言设置（不是系统语言）一致。
///
/// 只有查词与三个媒体库页四条，两端一致（所有者 2026-09-27 拍板；iOS 图标菜单
/// 本就只显示前 4 条）。游戏库 / 设置曾发布过：Android 上被固定到桌面的会被原生
/// 侧置灰，旧 URL 在这里解析为 `null` 按「未处理」放行。
enum AppShortcut {
  lookup(HomeTab.dictionaries, ModuleId.lookup),
  books(HomeTab.books, ModuleId.books),
  manga(HomeTab.manga, ModuleId.manga),
  video(HomeTab.video, ModuleId.video);

  const AppShortcut(this.homeTab, this.module);

  /// 点下去要落到的首页 tab。
  final HomeTab homeTab;

  /// 门控模块：用户在「功能模块」里关掉它，快捷方式就不发布、也不落地。
  final ModuleId module;

  static const String _scheme = 'fushi';
  static const String _host = 'shortcut';

  /// 两端原生侧只认这个 id（选图标用），改名要同步 `AppShortcutsHelper.java`
  /// 与 `AppDelegate.swift`（`appShortcutSymbol`）。
  String get id => name;

  String get url => '$_scheme://$_host/$id';

  /// 不是快捷方式 URL 返回 `null`；是快捷方式 URL 但 id 未知（新版本发布的
  /// 固定快捷方式被降级回旧版本点开）也返回 `null`，调用方按「未处理」放行。
  static AppShortcut? tryParse(String? value) {
    if (value == null) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != _scheme ||
        uri.host.toLowerCase() != _host) {
      return null;
    }
    final String id = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    for (final AppShortcut shortcut in values) {
      if (shortcut.id == id) return shortcut;
    }
    return null;
  }

  /// 本平台此刻该发布的快捷方式（按展示顺序）：查词 > 书 > 漫画 > 视频。
  static List<AppShortcut> available(ModuleVisibility visibility) => [
    for (final AppShortcut shortcut in values)
      if (visibility.isEnabled(shortcut.module)) shortcut,
  ];
}

/// 把快捷方式列表发给原生侧。只在 Android / iOS 上生效，其余平台 no-op。
///
/// 调用方（根 widget 的 build）每次重建都会调它，本类按「id + 标签」签名去重，
/// 只有模块开关或界面语言真的变了才过一次通道。
class AppShortcutsPublisher {
  @visibleForTesting
  AppShortcutsPublisher({required this.platformSupported});

  static final AppShortcutsPublisher instance = AppShortcutsPublisher(
    platformSupported: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
  );

  static const MethodChannel _channel = FushiChannels.appShortcuts;

  /// 只有 Android / iOS 有原生侧；其余平台发了也是 MissingPluginException。
  final bool platformSupported;

  String? _lastSignature;

  /// Android 上已被固定到桌面、这次不再发布的快捷方式会被原生侧置灰
  /// （`setDynamicShortcuts` 删不掉固定快捷方式）。置灰提示分两种：
  /// - 仍是 [AppShortcut] 但模块被关掉了（载荷 `moduleDisabledIds`）：用户点它时
  ///   启动器显示 [disabledMessage]（「此功能模块已关闭」）。
  /// - 已不再是快捷方式的旧 id（曾发布过的游戏库 / 设置）：不是模块关闭，给启动器
  ///   默认文案。
  void sync(
    List<AppShortcut> shortcuts, {
    required String Function(AppShortcut shortcut) labelOf,
    required String disabledMessage,
  }) {
    if (!platformSupported) return;
    final List<Map<String, String>> payload = [
      for (final AppShortcut shortcut in shortcuts)
        <String, String>{
          'id': shortcut.id,
          'title': labelOf(shortcut),
          'url': shortcut.url,
        },
    ];
    final List<String> moduleDisabledIds = [
      for (final AppShortcut shortcut in AppShortcut.values)
        if (!shortcuts.contains(shortcut)) shortcut.id,
    ];
    final String signature = [
      for (final Map<String, String> item in payload)
        '${item['id']}=${item['title']}',
      disabledMessage,
    ].join('\n');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    _channel
        .invokeMethod<void>('setShortcuts', <String, Object>{
          'items': payload,
          'disabledMessage': disabledMessage,
          'moduleDisabledIds': moduleDisabledIds,
        })
        .catchError((Object error) {
          // 发布失败只影响图标菜单，不影响 app 本身；清掉签名让下次重建重试。
          _lastSignature = null;
          debugPrint('AppShortcutsPublisher: setShortcuts failed: $error');
        });
  }
}
