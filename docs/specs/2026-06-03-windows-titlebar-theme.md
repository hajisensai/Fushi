# Windows 标题栏主题化 Implementation Plan

> **For agentic workers:** 三处独立改动，按 Task 顺序执行；Dart 改动跑 `flutter analyze`，原生/资源改动靠 Windows 构建肉眼复测。

**Goal:** 删掉宽屏侧栏左上角的 app logo，把原生 Windows 标题栏图标换成真正的 Hibiki 图标，并让标题栏背景跟随 app 主题色（`colorScheme.surface`）且失焦时也保持。

**Architecture:**
- #1 纯 Dart：移除 `home_page.dart` 桌面布局 NavigationRail 的 `leading` logo。
- #2 资源：用 `flutter_launcher_icons` 给 windows 平台生成 `app_icon.ico`（当前是 33772B 的 Flutter 默认模板图标）。
- #3 跨语言：新增 `app.hibiki/window` MethodChannel，Dart 在 `main.dart` builder（已读 live `colorScheme`）里把 `surface`/`onSurface` 推给原生；Windows runner 用 `DwmSetWindowAttribute(DWMWA_CAPTION_COLOR/DWMWA_TEXT_COLOR)` 着色顶层窗口。显式设 caption color 后，系统不再在失焦时灰化。

**Tech Stack:** Flutter 3.44 / Dart；Win32 + DWM（dwmapi）；flutter_launcher_icons 0.14.3。

---

### Task 1: 删除宽屏侧栏左上角 logo

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`（`_buildDesktopLayout` 的 `leading:` + 删除 `_buildRailLeading()`；若 `_iconAsset`/`iconAssetMap`/incognito 引用变为死代码则一并清理）

- [ ] **Step 1:** 把 `adaptiveNavRail(...)` 调用里的 `leading: _buildRailLeading(),`（约 384 行）删除（rail 无 leading 时该参数可省略）。
- [ ] **Step 2:** 删除 `_buildRailLeading()` 方法（约 430-450 行）。
- [ ] **Step 3:** 检查 `_iconAsset`（32 行）、`iconAssetMap`、`appModel.incognitoNotifier` 在删除后是否还有其它使用；若仅 rail leading 使用则删除相关字段/赋值（72 行 setState），消除未用告警。保留仍被别处使用的部分。
- [ ] **Step 4:** `cd hibiki && flutter analyze lib/src/pages/implementations/home_page.dart`，期望无 error/warning（无 unused 残留）。

---

### Task 2: 替换原生 Windows 标题栏图标

**Files:**
- Modify: `hibiki/pubspec.yaml`（`flutter_icons:` 块加 `windows:`）
- Regenerate: `hibiki/windows/runner/resources/app_icon.ico`

- [ ] **Step 1:** 确认源图为正方形高分辨率：`hibiki/assets/meta/launcher_icon_full.png`（2.4MB）。若非正方形改用 `assets/meta/icon.png`。
- [ ] **Step 2:** 在 `pubspec.yaml` 的 `flutter_icons:` 块追加：
```yaml
  windows:
    generate: true
    image_path: "assets/meta/launcher_icon_full.png"
    icon_size: 256
```
- [ ] **Step 3:** `cd hibiki && dart run flutter_launcher_icons`，期望生成/覆盖 `windows/runner/resources/app_icon.ico`（大小应明显不同于 33772B）。
- [ ] **Step 4:** `git status --short` 确认仅 `app_icon.ico` 与 `pubspec.yaml` 改动；android/ios 图标未被动到（config 未改它们的 image_path）。

---

### Task 3: 标题栏背景跟随主题色（含失焦）

**Files:**
- Create: `hibiki/lib/src/utils/window_caption_channel.dart`（Dart 侧 MethodChannel 封装）
- Modify: `hibiki/lib/main.dart`（builder 内推送，约 482-508 行）
- Modify: `hibiki/windows/runner/flutter_window.h` / `flutter_window.cpp`（注册 channel + DWM 着色）
- Modify: `hibiki/windows/runner/CMakeLists.txt`（链接 `dwmapi`，若未链接）

- [ ] **Step 1（Dart channel）:** 新建 `window_caption_channel.dart`：
```dart
import 'dart:io';
import 'dart:ui';
import 'package:flutter/services.dart';

/// 把标题栏配色推给 Windows 原生 runner。仅 Windows 生效，其它平台 no-op。
class WindowCaptionChannel {
  WindowCaptionChannel._();
  static const MethodChannel _channel = MethodChannel('app.hibiki/window');
  static int? _lastCaption;
  static int? _lastText;

