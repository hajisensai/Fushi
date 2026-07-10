# 剪贴板查词独立弹窗 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 剪贴板查词新增两种去向——常驻半透明面板（覆盖窗第二实例）与光标处瞬态弹卡；默认去向 main 零破坏；顺手根修抓选区剪贴板事件泄漏。

**Architecture:** 复用 TODO-617 覆盖窗全管线（searchDictionary → buildStackRenderScript → WebView2 renderStack）。面板 = `GlobalLookupWindow` 第二实例（不装 dismiss 钩子、独立 user-data-folder、固定 rect、host `layoutMode:'panel'`）。路由 = 纯函数 `resolveDesktopLookupConsumer` 把 `DesktopLookupService` 请求分区给三个互斥消费者。

**Tech Stack:** Dart/Flutter 3.44、Win32 + WebView2（windowed hosting）、host JS（assets/popup）、Drift prefs、Slang i18n（17 语言，必须走 `tool/i18n_sync.dart`）。

**Spec:** `docs/specs/2026-07-10-clipboard-panel-lookup-design.md`（基线 origin/develop `cdcef9b86`；本 worktree 即该基线）。

**重要技术修正（相对 spec §6）**：调查证实 host.html/shell/iframe 全透明但 **C++ 窗口本身是不透明非 layered 窗**（popup.css:1225 注释、global_lookup_window.cpp:253-255）——CSS rgba 只能对窗口底色半透明，**透不到底下的游戏**。真透视 = Win11 `DWMWA_SYSTEMBACKDROP_TYPE`(acrylic) + `DwmExtendFrameIntoClientArea` + 透明 WebView2 背景（已有）。M0 gate 改为验证该组合；失败降级不透明（slider 隐藏，由 native 返回 `backdropApplied` 门控）。

**验证纪律**：每个 task 结束 `dart format` 改动文件 + `flutter analyze`（全量含 test，warning 即失败）+ 定向 `flutter test`；native/JS 改动后 `flutter build windows --debug`。commit 只 stage 本 task 文件（禁 `git add -A`）。

---

## M1 — Dart 管线（全部可离屏验证）

### Task 1: `DesktopClipboardDestination` 枚举 + 4 个面板 prefs + AppModel 转发

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart`（enum 加在 `DesktopClipboardWindowMode` 之后 :32；getters 加在 `setDesktopClipboardWindowMode` 之后 :418）
- Modify: `hibiki/lib/src/models/app_model.dart:3988` 后
- Test: `hibiki/test/models/desktop_clipboard_destination_test.dart`（新建）

- [ ] **Step 1: 失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';

void main() {
  group('DesktopClipboardDestination.fromStorage', () {
    test('roundtrip 三值', () {
      for (final DesktopClipboardDestination d
          in DesktopClipboardDestination.values) {
        expect(DesktopClipboardDestination.fromStorage(d.storageValue), d);
      }
    });
    test('未知/空值回退 main（存量用户零破坏）', () {
      expect(DesktopClipboardDestination.fromStorage(''),
          DesktopClipboardDestination.main);
      expect(DesktopClipboardDestination.fromStorage('bogus'),
          DesktopClipboardDestination.main);
    });
  });
}
```

- [ ] **Step 2: 实现枚举（仿 `DesktopClipboardWindowMode` :16-32 同款范式）**

```dart
/// 剪贴板查词去向（spec 2026-07-10 剪贴板独立弹窗）：
/// main = 主窗查词 tab（默认，现状）；panel = 常驻悬浮面板（覆盖窗第二实例，
/// 仅 Windows）；transient = 光标处瞬态弹卡（复用全局查词覆盖窗，仅 Windows）。
enum DesktopClipboardDestination {
  main('main'),
  panel('panel'),
  transient('transient');

  const DesktopClipboardDestination(this.storageValue);

  final String storageValue;

  static DesktopClipboardDestination fromStorage(String value) {
    for (final DesktopClipboardDestination d
        in DesktopClipboardDestination.values) {
      if (d.storageValue == value) return d;
    }
    return DesktopClipboardDestination.main;
  }
}
```

prefs（:418 后）：`desktopClipboardDestination`（key `desktop_clipboard_destination`，default `''`→main）/ `clipboardPanelOpacity`（`clipboard_panel_opacity`，default 0.85）/ `clipboardPanelRect`（`clipboard_panel_rect`，default `''`，格式 `x,y,w,h` 逻辑像素）/ `clipboardPanelPinned`（`clipboard_panel_pinned`，default true），全部带 setter+notifyListeners，照 :368-374 范式。AppModel :3988 后加 4 对转发（`setDesktopClipboardDestination` 额外调 `DesktopLookupDispatcher`？——不，保持纯转发，路由端每次读取现值）。

- [ ] **Step 3: `flutter test test/models/desktop_clipboard_destination_test.dart` 绿；analyze 零问题**
- [ ] **Step 4: Commit** `feat(lookup): clipboard destination enum + panel prefs (spec 2026-07-10)`

