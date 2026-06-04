# 全平台自动更新 · Phase 1（更新器重构 + Windows）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `UpdateChecker` 的 Android-only 硬门控重构成按平台策略，并端到端打通 Windows 应用内自动更新（CI 产出 Inno Setup 安装器 → 应用内检查/下载/运行安装器/重启）。

**Architecture:** 新增 `PlatformUpdater` 抽象（每平台一个 `selectAsset` 选包 + `apply` 安装）。`UpdateChecker` 保留共享的 GitHub 拉取/版本比较/代理回退/下载浮层，把「选哪个 asset」和「下载后做什么」委托给当前平台的 updater。桌面 apply 用纯 Dart `dart:io Process`，无需原生通道。设置网关从「仅 Android」演进为「按平台能力」（检查到处可用、自动安装仅支持自装的平台）。

**Tech Stack:** Dart/Flutter 3.44.0、`dart:io`（HttpClient/Process/Platform）、`device_info_plus`（Android ABI）、Inno Setup（Windows 安装器）、GitHub Actions（打包上传）。

设计依据：`docs/specs/2026-06-04-all-platform-auto-update-design.md`。

---

## 文件结构

| 文件 | 责任 | 动作 |
|---|---|---|
| `hibiki/lib/src/utils/misc/platform_updater.dart` | `PlatformUpdater` 抽象 + Android/Windows/Unsupported 实现 + 平台能力 helper + 工厂 | 新建 |
| `hibiki/lib/src/utils/misc/update_checker.dart` | 共享检查/下载/浮层，委托 updater 选包与 apply | 改 |
| `hibiki/lib/src/settings/settings_schema.dart` | 更新设置网关按平台能力 | 改 |
| `hibiki/test/utils/misc/platform_updater_test.dart` | selectAsset / 能力 / 工厂分发单测 | 新建 |
| `hibiki/test/settings/update_settings_android_only_guard_test.dart` | BUG-013 守卫演进为「按能力」 | 改 |
| `hibiki/windows/installer/hibiki.iss` | Inno Setup 安装器脚本 | 新建 |
| `.github/workflows/release-desktop.yml` | release 发布时打包+上传桌面 asset（本期仅 Windows job） | 新建 |

---

## Task 1: PlatformUpdater 抽象 + selectAsset（Android/Windows/Unsupported）

**Files:**
- Create: `hibiki/lib/src/utils/misc/platform_updater.dart`
- Test: `hibiki/test/utils/misc/platform_updater_test.dart`

设计要点：
- `selectAsset` 接收 release 的 `assets`（GitHub JSON 的 list，每项含 `name` / `browser_download_url`），返回下载 URL 或 null。
- Android 选包要按设备 ABI，ABI 探测是异步且依赖平台通道 → 用可注入的 `abiProvider` 让单测无需真机。
- Windows 选包是纯字符串后缀匹配 → 直接可测。
- `Unsupported`（iOS/mac/Linux 本期）：`supportsUpdateCheck=true`（能「检查→打开发布页」）、`supportsInAppInstall=false`、`selectAsset` 恒 null（上层回退打开页面）。

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/utils/misc/platform_updater_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';

List<Map<String, dynamic>> _assets(List<String> names) => names
    .map((String n) => <String, dynamic>{
          'name': n,
          'browser_download_url': 'https://example.com/$n',
        })
    .toList();