  /// 设置标题栏背景与文字色（传 ARGB int）。同值不重复下发，避免刷 channel。
  static Future<void> setCaptionColors({
    required Color caption,
    required Color text,
  }) async {
    if (!Platform.isWindows) return;
    final int captionArgb = caption.toARGB32();
    final int textArgb = text.toARGB32();
    if (captionArgb == _lastCaption && textArgb == _lastText) return;
    _lastCaption = captionArgb;
    _lastText = textArgb;
    try {
      await _channel.invokeMethod<void>('setCaptionColors', <String, int>{
        'caption': captionArgb,
        'text': textArgb,
      });
    } on PlatformException {
      // 旧 Windows（<Win11 22000）不支持 DWMWA_CAPTION_COLOR，忽略。
    }
  }
}
```
（注：`Color.toARGB32()` 是 Flutter 3.27+ API；本仓库 3.44 可用。若 analyze 报缺失则用 `caption.value`。）
- [ ] **Step 2（Dart 推送）:** 在 `main.dart` builder 内、`final cs = Theme.of(context).colorScheme;`（483 行）之后加：
```dart
          WindowCaptionChannel.setCaptionColors(
            caption: cs.surface,
            text: cs.onSurface,
          );
```
并在文件顶部 import `window_caption_channel.dart`。builder 每次主题变化都会重跑，channel 内做了同值去重。
- [ ] **Step 3（原生头）:** `flutter_window.h` 加成员声明：
```cpp
  // Pushes DWM caption/text colors from Dart; persists across focus changes.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> caption_channel_;
  void ApplyCaptionColors(int caption_argb, int text_argb);
```
并 `#include <flutter/method_channel.h>`、`#include <flutter/standard_method_codec.h>`、`#include <memory>`。
- [ ] **Step 4（原生注册+着色）:** `flutter_window.cpp` 顶部加 `#include <dwmapi.h>`；在 `OnCreate()` 的 `RegisterPlugins(...)` 之后、`SetChildContent(...)` 之前注册 channel：
```cpp
  caption_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.hibiki/window",
          &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setCaptionColors") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto caption_it = args->find(flutter::EncodableValue("caption"));
            auto text_it = args->find(flutter::EncodableValue("text"));
            int caption_argb =
                caption_it != args->end() ? std::get<int>(caption_it->second) : 0;
            int text_argb =
                text_it != args->end() ? std::get<int>(text_it->second) : 0;
            ApplyCaptionColors(caption_argb, text_argb);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
```
并实现 `ApplyCaptionColors`（ARGB→COLORREF 0x00BBGGRR）：
```cpp
void FlutterWindow::ApplyCaptionColors(int caption_argb, int text_argb) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  auto to_colorref = [](int argb) -> COLORREF {
    return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  };
  COLORREF caption = to_colorref(caption_argb);
  COLORREF text = to_colorref(text_argb);
  // DWMWA_CAPTION_COLOR=35, DWMWA_TEXT_COLOR=36 (Win11 build 22000+).
  DwmSetWindowAttribute(hwnd, 35, &caption, sizeof(caption));
  DwmSetWindowAttribute(hwnd, 36, &text, sizeof(text));
}
```
- [ ] **Step 5（链接库）:** 检查 `windows/runner/CMakeLists.txt` 是否已 `target_link_libraries(... dwmapi)`；未链接则加 `dwmapi.lib`（或 `target_link_libraries(${BINARY_NAME} PRIVATE dwmapi)`）。
- [ ] **Step 6（构建验证）:** `cd hibiki && flutter analyze`（期望 0 issue）→ `flutter build windows --debug` 期望编译通过。
- [ ] **Step 7（肉眼复测，Win11）:** 运行 `build/windows/x64/runner/Debug/hibiki.exe`：
  - 标题栏背景=当前主题 surface 色（暗主题深色/亮主题浅色），文字可读；
  - 点别的窗口让 Hibiki 失焦，标题栏**仍是主题色不变灰**；
  - 切换 app 暗/亮主题或换 seed 色，标题栏实时跟随；
  - 标题栏图标=Hibiki 图标（非 Flutter logo）；
  - 宽屏侧栏顶部不再有 logo。

---

## 影响范围与回退
- 仅 Windows 平台 + home_page 桌面布局；Android/iOS/macOS/Linux 不受影响（channel 在非 Windows no-op；macOS 走 Cupertino 无此 rail leading 影响——确认 macOS 是否复用 home_page 桌面布局，若复用则 logo 删除对 macOS 也生效，符合"删掉宽屏左上角图标"意图）。
- 三个 Task 相互独立，可单独 commit / revert。
- 旧 Windows（<Win11 22000）：DWM 调用返回错误被忽略，标题栏维持系统默认行为，不崩溃。