### Task 2: 抓选区剪贴板事件泄漏根修（spec §8）

**Files:**
- Modify: `hibiki/lib/src/sync/clipboard_dedupe.dart`（加 `ClipboardIgnoreSet`）
- Modify: `hibiki/lib/src/sync/desktop_lookup_service.dart`（`_handleClipboardChange` :228-235 拆出可测方法 + 持有 ignore set）
- Modify: `hibiki/lib/src/lookup/selection_capture_ffi.dart`（:77-82 恢复剪贴板前登记）
- Test: `hibiki/test/sync/clipboard_ignore_set_test.dart`（新建）+ `hibiki/test/sync/desktop_lookup_service_test.dart`（扩展）

- [ ] **Step 1: 失败测试（ignore set 四态 + service 集成）**

```dart
// clipboard_ignore_set_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/clipboard_dedupe.dart';

void main() {
  test('register 后 consume 命中即吞掉且一次性', () {
    final ClipboardIgnoreSet s = ClipboardIgnoreSet()
      ..register(<String>['選択テキスト', '旧剪贴板']);
    expect(s.consume('選択テキスト'), isTrue);
    expect(s.consume('選択テキスト'), isFalse); // 一次性
  });
  test('未命中的真实复制使整批登记过期', () {
    final ClipboardIgnoreSet s = ClipboardIgnoreSet()
      ..register(<String>['stale']);
    expect(s.consume('用户真实复制'), isFalse);
    expect(s.consume('stale'), isFalse); // 已整体过期，不再吞用户后续复制
  });
  test('空白登记被忽略', () {
    final ClipboardIgnoreSet s = ClipboardIgnoreSet()..register(<String>['  ']);
    expect(s.isEmpty, isTrue);
  });
}
```

service 集成（加进 desktop_lookup_service_test.dart，用现有 `debugReset` 范式）：`clipboardIgnores.register(['x'])` 后 `processClipboardText('x')` 不产生 pending；未登记文本照常产生 pending。

- [ ] **Step 2: 实现**

`clipboard_dedupe.dart` 追加：

```dart
/// 一次性剪贴板忽略集（spec 2026-07-10 §8 抓选区泄漏根修）。全局查词抓选区
/// （selection_capture_ffi）对剪贴板的写入会触发 WM_CLIPBOARDUPDATE，此刻 app
/// 必不在前台，DesktopLookupService 会把「捕获文本」「恢复的旧文本」当成用户
/// 复制排进查词管线（假查词）。抓取方登记这批文本；监听端处理事件时先
/// [consume]——命中即吞掉并移除（一次性）；未命中说明捕获窗口期已过，整批清空，
/// 防陈旧登记吞掉用户后续的真实复制。纯 Dart，无平台依赖。
class ClipboardIgnoreSet {
  final Set<String> _texts = <String>{};

  bool get isEmpty => _texts.isEmpty;

  void register(Iterable<String> texts) {
    for (final String t in texts) {
      final String trimmed = t.trim();
      if (trimmed.isNotEmpty) _texts.add(trimmed);
    }
  }

  /// true = 该文本是抓选区自产事件，调用方应丢弃本次剪贴板变化。
  bool consume(String text) {
    if (_texts.remove(text.trim())) return true;
    _texts.clear();
    return false;
  }
}
```

`desktop_lookup_service.dart`：字段 `final ClipboardIgnoreSet clipboardIgnores = ClipboardIgnoreSet();`；`_handleClipboardChange` 末两行改为调 `processClipboardText(text)`；新增：

```dart
/// 剪贴板事件的统一入口（读取成功后）。@visibleForTesting 使泄漏根修可离屏
/// 单测（真实读取不可测）。spec §8：先过一次性忽略集（吞掉抓选区自产事件）。
@visibleForTesting
void processClipboardText(String text) {
  if (text.trim().isEmpty) return;
  if (clipboardIgnores.consume(text)) return;
  submitText(text);
}
```

`selection_capture_ffi.dart` 在恢复剪贴板（:79-81 `if (oldText != null ...`）**之前**插入登记（import `package:hibiki/src/sync/desktop_lookup_service.dart`，无环：service 不 import lookup/）：

```dart
    // spec 2026-07-10 §8 — 本函数的剪贴板写入（注入 Ctrl+C 的选区写入 + 下面的
    // 旧值恢复）都会触发 WM_CLIPBOARDUPDATE；此刻 app 不在前台，剪贴板监听会把
    // 它们当用户复制排进查词管线。登记进一次性忽略集让监听端吞掉这批自产事件。
    // TODO-617 设计（design.md:74）规划过此护栏但从未实现——此即根修。
    DesktopLookupService.instance.clipboardIgnores.register(<String>[
      if (captured != null) captured,
      if (oldText != null) oldText,
    ]);
```

