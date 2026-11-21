import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Fushi 跑在哪个操作系统上：设置层（schema 的可见性 / 可选值、出厂默认值）读平台
/// 的唯一入口。
///
/// 为什么不直接读 `dart:io` 的 `Platform.isXxx`：那是进程级常量，测试与工具没有
/// 任何缝去声明「这一遍讲的是 iOS」。设置项目录导出器
/// （`test/settings/settings_catalog_export_test.dart`）要在 Linux CI 上按四个出包平台
/// （Android / iOS / Windows / macOS）各走一遍设置索引，读出每个平台上的出厂默认值与
/// 可见行；直读 `Platform` 的判据只会给出 CI 宿主（Linux，不出包）的结果。
/// 生产里 [hostPlatform] 恒等于真实平台，行为不变。
///
/// 设置层（`lib/src/settings/`、`lib/src/ops/settings_index.dart`、
/// `lib/src/ops/ctl_settings_body_*.dart`）禁止再直读 `Platform.isXxx`，由
/// `test/settings/settings_host_platform_guard_test.dart` 守。
enum HostPlatform {
  android('android'),
  ios('ios'),
  windows('windows'),
  macos('macos'),
  linux('linux');

  const HostPlatform(this.wireName);

  /// 目录 JSON / 日志里用的稳定名（与 `Platform.operatingSystem` 同形）。
  final String wireName;

  /// 出包的平台（Linux 不进发布矩阵）。
  static const List<HostPlatform> shipping = <HostPlatform>[
    HostPlatform.android,
    HostPlatform.ios,
    HostPlatform.windows,
    HostPlatform.macos,
  ];

  bool get isAndroid => this == HostPlatform.android;
  bool get isIOS => this == HostPlatform.ios;
  bool get isWindows => this == HostPlatform.windows;
  bool get isMacOS => this == HostPlatform.macos;
  bool get isLinux => this == HostPlatform.linux;

  /// Windows / macOS / Linux。
  bool get isDesktop => isWindows || isMacOS || isLinux;

  /// Android / iOS。
  bool get isMobile => isAndroid || isIOS;

  /// 对应的 Flutter [TargetPlatform]（导出器据此同步
  /// `debugDefaultTargetPlatformOverride`，让读 [defaultTargetPlatform] 的判据一起切）。
  TargetPlatform get targetPlatform => switch (this) {
    HostPlatform.android => TargetPlatform.android,
    HostPlatform.ios => TargetPlatform.iOS,
    HostPlatform.windows => TargetPlatform.windows,
    HostPlatform.macos => TargetPlatform.macOS,
    HostPlatform.linux => TargetPlatform.linux,
  };
}

/// 测试 / 导出器专用：非 null 时 [hostPlatform] 返回它。用完必须复位为 null。
@visibleForTesting
HostPlatform? debugHostPlatformOverride;

/// 当前宿主平台（见 [HostPlatform]）。
HostPlatform get hostPlatform => debugHostPlatformOverride ?? _realHostPlatform;

final HostPlatform _realHostPlatform = _detectHostPlatform();

HostPlatform _detectHostPlatform() {
  if (Platform.isAndroid) return HostPlatform.android;
  if (Platform.isIOS) return HostPlatform.ios;
  if (Platform.isWindows) return HostPlatform.windows;
  if (Platform.isMacOS) return HostPlatform.macos;
  // Linux 与其余不支持的宿主都按 Linux 处理：桌面、无商店限制。
  return HostPlatform.linux;
}
