# 桌面端换图标（Win/Mac 本地）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> 派生子代理一律 `model: "opus"`（本仓库规则）。每个 Dart 任务跑 `dart format .` + `flutter test`（工具链 Flutter 3.44.0，`flutter` 不在 PATH 时用 `/d/flutter_sdk/flutter_extracted/flutter/bin/flutter`）。原生任务按 [docs/agent/integration-testing.md] 设备复测。

**Goal:** 让 Windows / macOS 能切换运行中 App 的图标（预设 default/full/minimal + 用户自选图片），每次启动重套用持久；不跨设备同步，不改磁盘文件图标。

**Architecture:** Dart 侧集中到新 `AppIconService`（纯函数缩放 + `app.hibiki/icon_switch` channel 封装 + 自选图本地文件管理）；设置页门控放开到 Win/Mac；`main.dart` 启动重套用。原生三端实现 `applyIcon`：Windows `WM_SETICON`、macOS `NSApp.applicationIconImage`、Android 适配现有 `IconSwitchHelper`。预设选择存在现有 SharedPreferences `app_icon_preset`（零迁移），自选图存本地文件 `app_icon_custom.png`。

**Tech Stack:** Flutter 3.44.0 / Dart；`image:^4.3.0`（缩放/PNG 编码）；`file_picker:^8.0.0`（桌面选图）；`path_provider`（app support 目录）；Windows C++ runner（GDI+ / WinAPI）；macOS Swift runner（AppKit）；Android Java。

设计源文档：`docs/specs/2026-06-04-desktop-icon-switch-design.md`。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `hibiki/lib/src/utils/misc/app_icon_service.dart` | 缩放纯函数 + channel 封装 + 自选文件 + 启动回落决策 | 新建 |
| `hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart` | 门控放开 Win/Mac + 桌面自选路径 + 调 AppIconService | 改 |
| `hibiki/lib/main.dart` | 桌面启动重套用 | 改 |
| `hibiki/windows/runner/{flutter_window.cpp,flutter_window.h}` | 注册 `icon_switch` channel + applyIcon 实现 | 改 |
| `hibiki/windows/runner/{Runner.rc,resource.h}` + `resources/*.ico` | 预设 .ico 资源 | 改/新增 |
| `hibiki/macos/Runner/MainFlutterWindow.swift` | 注册 channel + applicationIconImage | 改 |
| `hibiki/android/.../IconSwitchHelper.java` + `MainActivity.java` | `applyIcon` 适配现有 alias/shortcut | 改 |
| `hibiki/pubspec.yaml` | 确保 full/minimal 预览图入桌面包 | 核对 |
| `hibiki/test/utils/app_icon_service_test.dart` | 缩放 + 回落 单测 | 新建 |
| `hibiki/test/pages/misc_settings_icon_test.dart` | 设置页 channel 调用 + 源码守卫 | 新建 |

---

## Task 1: AppIconService —— 缩放纯函数 `resizeIconPng`