- [ ] **Step 3: 定向测试绿 + 全量 analyze 零问题**
- [ ] **Step 4: Commit** `fix(lookup): swallow selection-capture clipboard echoes via one-shot ignore set (spec §8)`

### Task 3: 路由纯函数 `resolveDesktopLookupConsumer`

**Files:**
- Create: `hibiki/lib/src/lookup/desktop_lookup_router.dart`
- Test: `hibiki/test/lookup/desktop_lookup_router_test.dart`（新建）

- [ ] **Step 1: 失败测试（全矩阵 3 origin × 3 destination × 2 available = 18 例，逐一断言）**
- [ ] **Step 2: 实现**

```dart
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

/// 桌面查词请求的消费面（spec 2026-07-10 §4）。
enum DesktopLookupConsumer { mainTab, panel, transient }

/// 纯函数：一次 [DesktopLookupService] 请求应落到哪个消费面。
/// - explicit（悬浮字幕点词回落）恒 mainTab：它本就是覆盖窗不可用时的回落路径。
/// - 覆盖窗不可用（非 Windows / 控制器未启动）时 panel/transient 退回 mainTab，
///   请求永不静默丢失。
/// HomeDictionaryPage（mainTab）与 DesktopLookupDispatcher（panel/transient）
/// 以本函数结果互斥分区消费 pendingRequest，无双消费。
DesktopLookupConsumer resolveDesktopLookupConsumer({
  required DesktopLookupOrigin origin,
  required DesktopClipboardDestination destination,
  required bool overlayAvailable,
}) {
  if (origin == DesktopLookupOrigin.explicit) {
    return DesktopLookupConsumer.mainTab;
  }
  if (!overlayAvailable) return DesktopLookupConsumer.mainTab;
  switch (destination) {
    case DesktopClipboardDestination.main:
      return DesktopLookupConsumer.mainTab;
    case DesktopClipboardDestination.panel:
      return DesktopLookupConsumer.panel;
    case DesktopClipboardDestination.transient:
      return DesktopLookupConsumer.transient;
  }
}
```

- [ ] **Step 3: 测试绿 + Commit** `feat(lookup): pure destination router for desktop lookup consumers`

### Task 4: 生命周期上移 AppModel + HomeDictionaryPage 退化为 main 消费者

**Files:**
- Modify: `hibiki/lib/src/models/app_model.dart`（:3969-3971 setter 改；:882-886 守卫注释改写）
- Modify: `hibiki/lib/src/lookup/global_lookup_controller.dart`（加 `bool get isAvailable => isSupported && _started;`，:57 旁）
- Modify: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`（:110-121 gate；删 :112 `_startDesktopLookupIfEnabled` 调用与 :154-164 方法体；删 dispose :223-226 stop 块）
- Modify: `hibiki/lib/main.dart`（:379 后加启动）
- Modify: `hibiki/lib/src/settings/settings_schema_lookup.dart`（:287-293 onChanged 简化）
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`（:224/:273-279 注释改写）
- Test: `hibiki/test/lookup/desktop_lookup_lifecycle_guard_test.dart`（新建，源码守卫）

- [ ] **Step 1: 源码守卫失败测试**：断言 ① `home_dictionary_page.dart` 不含 `DesktopLookupService.instance.start(`、不含 `.stop()`；② `app_model.dart` 含 `applyDesktopClipboardLifecycle`；③ `home_dictionary_page.dart` 的 `_onDesktopLookupPending` 含 `resolveDesktopLookupConsumer`（防后人绕过路由直接消费）。
- [ ] **Step 2: 实现**

AppModel（:3969-3971 替换 + 新方法）：

```dart
  bool get desktopClipboardEnabled => prefsRepo.desktopClipboardEnabled;
  Future<void> setDesktopClipboardEnabled(bool v) async {
    await prefsRepo.setDesktopClipboardEnabled(v);
    await applyDesktopClipboardLifecycle();
  }

  /// spec 2026-07-10 §7 生命周期上移：剪贴板监听归 AppModel 持有（开=start /
  /// 关=stop），HomeDictionaryPage 退化为 destination==main 的消费者。此前
  /// start/stop 绑词典 tab 挂载周期——那是「去向只有主窗 tab」时代的产物；
  /// 面板/瞬态去向要求 app 级监听（tab 未挂载时 pending 排队语义 TODO-376 已有）。
  Future<void> applyDesktopClipboardLifecycle() async {
    if (!DesktopLookupService.isDesktop) return;
    if (desktopClipboardEnabled) {
      await DesktopLookupService.instance.start(
        windowMode: desktopClipboardWindowMode,
      );
    } else {
      await DesktopLookupService.instance.stop();
    }
  }
```

main.dart（:379 `GlobalLookupController...start` 之后同一 try 块内）：

```dart
          // spec 2026-07-10 §7 — 剪贴板监听 app 级启动（生命周期归 AppModel）。
          await appModel.applyDesktopClipboardLifecycle();
```