void main() {
  group('WindowsUpdater.selectAsset', () {
    test('picks the -windows-setup.exe asset', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
        'hibiki-0.4.2-linux-x86_64.AppImage',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-windows-setup.exe');
    });

    test('returns null when no windows asset present', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await u
          .selectAsset(_assets(<String>['hibiki-0.4.2-arm64-v8a.apk']));
      expect(url, isNull);
    });

    test('supports update check and in-app install', () {
      final WindowsUpdater u = WindowsUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isTrue);
    });
  });

  group('AndroidUpdater.selectAsset', () {
    test('matches device ABI', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-arm64-v8a.apk');
    });

    test('falls back to first apk when no ABI match', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['x86_64'],
      );
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-armeabi-v7a.apk');
    });

    test('returns null when no apk asset', () async {
      final AndroidUpdater u =
          AndroidUpdater(abiProvider: () async => <String>[]);
      final String? url = await u
          .selectAsset(_assets(<String>['hibiki-0.4.2-windows-setup.exe']));
      expect(url, isNull);
    });
  });

  group('UnsupportedUpdater', () {
    test('checks but cannot install; selectAsset always null', () async {
      final UnsupportedUpdater u = UnsupportedUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isFalse);
      expect(await u.selectAsset(_assets(<String>['x.zip'])), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: FAIL（`platform_updater.dart` 不存在 / 类未定义）。

- [ ] **Step 3: 写最小实现**

```dart
// hibiki/lib/src/utils/misc/platform_updater.dart
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart'; // ErrorLogService

/// 每平台的更新策略：选包（[selectAsset]）+ 安装（[apply]）。
/// 共享的 GitHub 拉取/版本比较/下载浮层仍在 UpdateChecker。
abstract class PlatformUpdater {
  /// 当前平台是否支持「检查更新」（iOS/未实现桌面也为 true，只是 apply=打开发布页）。
  bool get supportsUpdateCheck;

  /// 当前平台是否支持「应用内安装」（决定是否显示自动安装、是否走下载→apply）。
  bool get supportsInAppInstall;

  /// 从 release 的 [assets]（每项含 name / browser_download_url）挑本平台可安装包的
  /// 下载 URL；null = 无适配包（上层回退打开发布页）。
  Future<String?> selectAsset(List<Map<String, dynamic>> assets);

  /// 应用已下载到 [file] 的更新。仅在 [supportsInAppInstall] 为 true 时被调用。
  Future<void> apply(File file, String version);
}

/// 从 asset map 安全取出可下载的 (name, url)。
Iterable<(String, String)> _downloadable(
    List<Map<String, dynamic>> assets) sync* {
  for (final Map<String, dynamic> a in assets) {
    final String name = a['name'] as String? ?? '';
    final String? url = a['browser_download_url'] as String?;
    if (name.isEmpty || url == null) continue;
    yield (name, url);
  }
}

class AndroidUpdater extends PlatformUpdater {
  AndroidUpdater({Future<List<String>> Function()? abiProvider})
      : _abiProvider = abiProvider ?? _defaultAbis;

  final Future<List<String>> Function() _abiProvider;

  static Future<List<String>> _defaultAbis() async {
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      return info.supportedAbis;
    } catch (e, s) {
      ErrorLogService.instance.log('PlatformUpdater.getAbi', e, s);
      return <String>[];
    }
  }

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async {
    final List<String> abis = await _abiProvider();
    final List<String> abiTags =
        abis.map((String a) => a.replaceAll('_', '-')).toList();
    String? fallback;
    for (final (String name, String url) in _downloadable(assets)) {
      if (!name.endsWith('.apk')) continue;
      if (abiTags.any(name.contains)) return url;
      fallback ??= url;
    }
    return fallback;
  }

  @override
  Future<void> apply(File file, String version) async {
    await AndroidInstaller.install(file.path);
  }
}

class WindowsUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => true;

  @override
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async {
    for (final (String name, String url) in _downloadable(assets)) {
      if (name.endsWith('-windows-setup.exe')) return url;
    }
    return null;
  }

  @override
  Future<void> apply(File file, String version) async {
    await WindowsInstaller.runAndExit(file.path);
  }
}

/// iOS + 本期未实现的 macOS/Linux：可检查但不能自装。
class UnsupportedUpdater extends PlatformUpdater {
  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => false;

  @override
  Future<String?> selectAsset(List<Map<String, dynamic>> assets) async => null;

  @override
  Future<void> apply(File file, String version) async {
    throw StateError('UnsupportedUpdater.apply must not be called');
  }
}

// ── 安装器（Task 3/4 落地真实实现，本 Task 先占位让 selectAsset 测试编译通过）──
class AndroidInstaller {
  static Future<void> install(String apkPath) async {}
}

class WindowsInstaller {
  static Future<void> runAndExit(String installerPath) async {}
}
```

> 占位 `AndroidInstaller` / `WindowsInstaller` 在 Task 3/4 被真实实现替换（同文件）。
> 本 Task 的测试不调用 `apply`，故占位不影响绿。

- [ ] **Step 4: 跑测试确认通过**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: PASS（9 个用例全绿）。

- [ ] **Step 5: 格式化 + 提交**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/dart format lib/src/utils/misc/platform_updater.dart test/utils/misc/platform_updater_test.dart
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/utils/misc/platform_updater.dart hibiki/test/utils/misc/platform_updater_test.dart
git commit -m "feat(update): PlatformUpdater strategy + selectAsset (android/windows)"
```

---

## Task 2: 平台能力 helper + 工厂分发

**Files:**
- Modify: `hibiki/lib/src/utils/misc/platform_updater.dart`（追加顶层函数）
- Test: `hibiki/test/utils/misc/platform_updater_test.dart`（追加）

工厂用 `dart:io Platform`（宿主）分发；单测只能验证当前宿主返回的类型。能力 helper 供
设置网关与 UpdateChecker 复用，是「哪些平台能自装」的单一真相源。

- [ ] **Step 1: 追加失败测试**

```dart
// 追加到 platform_updater_test.dart 的 main() 内（文件顶部已 import 'dart:io';）
  group('factory + capability helpers', () {
    test('updaterForCurrentPlatform returns a supported-check updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(u.supportsUpdateCheck, isTrue);
    });

    test('capability helpers agree with the current updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(platformSupportsUpdateCheck(), u.supportsUpdateCheck);
      expect(platformSupportsInAppInstall(), u.supportsInAppInstall);
    });

    test('in-app install capability is android or windows in phase 1', () {
      final bool expected = Platform.isAndroid || Platform.isWindows;
      expect(platformSupportsInAppInstall(), expected);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: FAIL（`updaterForCurrentPlatform` / helper 未定义）。

- [ ] **Step 3: 追加实现**

```dart
// 追加到 platform_updater.dart 顶层（abstract class 之前或之后均可）
/// 本期支持「应用内安装」的平台集合（单一真相源；macOS/Linux 在各自阶段加入）。
bool platformSupportsInAppInstall() => Platform.isAndroid || Platform.isWindows;

/// 所有平台都至少支持「检查更新 → 打开发布页」。
bool platformSupportsUpdateCheck() => true;

PlatformUpdater updaterForCurrentPlatform() {
  if (Platform.isAndroid) return AndroidUpdater();
  if (Platform.isWindows) return WindowsUpdater();
  return UnsupportedUpdater();
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: PASS。

- [ ] **Step 5: 格式化 + 提交**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/dart format lib/src/utils/misc/platform_updater.dart test/utils/misc/platform_updater_test.dart
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/utils/misc/platform_updater.dart hibiki/test/utils/misc/platform_updater_test.dart
git commit -m "feat(update): platform capability helpers + updater factory"
```

---

## Task 3: UpdateChecker 委托 updater（选包 + 下载文件名 + Android apply 抽出）

**Files:**
- Modify: `hibiki/lib/src/utils/misc/update_checker.dart`
- Modify: `hibiki/lib/src/utils/misc/platform_updater.dart`（落地 `AndroidInstaller`）

把 `_check` 的 Android 硬门控、ABI 选包、`_downloadAndInstall` 的硬编码 `installApk` 与
`.apk` 文件名替换为 updater 委托。下载文件名按 asset URL 的扩展名生成。

> 实现前先读现状：`update_checker.dart` 的 `_check`（约 62-149 行）、`_downloadAndInstall`
> （约 247-325 行）、`_cleanupOldApks`（约 40-60 行）、`_showUpdateDialog`（约 203-221 行）。
> 下面给出精确替换；行号以实际文件为准。

- [ ] **Step 1: 落地 AndroidInstaller（替换 Task 1 占位）**

在 `platform_updater.dart` 把占位 `class AndroidInstaller {...}` 替换为：

```dart
/// Android 原生安装：仅 Android 注册的 installApk 通道（FileProvider + ACTION_VIEW，
/// 带 HBK-AUDIT-058 路径校验，见 MainActivity.java）。
class AndroidInstaller {
  static Future<void> install(String apkPath) async {
    await HibikiChannels.update.invokeMethod('installApk', <String, String>{
      'path': apkPath,
    });
  }
}
```

（`HibikiChannels` 来自 Task 1 已加的 `import '.../channel_constants.dart';`。）

- [ ] **Step 2: 改 `_check` 门控 + 选包（update_checker.dart）**

替换 A（原 `if (!Platform.isAndroid) return;` + `if (neverRemind && !autoInstall) return;`）:
```dart
    final PlatformUpdater updater = updaterForCurrentPlatform();
    if (!updater.supportsUpdateCheck) return;
    final bool canInstall = updater.supportsInAppInstall;
    // 不能自装的平台忽略 autoInstall（无意义），但仍可「检查→打开发布页」。
    if (neverRemind && !(canInstall && autoInstall)) return;
```

替换 B（原整段 ABI 选包：`String? apkUrl; String? fallbackApkUrl;` 起，到
`apkUrl ??= fallbackApkUrl;` 止，含 `supportedAbis`/`abiTags`/`for (final asset...)`）:
```dart
      final List<Map<String, dynamic>> assetMaps = assets
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final String? downloadUrl = await updater.selectAsset(assetMaps);
```
（保留上方 `final releaseBody = ...` 与 `final assets = json['assets'] ...` 两行。）

替换 C（原 `if (apkUrl == null) {...}` 回退块 + `if (!context.mounted) return;` +
`if (autoInstall) { _downloadAndInstall(...) } else { _showUpdateDialog(...) }`）:
```dart
      // 无适配本平台的 asset（iOS / 未实现桌面 / 该 release 没传本平台包）→ 打开发布页。
      if (downloadUrl == null) {
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null && context.mounted) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
        return;
      }
      if (!context.mounted) return;
      if (canInstall && autoInstall) {
        _downloadAndInstall(context, downloadUrl, tagName, updater);
      } else if (canInstall) {
        _showUpdateDialog(context, tagName, releaseBody, downloadUrl, updater);
      } else {
        // 能检查但不能自装（本期 iOS/mac/Linux）：弹「前往下载」打开发布页。
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
      }
```

- [ ] **Step 3: `_showUpdateDialog` / `_downloadAndInstall` 带 updater + 通用文件名**

`_showUpdateDialog` 增末参 `PlatformUpdater updater`，其 `onPrimary` 调用改：
```dart
          _downloadAndInstall(context, downloadUrl, version, updater);
```

`_downloadAndInstall` 签名改为：
```dart
  static Future<void> _downloadAndInstall(
    BuildContext context,
    String url,
    String version,
    PlatformUpdater updater,
  ) async {
```
方法体内：
1. 把 `final apkFile = File('${cacheDir.path}/hibiki-$version.apk');` 改为：
```dart
      final String ext = _extOf(url);
      final File outFile = File('${cacheDir.path}/hibiki-$version$ext');
```
2. 方法内其余 `apkFile` 全改名 `outFile`。
3. 安装调用（原 `await HibikiChannels.update.invokeMethod('installApk', {'path': apkFile.path});`）改为：
```dart
      await updater.apply(outFile, version);
```

文件内新增顶层 helper：
```dart
String _extOf(String url) {
  final String path = Uri.parse(url).path;
  final int slash = path.lastIndexOf('/');
  final String name = slash >= 0 ? path.substring(slash + 1) : path;
  final int dot = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot) : '';
}
```

- [ ] **Step 4: 泛化 `_cleanupOldApks` 多扩展名**

替换其文件筛选段（原 `if (f is! File || !f.path.endsWith('.apk')) continue;` 到
`final apkVersion = name.substring(prefix.length, name.length - 4);`）:
```dart
        if (f is! File) continue;
        final String name = f.uri.pathSegments.last;
        if (!name.startsWith(prefix)) continue;
        const List<String> exts = <String>['.apk', '.exe', '.AppImage', '.zip'];
        final String ext =
            exts.firstWhere((String e) => name.endsWith(e), orElse: () => '');
        if (ext.isEmpty) continue;
        final String fileVersion =
            name.substring(prefix.length, name.length - ext.length);
```
并把后续 `if (!_isNewer(apkVersion, currentVersion))` 改 `_isNewer(fileVersion, currentVersion)`。

- [ ] **Step 5: import 调整**

`update_checker.dart` 顶部加：
```dart
import 'package:hibiki/src/utils/misc/platform_updater.dart';
```
若 `device_info_plus` import 在 update_checker 内已无引用（ABI 逻辑迁走），删除它。
`channel_constants` 若 update_checker 内不再直接用 `HibikiChannels`（installApk 迁走），
删除其 import。`dart:io` 若 `Platform` 仍被其它分支用则保留，否则删。
（删前用 analyze 确认无未使用 import 报错。）

- [ ] **Step 6: analyze + 单测**

Run:
```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter analyze --no-pub lib/src/utils/misc/update_checker.dart lib/src/utils/misc/platform_updater.dart
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart
```
Expected: analyze 无 issue；单测 PASS。

- [ ] **Step 7: 格式化 + 提交**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/dart format lib/src/utils/misc/update_checker.dart lib/src/utils/misc/platform_updater.dart
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/utils/misc/update_checker.dart hibiki/lib/src/utils/misc/platform_updater.dart
git commit -m "refactor(update): delegate asset-select + apply to PlatformUpdater"
```

---

## Task 4: WindowsUpdater.apply（启动安装器 + 退出）

**Files:**
- Modify: `hibiki/lib/src/utils/misc/platform_updater.dart`（落地 `WindowsInstaller`）
- Test: `hibiki/test/utils/misc/platform_updater_test.dart`（命令构造纯函数单测）

Windows 无法覆盖运行中的 exe，故策略 = 启动 Inno Setup 安装器（分离进程）后**退出本进程**，
由安装器关旧实例（AppMutex）、替换文件、`[Run] postinstall` 重启。`apply` 含 `exit(0)` 和
`Process.start` 的真实副作用无法单测 → 抽纯函数 `windowsInstallerArgs` 单测，副作用部分
由 Task 5 守卫 + Task 8 真机覆盖。

- [ ] **Step 1: 写失败测试（命令构造纯函数）**

```dart
// 追加到 platform_updater_test.dart 的 main() 内
  group('windowsInstallerArgs', () {
    test('runs installer very-silently and skips initial prompt', () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');
      expect(args, contains('/VERYSILENT'));
      expect(args, contains('/SP-'));
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: FAIL（`windowsInstallerArgs` 未定义）。

- [ ] **Step 3: 落地 WindowsInstaller（替换 Task 1 占位）**

在 `platform_updater.dart` 把占位 `class WindowsInstaller {...}` 替换为：

```dart
/// Inno Setup 静默安装参数：抑制向导、跳过初始提示；安装器脚本负责关旧实例 + 重启。
List<String> windowsInstallerArgs(String installerPath) =>
    <String>['/VERYSILENT', '/SP-'];

class WindowsInstaller {
  /// 启动安装器（分离进程）后退出本进程，让安装器替换运行中的 exe 并重启 app。
  static Future<void> runAndExit(String installerPath) async {
    await Process.start(
      installerPath,
      windowsInstallerArgs(installerPath),
      mode: ProcessStartMode.detached,
    );
    // 给安装器拿到文件锁的瞬间；随后退出本进程，让其替换 hibiki.exe。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/utils/misc/platform_updater_test.dart`
Expected: PASS。

- [ ] **Step 5: 格式化 + 提交**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/dart format lib/src/utils/misc/platform_updater.dart test/utils/misc/platform_updater_test.dart
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/utils/misc/platform_updater.dart hibiki/test/utils/misc/platform_updater_test.dart
git commit -m "feat(update): WindowsUpdater apply via Inno Setup installer + exit"
```

---

## Task 5: 设置网关按平台能力演进 + BUG-013 守卫演进

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema.dart`
- Modify: `hibiki/test/settings/update_settings_android_only_guard_test.dart`

> 前置：本 Task 演进 BUG-013 的修复。BUG-013 当前实现（在 develop 上，提交
> `b83538d40`）给更新 section 加了 `visible: (_) => Platform.isAndroid` 且 summary 为
> `Platform.isAndroid ? t.section_update : null`。本 Task 把二者改为按能力 helper。
> 若执行分支尚未含 BUG-013 提交，先确认 `_systemDestination()` 当前形态再套用替换。

更新分区从「仅 Android 可见」改为「按平台能力」：分区在 `platformSupportsUpdateCheck()`
（恒真，所有平台显示「更新」分区）；自动安装开关仅在 `platformSupportsInAppInstall()`
（本期 Android+Windows）显示。

- [ ] **Step 1: 改 settings_schema.dart**

顶部加 `import 'package:hibiki/src/utils/misc/platform_updater.dart';`。

summary（原 `summary: Platform.isAndroid ? t.section_update : null,`）改：
```dart
    summary: t.section_update,
```

section 网关（原 `visible: (_) => Platform.isAndroid,` 及其上方 BUG-013 注释）改：
```dart
        // 更新分区在所有平台可见（至少能「检查→打开发布页」）；自动安装开关
        // 仅在支持应用内安装的平台显示（platformSupportsInAppInstall，见
        // platform_updater.dart 单一真相源）。
        visible: (_) => platformSupportsUpdateCheck(),
```

「自动安装」开关（`id: 'system.update_auto_install'`）加 item 级网关，紧接 `icon:` 后：
```dart
            visible: (_) => platformSupportsInAppInstall(),
```

- [ ] **Step 2: 改守卫测试（演进 BUG-013）**

把 `test/settings/update_settings_android_only_guard_test.dart` 整体替换为：

```dart
import 'package:flutter_test/flutter_test.dart';

/// BUG-013 演进（全平台自动更新 Phase 1）：更新分区不再仅 Android。
/// 不变量：分区按 platformSupportsUpdateCheck()（恒真）可见；自动安装开关按
/// platformSupportsInAppInstall()（本期 Android+Windows）网关；数据侧 UpdateChecker
/// 不再硬门控 Android，而是按 updater.supportsUpdateCheck。
void main() {
  test('update section gated by capability helper, not Platform.isAndroid', () {
    final String src =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    final String systemDest = _functionSource(
      src,
      'SettingsDestination _systemDestination() {',
      'String _selectedUpdateChannel(',
    );
    expect(systemDest,
        contains('visible: (_) => platformSupportsUpdateCheck()'));
    expect(systemDest.contains('visible: (_) => Platform.isAndroid'), isFalse,
        reason: '更新分区不应再硬绑 Android（已扩展到全平台）');
    final int autoIdx = systemDest.indexOf("id: 'system.update_auto_install'");
    expect(autoIdx, isNonNegative);
    expect(systemDest,
        contains('visible: (_) => platformSupportsInAppInstall()'),
        reason: '自动安装开关必须按 platformSupportsInAppInstall 网关');
  });

  test('UpdateChecker no longer hard-returns on non-Android', () {
    final String src =
        File('lib/src/utils/misc/update_checker.dart').readAsStringSync();
    expect(src.contains('if (!Platform.isAndroid) return;'), isFalse,
        reason: '检查流程已按 updater.supportsUpdateCheck 门控');
    expect(src, contains('updaterForCurrentPlatform()'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
```
> 文件顶部需 `import 'dart:io';`（用 `File`）。补上。

- [ ] **Step 3: 跑守卫 + 覆盖测试**

Run:
```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/settings/update_settings_android_only_guard_test.dart test/settings/settings_schema_coverage_test.dart
```
Expected: PASS。覆盖测试注意：更新分区现在在非 Android/Windows 宿主（CI linux/mac）也渲染
通道 + 不再提醒（自动安装被 item 网关掉）。若覆盖测试报新增 STILL-UNACCOUNTED（如更新通道
现被遍历到且无探针），按其提示把对应项保留/补登记进 `kCoveredElsewhere`（`system/Update
Channel`、`system/Don't remind me about updates` 已在；`system/Auto-install updates` 在
非 Android/Windows 宿主不被遍历，登记保留无害）。

- [ ] **Step 4: analyze + 全量 settings 测试**

Run:
```bash
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter analyze --no-pub lib/src/settings/settings_schema.dart
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub test/settings/
```
Expected: analyze 无 issue；settings 测试全绿。

- [ ] **Step 5: 格式化 + 提交**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/dart format lib/src/settings/settings_schema.dart test/settings/update_settings_android_only_guard_test.dart
cd /d/APP/vs_claude_code/hibiki
git add hibiki/lib/src/settings/settings_schema.dart hibiki/test/settings/update_settings_android_only_guard_test.dart
git commit -m "feat(settings): gate update UI by platform capability (BUG-013 evolved)"
```

---

## Task 6: Inno Setup 安装器脚本 + 单实例互斥量

**Files:**
- Create: `hibiki/windows/installer/hibiki.iss`
- Modify: `hibiki/windows/runner/main.cpp`

产出 `hibiki-<v>-windows-setup.exe`：安装 `flutter build windows --release` 的产物目录，
关运行中实例（AppMutex），安装后重启。无 GUI 单测——CI 编译验证（Task 7）+ 真机（Task 8）。

- [ ] **Step 1: 写 Inno Setup 脚本**

```iss
; hibiki/windows/installer/hibiki.iss
; 由 CI 用 ISCC 编译；AppVersion / SourceDir / OutputDir 由命令行 /D 传入。
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

[Setup]
AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}
AppName=Hibiki
AppVersion={#AppVersion}
AppPublisher=Hibiki
DefaultDirName={localappdata}\Hibiki
DefaultGroupName=Hibiki
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=hibiki-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
AppMutex=HibikiSingleInstanceMutex

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hibiki"; Filename: "{app}\hibiki.exe"
Name: "{userdesktop}\Hibiki"; Filename: "{app}\hibiki.exe"

[Run]
Filename: "{app}\hibiki.exe"; Description: "启动 Hibiki"; Flags: nowait postinstall
```

- [ ] **Step 2: Windows runner 创建命名互斥量**

读 `hibiki/windows/runner/main.cpp`，在 `wWinMain` 开头（attach console 相关之后、创建窗口
之前）加：
```cpp
  // Inno Setup 静默更新靠这个命名互斥量检测并关闭运行中的实例（见 hibiki.iss AppMutex）。
  ::CreateMutexW(nullptr, FALSE, L"HibikiSingleInstanceMutex");
```
确认文件已 `#include <windows.h>`（Flutter Windows runner 默认含；若无则补）。该 mutex 仅
供被检测，不做单实例逻辑，不检查 `ERROR_ALREADY_EXISTS`。

- [ ] **Step 3: 编译验证（本地有 Inno Setup 时）**

```bash
# Windows，装 Inno Setup 6 后：
"/c/Program Files (x86)/Inno Setup 6/ISCC.exe" //DAppVersion=0.4.2 hibiki/windows/installer/hibiki.iss
```
Expected: 生成 `hibiki/build/installer/hibiki-0.4.2-windows-setup.exe`。无本地 Inno 则
留 Task 7 CI 验证。可选源码守卫：`main.cpp` 含 `HibikiSingleInstanceMutex` 且 `.iss` 的
`AppMutex` 同名。

- [ ] **Step 4: 提交**

```bash
cd /d/APP/vs_claude_code/hibiki
git add hibiki/windows/installer/hibiki.iss hibiki/windows/runner/main.cpp
git commit -m "build(windows): Inno Setup installer + single-instance mutex"
```

---

## Task 7: CI Windows 打包 + 上传

**Files:**
- Create: `.github/workflows/release-desktop.yml`

release 发布时（与现 `release.yml` 并列，互不阻塞）构建 Windows release、编译 Inno Setup、
上传 `hibiki-<v>-windows-setup.exe`。可选签名留口（有 secret 才签）。

- [ ] **Step 1: 写 workflow**

```yaml
# .github/workflows/release-desktop.yml
name: Build Desktop Release Artifacts

on:
  release:
    types: [published]
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.41.6'
      - name: Flutter pub get
        working-directory: hibiki
        run: flutter pub get
      - name: Apply pub cache patches
        shell: bash
        run: |
          chmod +x ci/apply-patches.sh
          bash ci/apply-patches.sh
      - name: Build Windows release
        working-directory: hibiki
        run: flutter build windows --release
      - name: Read version
        id: ver
        shell: bash
        run: |
          V=$(grep '^version:' hibiki/pubspec.yaml | sed 's/version: *//;s/+.*//')
          echo "version=$V" >> "$GITHUB_OUTPUT"
      - name: Compile installer (Inno Setup)
        shell: pwsh
        run: |
          $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
          if (-not (Test-Path $iscc)) { choco install innosetup -y; $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
          & "$iscc" "/DAppVersion=${{ steps.ver.outputs.version }}" `
            "/DSourceDir=$PWD\hibiki\build\windows\x64\runner\Release" `
            "/DOutputDir=$PWD\hibiki\build\installer" `
            "hibiki\windows\installer\hibiki.iss"
      - name: Check signing availability
        id: signcheck
        shell: bash
        env:
          CERT: ${{ secrets.WINDOWS_CERT_BASE64 }}
        run: |
          if [ -n "$CERT" ]; then echo "have=true" >> "$GITHUB_OUTPUT"; else echo "have=false" >> "$GITHUB_OUTPUT"; fi
      - name: Sign installer (optional)
        if: steps.signcheck.outputs.have == 'true'
        env:
          WINDOWS_CERT_BASE64: ${{ secrets.WINDOWS_CERT_BASE64 }}
          WINDOWS_CERT_PASSWORD: ${{ secrets.WINDOWS_CERT_PASSWORD }}
        shell: pwsh
        run: |
          [IO.File]::WriteAllBytes("$PWD\cert.pfx", [Convert]::FromBase64String($env:WINDOWS_CERT_BASE64))
          $st = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" | Select-Object -Last 1).FullName
          & "$st" sign /fd SHA256 /f "$PWD\cert.pfx" /p $env:WINDOWS_CERT_PASSWORD /tr http://timestamp.digicert.com /td SHA256 "$PWD\hibiki\build\installer\hibiki-${{ steps.ver.outputs.version }}-windows-setup.exe"
      - name: Upload to release
        if: github.event_name == 'release'
        uses: softprops/action-gh-release@v2
        with:
          files: hibiki/build/installer/hibiki-*-windows-setup.exe
```

- [ ] **Step 2: 手动触发验证（不发 release）**

push 含本 workflow 的分支后，在 GitHub Actions 用 `workflow_dispatch` 跑
`release-desktop.yml`，确认：`flutter build windows --release` 成功；ISCC 产出
`hibiki-<v>-windows-setup.exe`；未配 cert 时跳过签名不报错；artifact 名符合契约。
（需 push 到 GitHub；不便时标记待办交用户触发。）

- [ ] **Step 3: 提交**

```bash
cd /d/APP/vs_claude_code/hibiki
git add .github/workflows/release-desktop.yml
git commit -m "ci(release): build + upload Windows installer on release"
```

---

## Task 8: Windows 真机端到端验证（设备验证纪律）

**Files:** 无（验证 + 记录）

应用内 `Process` 启动安装器 / 替换 exe / 重启不可单测，必须真机走原始路径（CLAUDE.md 纪律）。

- [ ] **Step 1: 准备两版本** — 装 `0.4.1` 安装器；CI/本地 ISCC 出 `0.4.2`（临时抬 pubspec
  version 到 `0.4.2+33` 出测试包）。
- [ ] **Step 2: 走更新路径** — 启动 0.4.1 → 设置确认「更新」分区可见且「自动安装」开关存在
  → 开 app 自动 `scheduleCheck` → 更新对话框 → 下载 → 进度浮层 → 安装器静默运行 → app 退出
  → 替换 → 以 0.4.2 重启。截图/录屏存 `.codex-test/`。
- [ ] **Step 3: 边界** — 未签名 SmartScreen「仍要运行」可继续；下载失败走代理回退；
  `neverRemind` 后不再弹；`autoInstall` 关时只弹对话框不自动装。
- [ ] **Step 4: 记录** — 结果记入设计文档 Phase 1 小节；真机通过后方可声明 Phase 1 完成。

---

## Self-Review（计划对设计的覆盖）

- 设计 §2 asset 契约 → Task 1（selectAsset 后缀）、Task 7（CI 产出该名）。✅
- §3.1 PlatformUpdater 接口 → Task 1/2（mac/Linux 用 UnsupportedUpdater 占位，符合分阶段）。✅
- §3.2 共享流程改造 → Task 3。✅
- §3.3 不变量（iOS 不执行外部二进制 / 失败不吞 / 下载源校验）→ Task 1（UnsupportedUpdater.apply
  抛错）、Task 3（沿用现有 try/catch + ErrorLogService + SnackBar + 下载到自家临时目录）。✅
- §4 CI Windows 打包 → Task 6/7（mac/Linux job 留各自阶段）。✅
- §5 macOS 去沙盒 → 不在本期（Phase 3）。✅
- §6 iOS → 本期 UnsupportedUpdater 给「检查→打开发布页」；文案演进留 Phase 4。✅
- §7 设置网关演进 → Task 5。✅
- §8 测试分层 → Task 1/2/4（单测）、Task 5（守卫）、Task 8（真机）。✅
- 类型一致性：`selectAsset` 全程 `Future<String?>`；`apply(File,String)` 一致；helper
  `platformSupportsInAppInstall()`/`platformSupportsUpdateCheck()` Task 2 定义、Task 3/5 引用；
  `windowsInstallerArgs`/`WindowsInstaller.runAndExit`/`AndroidInstaller.install` 贯穿
  Task 1/3/4 命名一致。✅
- 占位扫描：无 TODO/TBD；Task 1 占位类在 Task 3/4 明确替换并说明。✅

## 范围说明（YAGNI）

本计划只做 Phase 1（更新器重构 + Windows 端到端）。macOS（去沙盒 + zip 替换）、Linux
（AppImage）、iOS（文案演进）各自后续单独计划，互不阻塞。