**Files:**
- Create: `hibiki/lib/src/utils/misc/app_icon_service.dart`
- Test: `hibiki/test/utils/app_icon_service_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/utils/app_icon_service_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hibiki/src/utils/misc/app_icon_service.dart';

void main() {
  test('resizeIconPng 把大图缩到 <=256 并保持长宽比', () {
    final src = img.Image(width: 512, height: 400);
    img.fill(src, color: img.ColorRgb8(10, 20, 30));
    final input = Uint8List.fromList(img.encodePng(src));

    final out = resizeIconPng(input);

    final decoded = img.decodeImage(out)!;
    expect(decoded.width, lessThanOrEqualTo(256));
    expect(decoded.height, lessThanOrEqualTo(256));
    // 512x400 长边缩到 256 → 256x200
    expect(decoded.width, 256);
    expect(decoded.height, 200);
  });

  test('resizeIconPng 不放大小图', () {
    final src = img.Image(width: 64, height: 64);
    img.fill(src, color: img.ColorRgb8(0, 0, 0));
    final input = Uint8List.fromList(img.encodePng(src));
    final decoded = img.decodeImage(resizeIconPng(input))!;
    expect(decoded.width, 64);
    expect(decoded.height, 64);
  });

  test('resizeIconPng 解码失败抛 FormatException', () {
    expect(() => resizeIconPng(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()));
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: FAIL —— `app_icon_service.dart` 不存在 / `resizeIconPng` 未定义。

- [ ] **Step 3: 写最小实现**

```dart
// hibiki/lib/src/utils/misc/app_icon_service.dart
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 把任意图片字节缩放到 <=256x256（保持长宽比，不放大）并编码为 PNG。
/// 256 是 Windows .ico 单图硬上限 + macOS Dock Retina 最大尺寸。
Uint8List resizeIconPng(Uint8List input) {
  final img.Image? decoded = img.decodeImage(input);
  if (decoded == null) {
    throw const FormatException('无法解码所选图片');
  }
  const int maxSide = 256;
  img.Image out = decoded;
  if (decoded.width > maxSide || decoded.height > maxSide) {
    out = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide)
        : img.copyResize(decoded, height: maxSide);
  }
  return Uint8List.fromList(img.encodePng(out));
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: PASS（3 个测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/app_icon_service.dart hibiki/test/utils/app_icon_service_test.dart
git commit -m "feat(icon): add resizeIconPng pure helper (256px cap)"
```

---

## Task 2: AppIconService —— 启动回落决策 `resolveApplyArgs`

**Files:**
- Modify: `hibiki/lib/src/utils/misc/app_icon_service.dart`
- Test: `hibiki/test/utils/app_icon_service_test.dart`

- [ ] **Step 1: 追加失败测试**

```dart
// 追加到 app_icon_service_test.dart main() 内
  test('resolveApplyArgs: 预设原样返回', () {
    final r = resolveApplyArgs('hibiki_full',
        customExists: false, customPath: '/x.png');
    expect(r.preset, 'hibiki_full');
    expect(r.customPath, isNull);
  });

  test('resolveApplyArgs: custom 且文件存在 → 带路径', () {
    final r = resolveApplyArgs('custom',
        customExists: true, customPath: '/x.png');
    expect(r.preset, 'custom');
    expect(r.customPath, '/x.png');
  });

  test('resolveApplyArgs: custom 但文件缺失 → 回落 default', () {
    final r = resolveApplyArgs('custom',
        customExists: false, customPath: '/x.png');
    expect(r.preset, 'default');
    expect(r.customPath, isNull);
  });
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: FAIL —— `resolveApplyArgs` 未定义。

- [ ] **Step 3: 写实现**

```dart
// 追加到 app_icon_service.dart
import 'package:meta/meta.dart';

/// 启动/切换时把 (preset, 文件是否存在) 解析成真正要套用的入参。
/// custom 但本地文件缺失 → 回落 default（单一兜底，无分支扩散）。
@visibleForTesting
({String preset, String? customPath}) resolveApplyArgs(
  String preset, {
  required bool customExists,
  required String customPath,
}) {
  if (preset == 'custom') {
    return customExists
        ? (preset: 'custom', customPath: customPath)
        : (preset: 'default', customPath: null);
  }
  return (preset: preset, customPath: null);
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: PASS（6 个测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/app_icon_service.dart hibiki/test/utils/app_icon_service_test.dart
git commit -m "feat(icon): add resolveApplyArgs launch-fallback decision"
```

---

## Task 3: AppIconService —— channel 封装 + 自选文件 + 启动重套用

**Files:**
- Modify: `hibiki/lib/src/utils/misc/app_icon_service.dart`
- Test: `hibiki/test/utils/app_icon_service_test.dart`

> channel 名必须与原生一致。Dart 现有 `HibikiChannels.iconSwitch = MethodChannel('$_prefix/icon_switch')`。**Step 0 先确认** `_prefix` 解析值（`channel_constants.dart` 顶部），原生用同名字符串（参考已存在的 `app.hibiki/window`，推断 `_prefix == 'app.hibiki'` → channel = `app.hibiki/icon_switch`）。

- [ ] **Step 1: 写失败测试（mock channel 捕获入参）**

```dart
// 追加到 app_icon_service_test.dart
import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

  test('applyIcon 把 preset/customPngPath 透传给 icon_switch channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.iconSwitch, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.iconSwitch, null));

    final ok = await AppIconService.applyIcon(
        preset: 'custom', customPngPath: '/tmp/a.png');

    expect(ok, isTrue);
    expect(calls.single.method, 'applyIcon');
    final args = calls.single.arguments as Map;
    expect(args['preset'], 'custom');
    expect(args['customPngPath'], '/tmp/a.png');
  });

  test('applyIcon 吞掉 channel 异常返回 false', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.iconSwitch,
            (call) async => throw PlatformException(code: 'x'));
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.iconSwitch, null));
    expect(await AppIconService.applyIcon(preset: 'default'), isFalse);
  });
```