home_dictionary_page.dart `_onDesktopLookupPending`（:166-179 改）：

```dart
  void _onDesktopLookupPending() {
    final DesktopLookupRequest? request =
        DesktopLookupService.instance.pendingRequest;
    if (request == null) return;
    // spec 2026-07-10 §4 — destination 路由：本页只消费 mainTab 分区；
    // panel/transient 由 DesktopLookupDispatcher 消费（互斥，无双消费）。
    if (resolveDesktopLookupConsumer(
          origin: request.origin,
          destination: appModelNoUpdate.desktopClipboardDestination,
          overlayAvailable: GlobalLookupController.instance.isAvailable,
        ) !=
        DesktopLookupConsumer.mainTab) {
      return;
    }
    DesktopLookupService.instance.clearPending();
    ...（其余原样）
```

settings onChanged（:287-293）简化为只调 `setDesktopClipboardEnabled(value)`（其内部已 start/stop）。删除 `_startDesktopLookupIfEnabled`、dispose stop 块、initState :112 行；改写 app_model.dart:882-886 / home_page.dart:224,273-279 守卫注释为「app 级监听 + 分区消费」的新事实。

- [ ] **Step 3: 守卫测试绿 + 全量 `flutter test`（关注 home_dictionary/desktop_lookup 相关既有用例）+ analyze 零问题**
- [ ] **Step 4: Commit** `refactor(lookup): lift DesktopLookupService lifecycle to AppModel; gate main-tab consumption by router (spec §7)`

### Task 5: Dispatcher + transient 接线 + 设置项 + i18n

**Files:**
- Create: `hibiki/lib/src/lookup/desktop_lookup_dispatcher.dart`
- Modify: `hibiki/lib/main.dart`（dispatcher 启动，紧邻 Task 4 加的行）
- Modify: `hibiki/lib/src/settings/settings_schema_lookup.dart`（:331 后加 destination 分段项；window_mode :300-302 visible += `destination == main`）
- i18n: `dart run tool/i18n_sync.dart --add <key> <en> <zh>` × 5 键，然后 `dart run slang` + `dart format lib/i18n/strings.g.dart`
- Test: `hibiki/test/lookup/desktop_lookup_dispatcher_test.dart`

- [ ] **Step 1: i18n 键（en/zh；其余 15 语言由 i18n_sync 补占位）**

| key | en | zh |
|---|---|---|
| `desktop_clipboard_destination` | Clipboard lookup destination | 剪贴板查词显示位置 |
| `desktop_clipboard_destination_hint` | Where clipboard lookups appear | 剪贴板查词结果显示在哪里 |
| `desktop_clipboard_destination_main` | Main window | 主窗口 |
| `desktop_clipboard_destination_panel` | Floating panel | 悬浮面板 |
| `desktop_clipboard_destination_transient` | Popup at cursor | 光标处弹卡 |

- [ ] **Step 2: Dispatcher（M1 版：panel 分支暂等同 transient 并留 M2 注释——UI 在 M2 前不暴露 panel 选项，分支不可达但防御性存在）**

```dart
import 'dart:async';

import 'package:hibiki/src/lookup/desktop_lookup_router.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

/// spec 2026-07-10 §4 — app 级消费者：把 destination=panel/transient 的桌面查词
/// 请求从 [DesktopLookupService] 分发进覆盖窗管线。mainTab 分区不碰（仍由
/// HomeDictionaryPage 消费）；分区判据与页面侧共用 [resolveDesktopLookupConsumer]。
class DesktopLookupDispatcher {
  DesktopLookupDispatcher._();
  static final DesktopLookupDispatcher instance = DesktopLookupDispatcher._();

  AppModel? _appModel;
  bool _started = false;

  void start({required AppModel appModel}) {
    if (_started) return;
    _started = true;
    _appModel = appModel;
    DesktopLookupService.instance.addListener(_onPending);
  }

  void _onPending() {
    final AppModel? model = _appModel;
    final DesktopLookupRequest? request =
        DesktopLookupService.instance.pendingRequest;
    if (model == null || request == null) return;
    final DesktopLookupConsumer consumer = resolveDesktopLookupConsumer(
      origin: request.origin,
      destination: model.desktopClipboardDestination,
      overlayAvailable: GlobalLookupController.instance.isAvailable,
    );
    switch (consumer) {
      case DesktopLookupConsumer.mainTab:
        return; // HomeDictionaryPage 消费。
      case DesktopLookupConsumer.panel:
      // M2 Task 11 接管 panel → ClipboardPanelController.update；在那之前
      // UI 不暴露 panel 选项，此分支不可达，防御性回落瞬态弹卡。
      case DesktopLookupConsumer.transient:
        DesktopLookupService.instance.clearPending();
        // 整句作 sentence 横幅 + 制卡 sentence 字段（覆盖窗自身按词条切前缀）。
        unawaited(GlobalLookupController.instance
            .lookupText(request.text, sentence: request.text));
    }
  }
}
```

