import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/lookup/browser_extension_installer.dart';

/// 浏览器扩展安装引导用的「默认浏览器」探测 + 「尝试打开扩展管理页」。
///
/// 两件事都是**尽力而为**：探测只用来预选引导里的浏览器 chip（探不到就停在
/// 枚举第一个），打开失败时页面提示用户复制地址手动粘贴——都不影响安装本身。
/// 扩展管理页是浏览器私有 scheme（`chrome://` 等），`url_launcher` 交给系统
/// 处理时没有关联程序，只能把地址当参数直接交给对应浏览器的可执行文件。

/// 引导 chip 上显示的浏览器名（产品名，不进 i18n）。
String browserDisplayName(BrowserKind kind) {
  switch (kind) {
    case BrowserKind.chrome:
      return 'Chrome';
    case BrowserKind.edge:
      return 'Edge';
    case BrowserKind.brave:
      return 'Brave';
    case BrowserKind.vivaldi:
      return 'Vivaldi';
    case BrowserKind.opera:
      return 'Opera';
  }
}

/// 纯函数：把系统给出的默认浏览器标识映射成 [BrowserKind]。
///
/// 认得三种来源的写法：Windows UserChoice ProgId（`ChromeHTML` / `MSEdgeHTM` /
/// `BraveHTML` / `VivaldiHTM.xxx` / `OperaStable`）、macOS LaunchServices bundle id
/// （`com.google.chrome` / `com.microsoft.edgemac` / `com.brave.browser` /
/// `com.vivaldi.vivaldi` / `com.operasoftware.opera`）、Linux `xdg-settings` 的
/// desktop 文件名（`google-chrome.desktop` / `microsoft-edge.desktop` …）。
/// 不认识的（Firefox / Safari 等不支持本扩展的浏览器）返回 null。
@visibleForTesting
BrowserKind? browserKindFromDefaultBrowserId(String id) {
  final String v = id.trim().toLowerCase();
  if (v.isEmpty) return null;
  // 先判 Edge / Brave / Vivaldi / Opera：它们的标识里都不含 chrome，但
  // Chromium 系的 desktop 名可能带 chromium，放最后兜给 Chrome。
  if (v.contains('msedge') || v.contains('edgemac') || v.contains('edge')) {
    return BrowserKind.edge;
  }
  if (v.contains('brave')) return BrowserKind.brave;
  if (v.contains('vivaldi')) return BrowserKind.vivaldi;
  if (v.contains('opera')) return BrowserKind.opera;
  if (v.contains('chrome')) return BrowserKind.chrome;
  return null;
}

/// 纯函数：从 `reg query ...\UserChoice /v ProgId` 的输出里取 ProgId。
@visibleForTesting
String? parseWindowsUserChoiceProgId(String regOutput) {
  for (final String line in regOutput.split(RegExp(r'\r?\n'))) {
    final Match? m =
        RegExp(r'^\s*ProgId\s+REG_SZ\s+(\S.*?)\s*$', caseSensitive: false)
            .firstMatch(line);
    if (m != null) return m.group(1);
  }
  return null;
}

/// 纯函数：从 `defaults read com.apple.LaunchServices/com.apple.launchservices.secure
/// LSHandlers` 的输出里取 https（退而求 http）的处理程序 bundle id。
@visibleForTesting
String? parseMacLaunchServicesHandler(String output) {
  // 输出是 plist 文本数组：每个处理程序是一对花括号；按块切开再找 scheme。
  final List<String> blocks = output.split('}');
  String? find(String scheme) {
    for (final String block in blocks) {
      if (!RegExp('LSHandlerURLScheme\\s*=\\s*"?$scheme"?;').hasMatch(block)) {
        continue;
      }
      final Match? m =
          RegExp(r'LSHandlerRoleAll\s*=\s*"?([^";\s]+)"?;').firstMatch(block);
      if (m != null) return m.group(1);
    }
    return null;
  }

  return find('https') ?? find('http');
}

/// 探测当前桌面系统的默认浏览器；探不到 / 不是受支持的浏览器时返回 null。
Future<BrowserKind?> detectDefaultBrowserKind() async {
  try {
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('reg', <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice',
        '/v',
        'ProgId',
      ]);
      if (r.exitCode != 0) return null;
      final String? progId = parseWindowsUserChoiceProgId('${r.stdout}');
      return progId == null ? null : browserKindFromDefaultBrowserId(progId);
    }
    if (Platform.isMacOS) {
      final ProcessResult r = await Process.run('defaults', <String>[
        'read',
        'com.apple.LaunchServices/com.apple.launchservices.secure',
        'LSHandlers',
      ]);
      if (r.exitCode != 0) return null;
      final String? bundleId = parseMacLaunchServicesHandler('${r.stdout}');
      return bundleId == null
          ? null
          : browserKindFromDefaultBrowserId(bundleId);
    }
    if (Platform.isLinux) {
      final ProcessResult r = await Process.run(
          'xdg-settings', <String>['get', 'default-web-browser']);
      if (r.exitCode != 0) return null;
      return browserKindFromDefaultBrowserId('${r.stdout}');
    }
  } on ProcessException {
    // 系统缺 reg / defaults / xdg-settings：探测是可选增强，按「探不到」处理，
    // 引导停在枚举第一个浏览器上。
    return null;
  }
  return null;
}