需要在测试文件顶部加 `TestWidgetsFlutterBinding.ensureInitialized();`（在 `main()` 第一行）。

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: FAIL —— `AppIconService` 类 / `applyIcon` 未定义。

- [ ] **Step 3: 写实现**

```dart
// 追加到 app_icon_service.dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

class AppIconService {
  AppIconService._();

  /// 套用图标统一入口。失败（含不支持平台）返回 false，不抛。
  static Future<bool> applyIcon({
    required String preset,
    String? customPngPath,
  }) async {
    try {
      final bool? ok = await HibikiChannels.iconSwitch.invokeMethod<bool>(
        'applyIcon',
        {'preset': preset, 'customPngPath': customPngPath},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 自选图本地文件（设备本地，不同步）。
  static Future<File> customIconFile() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'app_icon_custom.png'));
  }

  /// 缩放后写入自选图文件，返回路径。
  static Future<String> saveCustomIcon(Uint8List rawBytes) async {
    final Uint8List png = resizeIconPng(rawBytes);
    final File f = await customIconFile();
    await f.writeAsBytes(png, flush: true);
    return f.path;
  }

  /// 启动时按已存 preset 重套用一次（重启持久）。custom 文件缺失回落 default。
  static Future<void> reapplyOnLaunch(String preset) async {
    final File f = await customIconFile();
    final args = resolveApplyArgs(preset,
        customExists: await f.exists(), customPath: f.path);
    await applyIcon(preset: args.preset, customPngPath: args.customPath);
  }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/utils/app_icon_service_test.dart`
Expected: PASS（8 个测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/app_icon_service.dart hibiki/test/utils/app_icon_service_test.dart
git commit -m "feat(icon): AppIconService channel wrapper + custom-file + launch reapply"
```

---

## Task 4: 设置页 —— 门控放开 Win/Mac + 接 AppIconService

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart`
- Test: `hibiki/test/pages/misc_settings_icon_test.dart`

> 现状：`build()` 里 `if (Platform.isAndroid)` 显示网格；`_switchPreset` 走 `switchPresetIcon` 后写 `SharedPreferences`；`_pickCustomIcon` 走 `createCustomShortcut`。改为：门控含 Win/Mac；预设走 `AppIconService.applyIcon(preset:key)` 后写 prefs；桌面自选走 `file_picker`→`saveCustomIcon`→`applyIcon(preset:'custom', customPngPath:path)`→写 prefs。安卓分支保持原 `_switchPreset`/`_pickCustomIcon` 行为不回归。

- [ ] **Step 1: 写源码守卫 + channel 调用测试（失败）**

```dart
// hibiki/test/pages/misc_settings_icon_test.dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('源码守卫：设置页门控含 Windows/macOS', () {
    final src = File(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ).readAsStringSync();
    // 门控不再是裸 Platform.isAndroid，必须并入桌面
    expect(src.contains('Platform.isWindows'), isTrue,
        reason: '设置页应放开到 Windows');
    expect(src.contains('Platform.isMacOS'), isTrue,
        reason: '设置页应放开到 macOS');
  });

  test('源码守卫：桌面预设切换走 AppIconService.applyIcon', () {
    final src = File(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ).readAsStringSync();
    expect(src.contains('AppIconService.applyIcon'), isTrue);
  });
}
```

> 说明：设置页网格的运行时 widget 测试依赖 host 平台（本机 Windows 时 `Platform.isWindows` 真），跨平台 CI 不稳，故用项目惯用的**源码守卫**（读 .dart 断言门控/调用存在）。真生效在原生任务的设备复测里验。

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/pages/misc_settings_icon_test.dart`
Expected: FAIL —— 源码暂无 `Platform.isWindows` / `AppIconService.applyIcon`。

- [ ] **Step 3: 改设置页**

3a. 顶部 import：
```dart
import 'package:file_picker/file_picker.dart';
import 'package:hibiki/src/utils/misc/app_icon_service.dart';
```

3b. `build()` 门控（约 `:149`）：
```dart
        if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)
          AdaptiveSettingsSection(
            title: t.app_icon_label,
            children: [
              AdaptiveSettingsRow(
                title: t.app_icon_label,
                controlBelow: true,
                trailing: _buildIconGrid(),
              ),
              if (_customSupported || Platform.isWindows || Platform.isMacOS) ...[
                AdaptiveSettingsRow(title: t.icon_custom_hint),
              ],
            ],
          )
        else
          // ...保持原 else（不支持）