main.dart：`DesktopLookupDispatcher.instance.start(appModel: appModel);`（`applyDesktopClipboardLifecycle` 前一行——先挂监听再启动服务，防首个事件竞态）。

设置项（M1 只暴露 main/transient 两段；panel 段 M2 加）：仿 :295-331 `SettingsSegmentedItem<DesktopClipboardWindowMode>` 范式写 `SettingsSegmentedItem<DesktopClipboardDestination>`，`visible: isDesktop && desktopClipboardEnabled && GlobalLookupController.isSupported`。window_mode 项 visible 追加 `&& settingsContext.appModel.desktopClipboardDestination == DesktopClipboardDestination.main`。

- [ ] **Step 3: dispatcher 测试**（析出可测纯逻辑已在 Task 3；此处测 dispatcher 对 mainTab 请求不 clearPending、对 transient 请求 clearPending——用 `DesktopLookupService.instance.debugReset()`+`submitText` 注入，mock 不了 lookupText 就断言 pending 清空与否）
- [ ] **Step 4: 全量 analyze + `flutter test` + Commit** `feat(lookup): clipboard transient destination + dispatcher + settings (spec §4)`

---

## M2 — native 双实例 + host 面板模式 + ClipboardPanelController

### Task 6: native `GlobalLookupWindow` 多实例安全 + 面板差异化

**Files:**
- Modify: `hibiki/windows/runner/global_lookup_window.h`（成员+setter，:161-181 区）
- Modify: `hibiki/windows/runner/global_lookup_window.cpp`

改动清单（全部有档案锚点）：
1. **窗类进程级注册**（cpp:217-230）：`EnsureWindowClass` 里 `if (class_registered_)` 改 `static bool s_class_registered = false; if (s_class_registered) return; ... s_class_registered = true;`；析构 :212-214 **删除** `UnregisterClassW`（窗类进程生存期共享，注释写明双实例互相反注册的坑）；删成员 `class_registered_`。
2. **dismiss 钩子开关**：新成员 `bool arm_dismiss_hooks_ = true;` + `void SetArmDismissHooks(bool v)`；`Reveal()`（cpp:345-356）与 `RevealStack()`（cpp:406-417）两处钩子安装块包 `if (arm_dismiss_hooks_) { s_hook_owner_ = this; ... }`（面板永不写 `s_hook_owner_`，静态钩子指针保持查词窗独占）。
3. **独立 user-data-folder**：新成员 `std::wstring user_data_leaf_ = L"GlobalLookupWebView2";` + setter；`OverlayUserDataFolder()`（cpp:130-146）改成员函数用 `user_data_leaf_`；调用点 cpp:568。
4. **拖动/调整转发**（cpp:699-779 `add_WebMessageReceived` 回调，`message_cb_` 调用前）：

```cpp
      // spec 2026-07-10 面板 — host chrome 拖动：客户区被 WebView2 子窗铺满，
      // WM_NCHITTEST 到不了本窗，故由 JS postMessage 触发 HTCAPTION 模态拖动；
      // SendMessage 在拖动结束后返回，随即把最终 rect 报回 Dart 持久化。
      if (body.find("\"handler\":\"beginWindowDrag\"") != std::string::npos ||
          body.find("\"handler\":\"beginWindowResize\"") != std::string::npos) {
        const bool resize =
            body.find("\"beginWindowResize\"") != std::string::npos;
        ReleaseCapture();
        SendMessage(hwnd_, WM_NCLBUTTONDOWN,
                    resize ? HTBOTTOMRIGHT : HTCAPTION, 0);
        if (message_cb_) {
          RECT r{};
          GetWindowRect(hwnd_, &r);
          message_cb_(std::string("{\"handler\":\"windowMoved\",\"args\":[") +
                      std::to_string(r.left) + "," + std::to_string(r.top) +
                      "," + std::to_string(r.right - r.left) + "," +
                      std::to_string(r.bottom - r.top) + "]}");
        }
        return S_OK;
      }
```

5. **Win11 acrylic backdrop（M0 gate 载体）**：新方法

```cpp
// spec §6 半透明 gate — Win11 22H2+ 的系统 backdrop：窗口透明像素处透出桌面
// 的 acrylic 模糊（WebView2 默认背景已是全透明 A=0，cpp:614-619）。Win10 /
// 旧 Win11 上 DwmSetWindowAttribute 返回失败 → 面板保持不透明，Dart 据返回值
// 隐藏透明度滑杆。不动 WS_EX_LAYERED（与 WebView2 组合表面不共存）。
bool GlobalLookupWindow::ApplySystemBackdrop() {
  if (hwnd_ == nullptr) { return false; }
  const MARGINS margins{-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd_, &margins);
  int backdrop = 3;  // DWMSBT_TRANSIENTWINDOW (acrylic)
  const HRESULT hr = DwmSetWindowAttribute(
      hwnd_, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, &backdrop, sizeof(backdrop));
  return SUCCEEDED(hr);
}
```