/// Windows App Paths 里各浏览器登记的可执行名。
String _windowsExeName(BrowserKind kind) => switch (kind) {
      BrowserKind.chrome => 'chrome.exe',
      BrowserKind.edge => 'msedge.exe',
      BrowserKind.brave => 'brave.exe',
      BrowserKind.vivaldi => 'vivaldi.exe',
      BrowserKind.opera => 'opera.exe',
    };

/// 纯函数：从 `reg query <App Paths\x.exe> /ve` 的输出里取默认值（可执行文件
/// 绝对路径）。默认值的名字列是本地化的（「(默认)」/「(Default)」），只认
/// `REG_SZ` 之后的部分。
@visibleForTesting
String? parseWindowsRegDefaultValue(String regOutput) {
  for (final String line in regOutput.split(RegExp(r'\r?\n'))) {
    final Match? m =
        RegExp(r'\sREG_(?:EXPAND_)?SZ\s+(\S.*?)\s*$').firstMatch(line);
    if (m != null) return m.group(1)!.replaceAll('"', '');
  }
  return null;
}

/// macOS / Linux 把 [url] 交给 [kind] 浏览器的命令行（可执行名 + 参数）。
@visibleForTesting
List<String>? browserLaunchCommand(BrowserKind kind, String url,
    {required String os}) {
  switch (os) {
    case 'macos':
      final String app = switch (kind) {
        BrowserKind.chrome => 'Google Chrome',
        BrowserKind.edge => 'Microsoft Edge',
        BrowserKind.brave => 'Brave Browser',
        BrowserKind.vivaldi => 'Vivaldi',
        BrowserKind.opera => 'Opera',
      };
      return <String>['open', '-a', app, url];
    case 'linux':
      final String exe = switch (kind) {
        BrowserKind.chrome => 'google-chrome',
        BrowserKind.edge => 'microsoft-edge',
        BrowserKind.brave => 'brave-browser',
        BrowserKind.vivaldi => 'vivaldi',
        BrowserKind.opera => 'opera',
      };
      return <String>[exe, url];
  }
  return null;
}

/// Windows：经 App Paths（先 HKCU 后 HKLM）找到浏览器可执行文件。找不到返回
/// null——不走 `cmd /c start`，那条路在浏览器没装时会弹系统错误框。
Future<String?> _resolveWindowsBrowserExe(BrowserKind kind) async {
  const String appPaths =
      r'\Software\Microsoft\Windows\CurrentVersion\App Paths\';
  for (final String hive in <String>['HKCU', 'HKLM']) {
    final ProcessResult r = await Process.run('reg', <String>[
      'query',
      '$hive$appPaths${_windowsExeName(kind)}',
      '/ve',
    ]);
    if (r.exitCode != 0) continue;
    final String? exe = parseWindowsRegDefaultValue('${r.stdout}');
    if (exe != null && File(exe).existsSync()) return exe;
  }
  return null;
}

/// 尝试用 [kind] 浏览器直接打开它的扩展管理页。返回 false = 没能启动（未安装 /
/// 平台不支持），调用方提示用户复制地址手动打开。
Future<bool> tryOpenBrowserExtensionsPage(BrowserKind kind) async {
  final String url = browserExtensionsPageUrl(kind);
  try {
    if (Platform.isWindows) {
      final String? exe = await _resolveWindowsBrowserExe(kind);
      if (exe == null) return false;
      // detached：浏览器没在跑时它就是新进程本身，不能等它退出。
      await Process.start(exe, <String>[url], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isMacOS) {
      final List<String> cmd = browserLaunchCommand(kind, url, os: 'macos')!;
      // `open` 立即返回，退出码就是「找没找到这个 App」。
      final ProcessResult r = await Process.run(cmd.first, cmd.sublist(1));
      return r.exitCode == 0;
    }
    if (Platform.isLinux) {
      final List<String> cmd = browserLaunchCommand(kind, url, os: 'linux')!;
      await Process.start(cmd.first, cmd.sublist(1),
          mode: ProcessStartMode.detached);
      return true;
    }
  } on ProcessException {
    return false;
  }
  return false;
}