```

3c. `_switchPreset`（约 `:52`）—— 桌面走 AppIconService，安卓保持原 channel：
```dart
  Future<void> _switchPreset(String key) async {
    if (_switching || _currentIcon == key) return;
    setState(() => _switching = true);
    try {
      final bool ok;
      if (Platform.isAndroid) {
        ok = (await HibikiChannels.iconSwitch
                .invokeMethod<bool>('switchPresetIcon', {'alias': key})) ==
            true;
      } else {
        ok = await AppIconService.applyIcon(preset: key);
      }
      if (ok && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(iconPresetKey, key);
        if (!mounted) return;
        setState(() => _currentIcon = key);
        messenger.showSnackBar(SnackBar(content: Text(t.icon_switch_success)));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }
```

3d. 桌面自选（新增 `_pickCustomIconDesktop`，自选 tile 在桌面调它）：
```dart
  Future<void> _pickCustomIconDesktop() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    try {
      final path = await AppIconService.saveCustomIcon(bytes);
      final ok =
          await AppIconService.applyIcon(preset: 'custom', customPngPath: path);
      if (!mounted) return;
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(iconPresetKey, 'custom');
        setState(() => _currentIcon = 'custom');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.icon_shortcut_created)));
      }
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.icon_shortcut_unsupported)));
    }
  }
```

3e. `_loadCurrentIcon`（约 `:39`）改为：非安卓时从 SharedPreferences 读 `app_icon_preset`（安卓仍走 native `getCurrentIcon`）：
```dart
  Future<void> _loadCurrentIcon() async {
    if (Platform.isAndroid) {
      final results = await Future.wait([
        HibikiChannels.iconSwitch.invokeMethod<String>('getCurrentIcon'),
        HibikiChannels.iconSwitch
            .invokeMethod<bool>('isCustomShortcutSupported'),
      ]);
      if (!mounted) return;
      setState(() {
        _currentIcon = (results[0] as String?) ?? 'default';
        _customSupported = (results[1] as bool?) ?? false;
      });
    } else if (Platform.isWindows || Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _currentIcon = prefs.getString(iconPresetKey) ?? 'default';
        _customSupported = true; // 桌面自选总是支持
      });
    }
  }
```

3f. 自选 tile 的点击在桌面指向 `_pickCustomIconDesktop`（`_buildCustomTile` 里按平台分流，安卓仍 `_pickCustomIcon`）。`_buildIconGrid` 的 `if (_customSupported)` 已能显示自选 tile（桌面把 `_customSupported=true`）。

- [ ] **Step 4: 运行确认通过 + 全量**

Run: `dart format . && flutter test test/pages/misc_settings_icon_test.dart`
Expected: PASS（源码守卫 2 绿）。
Run: `flutter test`
Expected: 全量绿（无回归）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/pages/implementations/miscellaneous_settings_page.dart hibiki/test/pages/misc_settings_icon_test.dart
git commit -m "feat(icon): enable desktop icon picker (Win/Mac) wired to AppIconService"
```

---

## Task 5: main.dart —— 桌面启动重套用

**Files:**
- Modify: `hibiki/lib/main.dart`

> `main()` 难直接单测；逻辑已封装在 `AppIconService.reapplyOnLaunch`（Task 3 已测）。本任务只接线。

- [ ] **Step 1: 在 main.dart 启动序列接线**

在 `runApp` 之后、不阻塞首帧的位置（参考现有 `precacheImage('assets/meta/icon.png')` 附近，约 `:84`）加：
```dart
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hibiki/src/utils/misc/app_icon_service.dart';

// ...在初始化流程里（桌面分支，best-effort，不 await 阻塞 UI）：
if (Platform.isWindows || Platform.isMacOS) {
  unawaited(() async {
    final prefs = await SharedPreferences.getInstance();
    final preset = prefs.getString('app_icon_preset') ?? 'default';
    if (preset != 'default') {
      await AppIconService.reapplyOnLaunch(preset);
    }
  }());
}
```
（`unawaited` 来自 `dart:async`；若文件已 import 则复用。`preset == 'default'` 时原生默认图标即为 default，无需重套用。）