（`#include <dwmapi.h>` + 确认 runner 已链 dwmapi——主窗标题栏主题已用 DWM，CMake 大概率已链；没有则 target_link_libraries 加 `dwmapi`。）
6. **置顶切换**：新方法 `void SetTopmost(bool topmost)` → `SetWindowPos(hwnd_, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);`。

- [ ] 实现以上 6 点 → `flutter build windows --debug` 编译链接通过（此 task 仅泛化，行为零变化：默认值全等旧行为）
- [ ] Commit `refactor(global-lookup): multi-instance-safe window class + dismiss-hook/user-data options + drag/backdrop/topmost plumbing`

### Task 7: flutter_window 第二实例 + `clipboard_panel` channel

**Files:**
- Modify: `hibiki/windows/runner/flutter_window.h`（:71-74 平行加 `clipboard_panel_channel_` / `clipboard_panel_window_` / `RegisterClipboardPanelChannel()`）
- Modify: `hibiki/windows/runner/flutter_window.cpp`（:536 旁调用；照抄 :801-987 改名）

要点：channel 名 `app.hibiki.reader/clipboard_panel`；构造后 `SetArmDismissHooks(false)` + `SetUserDataLeaf(L"ClipboardPanelWebView2")`；4 回调全留（面板渲染同款词典卡，getMedia/jsMessage/nativeError/overlayHidden 都要）；handler 集 = 查词窗全集 + 新增 `applyBackdrop`（调 `ApplySystemBackdrop()` 返回 bool）+ `setPinned`（bool → `SetTopmost`）。

- [ ] 实现 → `flutter build windows --debug` 通过
- [ ] Commit `feat(clipboard-panel): second overlay window instance + clipboard_panel channel (native)`

### Task 8: Dart channel 抽象 `OverlayWindowChannel`

**Files:**
- Create: `hibiki/lib/src/lookup/overlay_window_channel.dart`（把 `global_lookup_channel.dart` 的方法体搬成实例类，构造收 `MethodChannel`；额外 `applyBackdrop()`/`setPinned(bool)`）
- Modify: `hibiki/lib/src/lookup/global_lookup_channel.dart`（静态 API 保持字节级签名不变，逐一委托 `static final OverlayWindowChannel _impl = OverlayWindowChannel(HibikiChannels.globalLookup);`——1729 行 controller 零改动）
- Modify: `hibiki/lib/src/utils/misc/channel_constants.dart`（加 `clipboardPanel` channel 常量，仿 `globalLookup` 现有写法）
- Test: `hibiki/test/lookup/overlay_window_channel_test.dart`（`TestDefaultBinaryMessenger` mock 两条 channel 互不串线；`GlobalLookupChannel.hide` 走 global_lookup channel 名）

- [ ] 失败测试 → 实现 → 测试绿 + analyze
- [ ] Commit `refactor(lookup): extract instance OverlayWindowChannel; GlobalLookupChannel delegates`

### Task 9: host JS 面板模式 + 面板栏 + 句子条可点

**Files:**
- Modify: `hibiki/assets/popup/global_lookup_host.js`（档案 F#1-6 锚点：`layoutMode` 状态 ~:141；`renderStack` :999 读 `payload.layoutMode`；`applyShellStyle` :341-377 panel+root 分支写固定视口 rect 且 top 让出面板栏高度；`measureAndReport` :1037 panel 短路 return；`onHostPointerDown` :1293-1302 panel 下点空白不 `dismissRootWithSlide`；新 `createPanelBar()` 仿 `createCloseButton` :513-546——grip 区 mousedown → `postToHost('beginWindowDrag')`、pin 钮 → `postToHost('panelPin',[next])`、× 钮 → `postToHost('panelClose')`、右下 resize 角 → `postToHost('beginWindowResize')`，全部 `stopPropagation`；`ensureStyle` :245-320 加面板栏 CSS）
- Modify: `hibiki/assets/popup/popup.js`（:2673-2683 `buildGlobalLookupSentenceBanner` 改逐字 span，click → `callHandler('onLinkClick', 该字到句尾后缀, {x,y,width,height})`，复制 :1904-1914 kanji-tag 的既有范式；`stopPropagation` 保留）
- Modify: `hibiki/assets/popup/popup.css`（`.global-lookup-sentence-char { cursor:pointer }` + hover 高亮；`html.global-lookup body` :1232 规则加 `background: rgba(var(--hibiki-card-bg-rgb, 30,30,30), var(--hibiki-card-bg-alpha, 1));`）
- Test: `hibiki/test/lookup/global_lookup_host_panel_guard_test.dart`（源码守卫：host.js 含 `layoutMode`、panel 分支短路 `measureAndReport`；popup.css 含 `--hibiki-card-bg-alpha` 且默认 1）