- [ ] **Step 2: 编译验证**

Run: `dart format . && flutter analyze lib/main.dart`
Expected: No issues。
Run: `flutter test`
Expected: 全量绿。

- [ ] **Step 3: 提交**

```bash
git add hibiki/lib/main.dart
git commit -m "feat(icon): reapply saved icon on desktop launch"
```

---

## Task 6: Windows 原生 —— icon_switch channel + WM_SETICON

**Files:**
- Modify: `hibiki/windows/runner/flutter_window.h`, `flutter_window.cpp`, `Runner.rc`, `resource.h`, `CMakeLists.txt`
- Create: `hibiki/windows/runner/resources/{app_icon_full.ico,app_icon_minimal.ico}`

> 无法单测；构建 + 设备复测。参考已存在的 `caption_channel_`（`flutter_window.cpp:34`）作注册样板。

- [ ] **Step 1: 生成预设 .ico**

把源 PNG 转成 256px .ico（default 复用现有 `app_icon.ico`）：
```bash
# 任一可用工具；ImageMagick 示例（若无则用在线/手工，目标 256x256 .ico）
magick hibiki/assets/meta/launcher_icon_full.png -resize 256x256 hibiki/windows/runner/resources/app_icon_full.ico
magick hibiki/assets/meta/launcher_icon_minimal.png -resize 256x256 hibiki/windows/runner/resources/app_icon_minimal.ico
```

- [ ] **Step 2: 注册资源 ID**（`resource.h`）

```cpp
#define IDI_APP_ICON          101
#define IDI_APP_ICON_FULL     102
#define IDI_APP_ICON_MINIMAL  103
```

`Runner.rc` 在现有 `IDI_APP_ICON` 行后加：
```rc
IDI_APP_ICON_FULL       ICON                    "resources\\app_icon_full.ico"
IDI_APP_ICON_MINIMAL    ICON                    "resources\\app_icon_minimal.ico"
```

- [ ] **Step 3: 头文件加 channel 成员 + 套用方法**（`flutter_window.h`）

```cpp
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> icon_channel_;
  HICON custom_hicon_ = nullptr;  // 自选图标句柄，切换时销毁
  void ApplyAppIcon(const std::string& preset, const std::string& custom_png_path);
```

- [ ] **Step 4: 注册 channel + 实现套用**（`flutter_window.cpp`）

在 `caption_channel_` 注册块之后加：
```cpp
  icon_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.hibiki/icon_switch",
          &flutter::StandardMethodCodec::GetInstance());
  icon_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "applyIcon") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::string preset = "default";
          std::string custom_path;
          if (args != nullptr) {
            const auto p_it = args->find(flutter::EncodableValue("preset"));
            if (p_it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&p_it->second))
                preset = *s;
            }
            const auto c_it =
                args->find(flutter::EncodableValue("customPngPath"));
            if (c_it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&c_it->second))
                custom_path = *s;
            }
          }
          ApplyAppIcon(preset, custom_path);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "getCurrentIcon") {
          result->Success(flutter::EncodableValue("default"));
        } else {
          result->NotImplemented();
        }
      });
```

实现 `ApplyAppIcon`（文件内，需 `#include <gdiplus.h>` + 链接 gdiplus；用 GDI+ 把 PNG 解码成 HICON）：
```cpp
void FlutterWindow::ApplyAppIcon(const std::string& preset,
                                 const std::string& custom_png_path) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  HICON hicon = nullptr;
  bool destroy_after = false;  // 资源图标不销毁，自选/转换出的要销毁

  if (preset == "custom" && !custom_png_path.empty()) {
    // PNG 文件 → HICON（GDI+）
    int wlen = MultiByteToWideChar(CP_UTF8, 0, custom_png_path.c_str(), -1,
                                   nullptr, 0);
    std::wstring wpath(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, custom_png_path.c_str(), -1, &wpath[0],
                        wlen);
    Gdiplus::Bitmap bmp(wpath.c_str());
    if (bmp.GetLastStatus() == Gdiplus::Ok) {
      bmp.GetHICON(&hicon);
      destroy_after = true;
    }
  } else {
    int res_id = IDI_APP_ICON;
    if (preset == "hibiki_full") res_id = IDI_APP_ICON_FULL;
    else if (preset == "hibiki_minimal") res_id = IDI_APP_ICON_MINIMAL;
    hicon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(res_id));
  }
  if (!hicon) return;

  SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(hicon));
  SendMessage(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(hicon));

  if (custom_hicon_) {  // 销毁上一张自选句柄
    DestroyIcon(custom_hicon_);
    custom_hicon_ = nullptr;
  }
  if (destroy_after) custom_hicon_ = hicon;  // 留着，下次切换再销毁
}
```
`OnDestroy` 里若 `custom_hicon_` 非空则 `DestroyIcon`。GDI+ 初始化：在 `FlutterWindow` 构造/`OnCreate` 用 `Gdiplus::GdiplusStartup`，析构 `GdiplusShutdown`（若工程未初始化过 GDI+）。

- [ ] **Step 5: CMake 链接 gdiplus**（`CMakeLists.txt`）

`target_link_libraries(${BINARY_NAME} PRIVATE ... gdiplus)`。

- [ ] **Step 6: 构建 + 设备复测**

Run: `cd hibiki && flutter build windows --release`
Expected: 编译通过。
手动：运行 → 设置→应用图标→依次选 full/minimal/自选图 → 肉眼确认任务栏+标题栏图标变 → 重启 app 确认保持。留截图证据。

- [ ] **Step 7: 提交**

```bash
git add hibiki/windows/runner/flutter_window.cpp hibiki/windows/runner/flutter_window.h hibiki/windows/runner/Runner.rc hibiki/windows/runner/resource.h hibiki/windows/runner/CMakeLists.txt hibiki/windows/runner/resources/app_icon_full.ico hibiki/windows/runner/resources/app_icon_minimal.ico
git commit -m "feat(icon): Windows runtime icon switch via WM_SETICON"
```

---

## Task 7: macOS 原生 —— icon_switch channel + applicationIconImage

**Files:**
- Modify: `hibiki/macos/Runner/MainFlutterWindow.swift`
- 预设图：`hibiki/macos/Runner/Assets.xcassets`（加 full/minimal 图）或运行时读 flutter_asset。

> 在远程 Mac（`ssh shfaifsj@192.168.1.34`）构建 + 复测，见 CLAUDE.local.md。参考 `MainFlutterWindow.swift:31 RegisterGeneratedPlugins`。

- [ ] **Step 1: 注册 channel + 套用**（`MainFlutterWindow.swift`）

在 `awakeFromNib()` 里 `RegisterGeneratedPlugins` 之后：
```swift
    let controller = flutterViewController
    let iconChannel = FlutterMethodChannel(
      name: "app.hibiki/icon_switch",
      binaryMessenger: controller.engine.binaryMessenger)
    iconChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "applyIcon":
        let args = call.arguments as? [String: Any]
        let preset = (args?["preset"] as? String) ?? "default"
        let customPath = args?["customPngPath"] as? String
        var image: NSImage?
        if preset == "custom", let path = customPath {
          image = NSImage(contentsOfFile: path)
        } else {
          let asset: String
          switch preset {
          case "hibiki_full": asset = "AppIconFull"
          case "hibiki_minimal": asset = "AppIconMinimal"
          default: asset = "AppIcon"
          }
          image = NSImage(named: asset)
        }
        NSApp.applicationIconImage = image  // nil → 回到 bundle 默认
        result(image != nil)
      case "getCurrentIcon":
        result("default")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
```
> `flutterViewController` 取法与 `RegisterGeneratedPlugins(registry: flutterViewController)` 同源；若该处用的是局部变量，复用之。

- [ ] **Step 2: 加预设图资源**

把 full/minimal PNG 加进 `Assets.xcassets`（image set 命名 `AppIconFull` / `AppIconMinimal`），`AppIcon` 复用现有。

- [ ] **Step 3: 构建 + 设备复测（远程 Mac）**

```bash
ssh shfaifsj@192.168.1.34
cd ~/dev/hibiki && git pull   # 经 mac remote 同步本轮提交
cd hibiki && flutter build macos --debug
open build/macos/Build/Products/Debug/*.app
```
手动：设置→应用图标→选 full/minimal/自选 → 肉眼确认 Dock 图标变 → 重启确认保持。截图取证。