契约红线：cascade 路径 payload 不带 `layoutMode` 键时行为字节级不变（transient/全局查词零回归）；面板栏只在 `layoutMode==='panel'` 时创建。

- [ ] 守卫测试 → 实现 → 测试绿
- [ ] Commit `feat(clipboard-panel): host panel layout mode + panel bar + clickable sentence banner`

### Task 10: render/settings 注入面板参数

**Files:**
- Modify: `hibiki/lib/src/lookup/global_lookup_render.dart`（`buildStackRenderScript` 加 `String layoutMode = 'cascade'` 参数，仅非 cascade 时写入 payload——cascade 载荷字节不变；`buildFrameSettingsJs` 加 `double cardBgAlpha = 1.0`，<1 时追加一行 `document.documentElement.style.setProperty('--hibiki-card-bg-alpha','<v>');`）
- Modify: `hibiki/lib/src/pages/implementations/popup_settings_injection.dart`（`_themeVariablesJs` :88 旁加 `--hibiki-card-bg-rgb` 三元组注入 + `_cssRgbTriplet` 辅助）
- Test: `hibiki/test/lookup/global_lookup_render_test.dart`（如已有则扩展）：cascade 调用产物不含 `layoutMode`/`card-bg-alpha`；panel 调用产物两者都含

- [ ] 失败测试 → 实现 → 绿 + analyze
- [ ] Commit `feat(clipboard-panel): renderStack layoutMode + card bg alpha variables`

### Task 11: `ClipboardPanelController` + 桥共享抽取 + dispatcher 接管 panel

**Files:**
- Create: `hibiki/lib/src/lookup/clipboard_panel_controller.dart`
- Modify: `hibiki/lib/src/lookup/global_lookup_controller.dart`（抽共享，见红线）
- Modify: `hibiki/lib/src/lookup/desktop_lookup_dispatcher.dart`（panel 分支 → `ClipboardPanelController.instance.update(request)`）
- Modify: `hibiki/lib/main.dart`（桌面块内 `ClipboardPanelController.instance.start(appModel: appModel)`）
- Modify: `hibiki/lib/src/settings/settings_schema_lookup.dart`（destination 分段项加 panel 段）
- i18n: `desktop_clipboard_destination_panel` 已在 Task 5 加过——无新键
- Test: `hibiki/test/lookup/clipboard_panel_controller_test.dart`（rect 解析/clamp 纯函数、paused 语义、update 时 stack 重置）

**桥共享红线（禁止复制 9-handler 块）**：`GlobalLookupController._onJsMessage` 的 DEFERRED 桥处理（resolveWordAudio/queryLocalAudio/playWordAudio/favoriteEntry/favoriteCheck/mineEntry/duplicateCheck/overwriteTargetNoteId/updateEntry，controller.dart:963-1252 一带）抽成 `overlay_bridge_handlers.dart` 共享函数（参数：AppModel + `Future<void> Function(int id, Object? value)` resolveBridge + 当前帧 result 查找回调），两 controller 各以自己的 channel/栈状态调用。嵌套栈同理：面板复用 `GlobalLookupStack`/`computeFrameRect`（边界=面板 rect），实现时若发现 controller 栈编排无法低风险抽取，面板 M2 先做 root+嵌套点词（onLinkClick → 面板内子卡），制卡/收藏桥必须共享、不许复制。

Controller 骨架契约：
- `start`: setHandlers + prepare(assetsDir 同 controller `_popupAssetsDir` 范式) + prewarmWebView + `_backdropOk = await _channel.applyBackdrop()`（показAt 后调更稳则移进首次 show）。
- `update(DesktopLookupRequest r)`: paused→仅 origin==hotkey 才解除暂停并继续；`searchDictionary(searchTerm: r.text)`；`buildStackRenderScript(layoutMode:'panel', sentence: r.text, cardBgAlpha: _backdropOk ? appModel.clipboardPanelOpacity : 1.0)`；未显示→`showAt(x,y,w,h)`（rect 来自 pref 解析/默认右侧 380×520，clamp 工作区）+`reveal(w,h)`+`setPinned(pref)`；已显示→仅 `render`。
- jsMessage: `windowMoved` → 存 rect pref；`panelPin` → `setPinned`+存 pref；`panelClose` → `hide(notify:false)`+`paused=true`；`onLinkClick/textSelected` → 面板内嵌套子卡；`overlaySize` → 忽略（panel 模式 host 已短路，防御性丢弃）。
- rect 解析纯函数：`Rect? parseClipboardPanelRect(String)` + `Rect clampPanelRect(Rect, Rect work)` 放 controller 文件顶部，直接单测。

- [ ] 失败测试 → 实现 → 绿 + analyze + `flutter build windows --debug`
- [ ] Commit `feat(clipboard-panel): panel controller + shared overlay bridge + panel destination live`