- [ ] **Step 4: 提交**

```bash
git add hibiki/macos/Runner/MainFlutterWindow.swift hibiki/macos/Runner/Assets.xcassets
git commit -m "feat(icon): macOS runtime Dock icon switch via applicationIconImage"
```

---

## Task 8: Android —— applyIcon 适配现有 IconSwitchHelper（不回归）

**Files:**
- Modify: `hibiki/android/app/src/main/java/app/hibiki/reader/IconSwitchHelper.java`、`MainActivity.java`（channel handler）

> 桌面统一调 `applyIcon`，安卓也加 `applyIcon` 入口路由到现有逻辑，保持 `switchPresetIcon`/`createCustomShortcut` 行为不变（设置页安卓分支仍走旧方法，故本任务是"加兼容入口"，可选；若 Task 4 安卓分支保留旧 method 调用，则 Android 无需改）。

- [ ] **Step 1: 判断是否需要改**

Task 4 已让安卓分支保留 `switchPresetIcon`/`createCustomShortcut`。**若保留**，Android 端无需新增 `applyIcon` → 本任务空操作，跳过。
**若想统一**：在 MainActivity 的 `icon_switch` channel handler 加 `case "applyIcon"`，按 `preset` 调 `IconSwitchHelper.switchPresetIcon`，custom 时走 `createCustomShortcut`（需另传 bytes，桌面契约用 path，安卓不复用 path → 维持安卓走旧 `_pickCustomIcon` 更简单）。

- [ ] **Step 2: 构建验证（若改了）**

Run: `cd hibiki/android && ./gradlew :app:assembleRelease`
Expected: BUILD SUCCESSFUL。
手动：安卓换图标功能仍正常（无回归）。

- [ ] **Step 3: 提交（若改了）**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/IconSwitchHelper.java hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java
git commit -m "feat(icon): Android applyIcon entry routed to existing alias/shortcut"
```

---

## Task 9: 打包核对 —— 桌面预览图入包

**Files:**
- Check: `hibiki/pubspec.yaml`（`- assets/meta/` 已声明，full/minimal PNG 在源码中 → 桌面构建自动入包）。
- 之前对 Windows 产物的体积裁剪（删 full/minimal 预览图）**与本功能冲突**：桌面 picker 要显示预览，full/minimal 必须在包里。后续发包脚本只剔除 `icon-android12.png`/`launcher_source.png`，**不再剔除** full/minimal。

- [ ] **Step 1: 确认 pubspec 仍打包 assets/meta**

Run: `grep -n "assets/meta" hibiki/pubspec.yaml`
Expected: `- assets/meta/` 在 `assets:` 列表中。无需改。

- [ ] **Step 2: 记录发包注意**

在 `docs/agent/build.md` 桌面发包小节补一句："桌面换图标依赖 full/minimal 预览图，发包剥离仅限 icon-android12/launcher_source，勿删 launcher_icon_full/minimal。"

- [ ] **Step 3: 提交**

```bash
git add hibiki/docs/agent/build.md
git commit -m "docs(build): keep full/minimal icon previews in desktop bundle"
```

---

## 收尾验证（全任务后）

- [ ] `cd hibiki && dart format . && flutter test` 全量绿。
- [ ] Windows release 构建 + 真机：三预设 + 自选 + 重启保持，截图。
- [ ] macOS 构建（远程 Mac）+ 真机：三预设 + 自选 + 重启保持，截图。
- [ ] Android：换图标无回归。
- [ ] 调 `superpowers:requesting-code-review`（`model: opus`）审本轮改动。

## Self-Review 覆盖核对
- spec §3.1 存储（SharedPreferences 预设 + 本地文件自选）→ Task 3/4。
- spec §3.2 channel applyIcon → Task 3（Dart）/6（Win）/7（Mac）/8（Android）。
- spec §3.3 各端套用 → Task 6/7/8。
- spec §3.4 启动重套用 → Task 3（逻辑）/5（接线）。
- spec §3.5 UI 门控 + 预览图 → Task 4 / 9。
- spec §3.6 256 上限 → Task 1。
- spec §4 错误处理（吞异常返回 false / 回落 default）→ Task 2/3。
- spec §5 体积副作用 → Task 9。
- spec §6 测试（缩放/回落/channel/源码守卫）→ Task 1/2/3/4。