---

## M3 — 交互打磨（拖动/图钉/暂停/透明度已在 M2 布线，此处收尾）

### Task 12: 透明度滑杆设置项 + backdrop 门控

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema_lookup.dart`（仿 :367-390 `SettingsSliderItem` 写 `lookup.clipboard_panel_opacity`：min 0.5 / max 1.0 / divisions 50 / step 0.05 / label 百分比；visible = destination==panel && `ClipboardPanelController.instance.backdropOk`）
- i18n: `clipboard_panel_opacity`(Panel opacity/面板不透明度) + `clipboard_panel_opacity_hint`(Background opacity of the floating lookup panel/悬浮查词面板的卡片背景不透明度)
- onChanged → `setClipboardPanelOpacity` + `ClipboardPanelController.instance.refreshOpacity()`（重渲 root 使 alpha 生效）

- [ ] 实现 + analyze + Commit `feat(clipboard-panel): opacity slider gated by backdrop support`

### Task 13: Ctrl+Shift+D 重唤面板 + hotkey 语义核对

已由 Task 11 `update` 的 `origin==hotkey 解除暂停` 覆盖；本 task 补测试：dispatcher 测试加「paused 面板 + hotkey 请求 → 面板恢复」用例（经 `ClipboardPanelController.paused` 断言）。

- [ ] 测试 + Commit `test(clipboard-panel): hotkey re-show semantics`

---

## M4 — 全量验证 + 真机 gate + 交付

### Task 14: 全量离屏验证
- [ ] `dart format .`（hibiki/ 下改动文件）
- [ ] `flutter analyze`（**全量含 test，零 warning**——CI 把 warning 当致命）
- [ ] `flutter test`（全量；对照基线 develop 预存红名单，不新增红）
- [ ] `flutter build windows --debug` 最终编译
- [ ] Commit 余项 + 更新 claim

### Task 15: 真机 gate（`tool/run_windows_itest.ps1` + observe_capture 离屏抓像素）
- [ ] **半透明 gate（spec §6/M0）**：面板下垫高对比背景截图，验证 acrylic backdrop 是否真透出（`applyBackdrop` 返回值 + 像素证据）；失败 → slider 保持隐藏、面板不透明，记录进 spec 修订
- [ ] 面板显示/复制更新不闪/句子条点词嵌套/发音/制卡按钮
- [ ] 拖动+位置记忆（windowMoved→pref→重启恢复）；**拖动期间 VN 流推送**（native 模态移动循环与渲染并发，审查建议）
- [ ] 图钉切换、×暂停、Ctrl+Shift+D 重唤
- [ ] transient 去向：复制→光标处弹卡→点外收
- [ ] 泄漏根修：Ctrl+Alt+D 后主窗 tab/面板无假更新（含 captured 回声先到时序——括号方案见 spec §8 修订）
- [ ] **面板内嵌套卡贴面板栏的 clamp**（anchor 坐标域含 28px 栏偏移，审查建议）
- [ ] 证据存 `.codex-test/`（不入库），结果写回 spec「验证记录」节

### Task 16: 交付
- [ ] spec 状态行更新（含 backdrop gate 结果）；如有行为偏差补决策记录
- [ ] push 分支 + 更新 PR #13（改标题为 feat，正文附验证证据摘要）
- [ ] `superpowers:requesting-code-review` 流程（repo 强制步骤 3）
- [ ] claim 移交 integration owner（合并回 develop 由 owner 统一做，本分支不自行 rebase develop）

---

## 自审记录

- **Spec 覆盖**：§4 数据流=Task 3/5/11；§5 交互=Task 6/9/11/13；§6 半透明=Task 6(5)/10/12/15；§7 设置与生命周期=Task 1/4/5/12；§8 泄漏=Task 2；§9 测试=各 task Step + Task 14/15；§10 里程碑映射 M0→Task 15 首项（spike 载体在 Task 6/7 的 applyBackdrop）。
- **类型一致性**：`DesktopClipboardDestination`（Task 1）被 3/4/5/11 引用同名；`resolveDesktopLookupConsumer` 签名 3=4=5；`OverlayWindowChannel`（Task 8）被 11 引用；`clipboardIgnores`（Task 2）命名与 selection_capture 调用一致。
- **无占位符**：M2 native/JS 任务以档案 file:line 锚点+关键代码给出，机械复制段（RegisterClipboardPanelChannel 照抄 :801-987）不重复全文——原文即真相源，复制指令明确。
- **风险**：① backdrop gate 可能失败（降级路径已定义，不阻塞其余交付）；② `GlobalLookupController` 桥抽取范围到实现时才能定界（红线：不许复制 9-handler 块）；③ HomeDictionaryPage 生命周期改动可能碰既有 widget 测试（Task 4 Step 3 全量跑）。
