# 全局查词（裸 WebView2 覆盖窗）实现计划 · TODO-617

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在任意外部 app 选中文字后按全局热键，于光标处弹出 Hibiki 词典卡片，不打扰外部 app；Windows MVP。

**Architecture:** 主 Flutter 窗口当「词典大脑」（HoshiDicts FFI + AppModel + DB + 全局热键），新增一个裸 Win32 分层置顶不激活窗口承载 WebView2 控件渲染现有 `popup.html`。Dart 经一条新 MethodChannel 把 `popupJson` 推进 WebView2、并回应 `image://` 外字图与发音回调。不起第二个 Flutter engine。

**Tech Stack:** Flutter Windows runner（C++17）、WebView2（NuGet `Microsoft.Web.WebView2` 1.0.2792.45）、`flutter::MethodChannel`、Dart `dart:ffi`（user32/kernel32）、现有 `popup.html/js/css`。

**Design spec:** `docs/specs/2026-06-25-global-lookup-webview-overlay-design.md`

---

## 关于测试方法的诚实说明

本计划大量是 native C++（WebView2 窗口）+ FFI，无法走经典 TDD 红-绿。分层处理：
- **纯 Dart 逻辑**（选区抓取的剪贴板存取/还原、bridge adapter 的 JS 映射）→ 单元测试。
- **bridge adapter JS** → node/JS 单测。
- **native WebView2 渲染 / image:// / 发音** → 真机构建 + 焦点驱动集成测试 + 截图取证（见 `docs/agent/integration-testing.md`）。
- **架构约束** → 源码扫描守卫（NOACTIVATE flag 存在、热键仅 keyDown、不引入 tray/第二 engine）。

M0 是降风险打样：先证明三个未验证假设成立，再展开 M1–M4。**M0 完成后有一个决策门（Gate），其结论可能微调 M1–M4 细节。**

---

## 文件结构

### 新增
| 文件 | 职责 |
|---|---|
| `hibiki/windows/runner/global_lookup_window.h/.cpp` | 裸 Win32 窗 + WebView2 控件；载 popup.html、image:// 拦截、收 JS postMessage、show/hide/render |
| `hibiki/lib/src/lookup/global_lookup_channel.dart` | Dart↔native channel 封装（show/hide/render/getMedia/audio + 反向事件） |
| `hibiki/lib/src/lookup/global_lookup_controller.dart` | 编排：热键→抓选区→查词→推送→收起（M1+） |
| `hibiki/lib/src/lookup/selection_capture_ffi.dart` | SendInput 注入 Ctrl+C + 剪贴板存取/还原（M1） |
| `hibiki/assets/reader/popup_bridge_adapter.js` | 把 `flutter_inappwebview.callHandler` 映射到 `chrome.webview.postMessage` |
| `hibiki/test/lookup/selection_capture_test.dart` | 剪贴板存取/还原单测 |
| `hibiki/test/lookup/global_lookup_guard_test.dart` | 源码扫描守卫 |
| `hibiki/test/lookup/popup_bridge_adapter_test.mjs`（或 dart node 调用）| adapter JS 单测 |

### 修改
| 文件 | 改动 |
|---|---|
| `hibiki/windows/runner/flutter_window.h` | 加 `global_lookup_channel_` / `global_lookup_window_` 成员 + `RegisterGlobalLookupChannel()` 声明 |
| `hibiki/windows/runner/flutter_window.cpp` | `OnCreate()` 调 `RegisterGlobalLookupChannel()`；新增其定义 |
| `hibiki/windows/runner/CMakeLists.txt` | 源文件加 `global_lookup_window.cpp`；链 WebView2 `.targets` + WIL + `Shlwapi.lib` |
| `hibiki/lib/src/utils/misc/channel_constants.dart` | 加 `globalLookup` channel 常量 |
| `hibiki/pubspec.yaml` | `assets/reader/popup_bridge_adapter.js` 入 assets（若 popup 资源目录未整目录纳入）|

---

## Phase M0：打样 — 裸 WebView2 覆盖窗渲染 popup.html + image:// 外字图

**M0 目标（验证设计 §7 的三个风险）：** 一个裸 Win32 窗里 WebView2 加载现有 `popup.html`，注入一段**真实导出的 `popupJson`** 渲染出和 app 内一致的卡片，且 `image://` 外字图能经 Dart 回灌字节显示出来。

### Task 0.1：WebView2 SDK 接入 runner 构建

**Files:**
- Modify: `hibiki/windows/runner/CMakeLists.txt`

- [ ] **Step 1: 在 runner CMakeLists 顶部加 WebView2 / WIL NuGet 拉取**

照抄 `packages/flutter_inappwebview_windows/windows/CMakeLists.txt:7-37` 的版本与 nuget install 写法，钉同一版本避免 ABI 不一致：

```cmake
# --- WebView2 SDK (match flutter_inappwebview_windows fork: 1.0.2792.45) ---
set(WEBVIEW_VERSION "1.0.2792.45")
set(WIL_VERSION "1.0.231216.1")
find_program(NUGET_EXE NAMES nuget PATHS ${CMAKE_BINARY_DIR})
if(NOT NUGET_EXE)
  message(FATAL_ERROR "nuget.exe not found; install or place in build dir")
endif()
execute_process(COMMAND ${NUGET_EXE} install Microsoft.Web.WebView2
  -Version ${WEBVIEW_VERSION} -ExcludeVersion
  -OutputDirectory ${CMAKE_BINARY_DIR}/packages)
execute_process(COMMAND ${NUGET_EXE} install Microsoft.Windows.ImplementationLibrary
  -Version ${WIL_VERSION} -ExcludeVersion
  -OutputDirectory ${CMAKE_BINARY_DIR}/packages)
```

- [ ] **Step 2: 把 global_lookup_window.cpp 加入可执行源列表，链接 SDK**

在 `add_executable(${BINARY_NAME} ... )` 源文件列表里追加 `"global_lookup_window.cpp"`（仿现有 `"floating_lyric_window.cpp"`），并在该 target 的 `target_link_libraries` 加：

```cmake
target_link_libraries(${BINARY_NAME} PRIVATE
  ${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/Microsoft.Web.WebView2.targets)
target_link_libraries(${BINARY_NAME} PRIVATE
  ${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary/build/native/Microsoft.Windows.ImplementationLibrary.targets)
target_link_libraries(${BINARY_NAME} PRIVATE Shlwapi.lib)
```

- [ ] **Step 3: 验证构建系统能解析（先放一个空 cpp）**

先创建 `global_lookup_window.cpp` 只含 `#include "global_lookup_window.h"`（下一 Task 填实），`global_lookup_window.h` 含空类声明。
Run（在 `hibiki/android` 同级的 hibiki 工程下）：`flutter build windows --debug`
Expected: 配置阶段无 nuget/链接错误（编译到空类通过）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/windows/runner/CMakeLists.txt hibiki/windows/runner/global_lookup_window.h hibiki/windows/runner/global_lookup_window.cpp
git commit -m "build(windows): wire WebView2 SDK into runner for global lookup overlay"
```

### Task 0.2：裸 Win32 窗口骨架（class + CreateWindowEx + WndProc）

**Files:**
- Modify: `hibiki/windows/runner/global_lookup_window.h`
- Modify: `hibiki/windows/runner/global_lookup_window.cpp`

照抄 `floating_lyric_window.cpp` 的窗口生命周期骨架（勘察报告 §1.1/1.2/1.5），**去掉 `WS_EX_LAYERED`**（WebView2 自带合成表面，与 layered 冲突），保留 `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`。

- [ ] **Step 1: 头文件声明**

```cpp
#pragma once
#include <windows.h>
#include <functional>
#include <string>
#include <vector>

class GlobalLookupWindow {
 public:
  GlobalLookupWindow();
  ~GlobalLookupWindow();

  bool ShowAt(int x, int y, int width, int height, HWND owner);
  void Hide();
  bool IsShowing() const;
  void Navigate(const std::wstring& url);
  void RenderJson(const std::string& popup_json);  // ExecuteScript: window.renderPopup(json)

  // native -> Dart 回调
  using MediaCallback = std::function<std::vector<uint8_t>(const std::string& url)>;
  using MessageCallback = std::function<void(const std::string& json)>;
  void SetMediaCallback(MediaCallback cb) { media_cb_ = std::move(cb); }
  void SetMessageCallback(MessageCallback cb) { message_cb_ = std::move(cb); }

 private:
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM) noexcept;
  LRESULT HandleMessage(UINT, WPARAM, LPARAM);
  void EnsureWindowClass();
  void EnsureWebView();   // Task 0.3

  HWND hwnd_ = nullptr;
  bool visible_ = false;
  bool class_registered_ = false;
  MediaCallback media_cb_;
  MessageCallback message_cb_;
  // WebView2 成员在 Task 0.3 加
};
```

- [ ] **Step 2: 实现 class 注册 + ShowAt 的 CreateWindowEx**

```cpp
namespace { constexpr wchar_t kClassName[] = L"HibikiGlobalLookupWindow"; }

void GlobalLookupWindow::EnsureWindowClass() {
  if (class_registered_) return;
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = GlobalLookupWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);
  class_registered_ = true;
}

bool GlobalLookupWindow::ShowAt(int x, int y, int width, int height, HWND owner) {
  EnsureWindowClass();
  if (hwnd_ == nullptr) {
    hwnd_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kClassName, L"Hibiki Lookup", WS_POPUP, x, y, width, height,
        nullptr, nullptr, GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) return false;
    EnsureWebView();  // Task 0.3
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
  }
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  visible_ = true;
  return true;
}
```

- [ ] **Step 3: Hide / IsShowing / 析构 / WndProc 骨架**

```cpp
void GlobalLookupWindow::Hide() {
  visible_ = false;
  if (hwnd_ != nullptr) ShowWindow(hwnd_, SW_HIDE);
}
bool GlobalLookupWindow::IsShowing() const {
  return visible_ && hwnd_ != nullptr && IsWindowVisible(hwnd_);
}
GlobalLookupWindow::GlobalLookupWindow() = default;
GlobalLookupWindow::~GlobalLookupWindow() {
  if (hwnd_ != nullptr) { DestroyWindow(hwnd_); hwnd_ = nullptr; }
  if (class_registered_) UnregisterClassW(kClassName, GetModuleHandle(nullptr));
}

LRESULT CALLBACK GlobalLookupWindow::WndProc(HWND hwnd, UINT msg,
                                             WPARAM wp, LPARAM lp) noexcept {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lp);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    auto* self = static_cast<GlobalLookupWindow*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, msg, wp, lp);
  }
  auto* self = reinterpret_cast<GlobalLookupWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  return self ? self->HandleMessage(msg, wp, lp) : DefWindowProc(hwnd, msg, wp, lp);
}

LRESULT GlobalLookupWindow::HandleMessage(UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_SIZE:
      // Task 0.3: controller_->put_Bounds(client_rect)
      return 0;
    default:
      return DefWindowProc(hwnd_, msg, wp, lp);
  }
}
```

- [ ] **Step 4: 构建通过**

Run: `flutter build windows --debug`
Expected: 编译链接通过（窗口尚未显示内容）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/windows/runner/global_lookup_window.h hibiki/windows/runner/global_lookup_window.cpp
git commit -m "feat(windows): bare Win32 topmost-noactivate window skeleton for global lookup"
```

### Task 0.3：WebView2 控件创建 + 加载 popup.html

**Files:**
- Modify: `hibiki/windows/runner/global_lookup_window.h/.cpp`

照抄勘察报告 §1（headless 非 composition 路径）：`CreateCoreWebView2EnvironmentWithOptions` → `CreateCoreWebView2Controller(hwnd_)` → `put_IsVisible(true)` + `put_Bounds`。popup 资源用 `SetVirtualHostNameToFolderMapping` 映射到一个虚拟主机，避免 `file://` 相对路径问题。

- [ ] **Step 1: 头文件加 WebView2 成员与包含**

```cpp
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/com.h>
#include <wrl.h>
// 成员：
wil::com_ptr<ICoreWebView2Environment> env_;
wil::com_ptr<ICoreWebView2Controller> controller_;
wil::com_ptr<ICoreWebView2> webview_;
bool webview_ready_ = false;
std::string pending_json_;  // webview 未就绪时缓存待渲染 json
```

- [ ] **Step 2: EnsureWebView 实现（含自定义 scheme 注册占位，image:// 在 Task 0.4 接）**

```cpp
using namespace Microsoft::WRL;
void GlobalLookupWindow::EnsureWebView() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  auto options = Make<CoreWebView2EnvironmentOptions>();
  // Task 0.4: QI ICoreWebView2EnvironmentOptions4 + SetCustomSchemeRegistrations("image")
  CreateCoreWebView2EnvironmentWithOptions(
      nullptr, nullptr, options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [this](HRESULT, ICoreWebView2Environment* env) -> HRESULT {
          env_ = env;
          env_->CreateCoreWebView2Controller(hwnd_,
            Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [this](HRESULT, ICoreWebView2Controller* ctrl) -> HRESULT {
                controller_ = ctrl;
                controller_->get_CoreWebView2(&webview_);
                controller_->put_IsVisible(TRUE);
                RECT rc; GetClientRect(hwnd_, &rc);
                controller_->put_Bounds(rc);
                ConfigureWebView();  // Task 0.4/0.5：scheme 过滤、postMessage、adapter 注入
                // 虚拟主机映射 popup 资源目录（运行时实际目录见 Step 3）
                wil::com_ptr<ICoreWebView2_3> wv3;
                if (SUCCEEDED(webview_->QueryInterface(IID_PPV_ARGS(&wv3)))) {
                  wv3->SetVirtualHostNameToFolderMapping(
                      L"hibiki.popup", popup_assets_dir_.c_str(),
                      COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                }
                webview_->Navigate(L"https://hibiki.popup/popup.html");
                webview_ready_ = true;
                if (!pending_json_.empty()) { RenderJson(pending_json_); pending_json_.clear(); }
                return S_OK;
              }).Get());
          return S_OK;
        }).Get());
}
```

- [ ] **Step 3: popup 资源目录来源**

popup.html/js/css 在 Flutter assets（`hibiki/lib/src/reader/` 或 `assets/`）。构建产物里位于 `<exe_dir>/data/flutter_assets/...`。`ShowAt` 前由 channel 从 Dart 传入绝对目录（`rootBundle` 解析的实际路径），或 native 用 `GetModuleFileName` 推 `data/flutter_assets/<popup_dir>`。**Task 0.5 的 channel `prepare` 方法把该目录传进来设 `popup_assets_dir_`。**

- [ ] **Step 4: WM_SIZE 同步 WebView2 bounds**

把 `HandleMessage` 的 `WM_SIZE` 分支改为：
```cpp
case WM_SIZE:
  if (controller_) { RECT rc; GetClientRect(hwnd_, &rc); controller_->put_Bounds(rc); }
  return 0;
```

- [ ] **Step 5: 构建 + 临时硬编码 ShowAt 自测**

临时在 `flutter_window.cpp::OnCreate()` 末尾加一行 `global_lookup_window_->ShowAt(200,200,420,600, GetHandle());`（自测后删）。
Run: `flutter build windows --debug` 后运行 exe。
Expected: 屏幕 (200,200) 出现一个无边框置顶窗，显示 popup.html 的空壳（无数据时的占位）。截图取证。

- [ ] **Step 6: Commit**

```bash
git add hibiki/windows/runner/global_lookup_window.h hibiki/windows/runner/global_lookup_window.cpp
git commit -m "feat(windows): host WebView2 in global lookup window, load popup.html via virtual host"
```

### Task 0.4：image:// 自定义协议拦截 → Dart 回灌外字图字节

**Files:**
- Modify: `hibiki/windows/runner/global_lookup_window.cpp`

照抄勘察报告 §2：环境选项 `SetCustomSchemeRegistrations` 注册 `image` + `AddWebResourceRequestedFilter(L"*", ...ALL)` + `add_WebResourceRequested`，回调里 `GetDeferral` → 经 `media_cb_`（Dart）拿字节 → `CreateWebResourceResponse` → `put_Response` → `Complete`。

- [ ] **Step 1: 环境选项注册 image scheme（补 Task 0.3 Step 2 的占位）**

```cpp
wil::com_ptr<ICoreWebView2EnvironmentOptions4> options4;
if (SUCCEEDED(options.As(&options4))) {
  auto reg = Make<CoreWebView2CustomSchemeRegistration>(L"image");
  reg->put_TreatAsSecure(TRUE);
  reg->put_HasAuthorityComponent(TRUE);
  ICoreWebView2CustomSchemeRegistration* regs[] = { reg.Get() };
  options4->SetCustomSchemeRegistrations(1, regs);
}
```

- [ ] **Step 2: ConfigureWebView 里注册资源拦截**

```cpp
void GlobalLookupWindow::ConfigureWebView() {
  webview_->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  webview_->add_WebResourceRequested(
    Callback<ICoreWebView2WebResourceRequestedEventHandler>(
      [this](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
        wil::com_ptr<ICoreWebView2WebResourceRequest> req;
        args->get_Request(&req);
        wil::unique_cotaskmem_string uri; req->get_Uri(&uri);
        std::string url = wide_to_utf8(uri.get());
        if (url.rfind("image://", 0) != 0) return S_OK;  // 只管 image://
        wil::com_ptr<ICoreWebView2Deferral> deferral;
        args->GetDeferral(&deferral);
        std::vector<uint8_t> bytes = media_cb_ ? media_cb_(url) : std::vector<uint8_t>{};
        wil::com_ptr<IStream> stream =
            SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size()));
        wil::com_ptr<ICoreWebView2WebResourceResponse> resp;
        env_->CreateWebResourceResponse(stream.get(), bytes.empty() ? 404 : 200,
            bytes.empty() ? L"Not Found" : L"OK", L"Content-Type: image/png", &resp);
        args->put_Response(resp.get());
        deferral->Complete();
        return S_OK;
      }).Get(), nullptr);
}
```

> 注：`media_cb_` 是同步签名，但它内部要等 Dart 异步返回。实现时 `media_cb_` 由 `flutter_window.cpp` 用 channel `invokeMethod` + 在 platform 线程上以一个有界等待（或把 deferral 句柄交给异步回调后 Complete）完成。**Task 0.5 决定同步桥还是异步 deferral 持有**；推荐异步：把 `deferral` 存入 map、channel result 回来时再 `Complete`，避免阻塞消息循环。`wide_to_utf8` 复用 fork 里的工具或自写 `WideCharToMultiByte`。

- [ ] **Step 3: 构建 + 用带外字图的真实词典词截图验证**（接 Task 0.7）

本 Task 不单独跑端到端，外字图验证并入 Task 0.7。先确保编译通过。
Run: `flutter build windows --debug`
Expected: 编译链接通过。

- [ ] **Step 4: Commit**

```bash
git add hibiki/windows/runner/global_lookup_window.cpp
git commit -m "feat(windows): intercept image:// in global lookup webview, route bytes from Dart"
```

### Task 0.5：channel 注册（flutter_window.cpp）+ Dart 侧封装

**Files:**
- Modify: `hibiki/windows/runner/flutter_window.h/.cpp`
- Modify: `hibiki/lib/src/utils/misc/channel_constants.dart`
- Create: `hibiki/lib/src/lookup/global_lookup_channel.dart`

照抄勘察报告 §2.5 的 `RegisterFloatingLyricChannel` 骨架。channel 名 `app.hibiki.reader/global_lookup`。

- [ ] **Step 1: channel 常量**

`channel_constants.dart` 仿现有 `floatingLyric` 加：
```dart
static const MethodChannel globalLookup =
    MethodChannel('$_prefix/global_lookup');
```

- [ ] **Step 2: flutter_window.h 成员**

```cpp
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> global_lookup_channel_;
std::unique_ptr<GlobalLookupWindow> global_lookup_window_;
void RegisterGlobalLookupChannel();
```
并 `#include "global_lookup_window.h"`。

- [ ] **Step 3: flutter_window.cpp 注册（OnCreate 调用 + 定义）**

`OnCreate()` 在 `RegisterFloatingLyricChannel();` 旁加 `RegisterGlobalLookupChannel();`。定义（方法：`prepare`/`showAt`/`hide`/`isShowing`/`render`；反向 `getMedia`/`jsMessage`）：

```cpp
void FlutterWindow::RegisterGlobalLookupChannel() {
  global_lookup_window_ = std::make_unique<GlobalLookupWindow>();
  global_lookup_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "app.hibiki.reader/global_lookup",
      &flutter::StandardMethodCodec::GetInstance());

  // image:// -> 同步阻塞向 Dart 取字节（MVP；如卡顿改异步 deferral）
  global_lookup_window_->SetMediaCallback([this](const std::string& url) -> std::vector<uint8_t> {
    // 经 channel 向 Dart invokeMethod("getMedia", {url})，等结果。
    // 实现细节：用 std::promise + InvokeMethod 的 result 回调 set_value（同在 platform 线程，
    // 用 PeekMessage 泵循环等待），或改为把 deferral 存 map 异步 Complete。见 Task 0.4 Step 2 注。
    return RequestMediaFromDart(url);  // 辅助函数，封装上述等待
  });
  global_lookup_window_->SetMessageCallback([this](const std::string& json) {
    global_lookup_channel_->InvokeMethod("jsMessage",
        std::make_unique<flutter::EncodableValue>(json));
  });

  global_lookup_channel_->SetMethodCallHandler(
    [this](const auto& call, auto result) {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const std::string& m = call.method_name();
      if (m == "prepare") {
        global_lookup_window_->SetPopupAssetsDir(WideFromValue(args, "assetsDir", L""));
        result->Success();
      } else if (m == "showAt") {
        const bool ok = global_lookup_window_->ShowAt(
            IntFromValue(args, "x", 0), IntFromValue(args, "y", 0),
            IntFromValue(args, "width", 420), IntFromValue(args, "height", 600),
            GetHandle());
        result->Success(flutter::EncodableValue(ok));
      } else if (m == "render") {
        global_lookup_window_->RenderJson(StringFromValue(args, "json", ""));
        result->Success();
      } else if (m == "hide") {
        global_lookup_window_->Hide(); result->Success();
      } else if (m == "isShowing") {
        result->Success(flutter::EncodableValue(global_lookup_window_->IsShowing()));
      } else {
        result->NotImplemented();
      }
    });
}
```
复用匿名 namespace 的 `IntFromValue`/`WideFromValue` 解析器（`flutter_window.cpp:280-382`）；如缺 `StringFromValue` 则新增一个 UTF-8 版本。

- [ ] **Step 4: Dart channel 封装**

`global_lookup_channel.dart`：
```dart
import 'package:flutter/services.dart';
import '../utils/misc/channel_constants.dart';

class GlobalLookupChannel {
  static final MethodChannel _ch = HibikiChannels.globalLookup;
  static Future<void>? _handlerSet;

  static Future<void> prepare(String assetsDir) =>
      _ch.invokeMethod('prepare', {'assetsDir': assetsDir});
  static Future<bool> showAt({required int x, required int y,
      int width = 420, int height = 600}) async =>
      (await _ch.invokeMethod<bool>('showAt',
          {'x': x, 'y': y, 'width': width, 'height': height})) ?? false;
  static Future<void> render(String popupJson) =>
      _ch.invokeMethod('render', {'json': popupJson});
  static Future<void> hide() => _ch.invokeMethod('hide');

  static void setHandlers({
    required Future<Uint8List> Function(String url) onGetMedia,
    required void Function(Map<String, dynamic> msg) onJsMessage,
  }) {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'getMedia':
          final url = (call.arguments as Map)['url'] as String;
          return await onGetMedia(url);
        case 'jsMessage':
          onJsMessage(_decode(call.arguments));
          return null;
      }
      return null;
    });
  }
  // _decode: jsonDecode(call.arguments as String)
}
```

- [ ] **Step 5: 构建通过**

Run: `flutter build windows --debug`
Expected: 编译链接通过。

- [ ] **Step 6: Commit**

```bash
git add hibiki/windows/runner/flutter_window.h hibiki/windows/runner/flutter_window.cpp hibiki/lib/src/utils/misc/channel_constants.dart hibiki/lib/src/lookup/global_lookup_channel.dart
git commit -m "feat: global lookup channel (Dart<->native) for overlay show/render/getMedia"
```

### Task 0.6：bridge adapter + RenderJson 执行脚本

**Files:**
- Create: `hibiki/assets/reader/popup_bridge_adapter.js`
- Create: `hibiki/test/lookup/popup_bridge_adapter_test.mjs`
- Modify: `hibiki/windows/runner/global_lookup_window.cpp`（`ConfigureWebView` 注入 adapter + `add_WebMessageReceived`；`RenderJson` 用 `ExecuteScript`）

popup.js 调 `window.flutter_inappwebview.callHandler(name, ...args)`。裸 WebView2 没有这个全局，需注入 adapter 映射到 `window.chrome.webview.postMessage`。

- [ ] **Step 1: 写 adapter 失败测试（先定契约）**

`popup_bridge_adapter_test.mjs`（node 跑）：模拟 `window.chrome.webview.postMessage`，加载 adapter，断言 `callHandler('playWordAudio', {term:'favour'})` 触发一条 `{handler:'playWordAudio', args:[{term:'favour'}], id:<n>}` 的 postMessage，并验证 `resolveWordAudio` 的回值 Promise 能被 native 回灌（`window.__hibikiResolve(id, value)`）解决。

```js
// 期望 adapter 暴露：window.flutter_inappwebview.callHandler(name, ...args) -> Promise
// 期望 native 回值入口：window.__hibikiBridgeResolve(id, jsonValue)
import assert from 'node:assert';
// ... 装 fake window/chrome.webview, import adapter source, 跑断言
```
Run: `node hibiki/test/lookup/popup_bridge_adapter_test.mjs`
Expected: FAIL（adapter 不存在）。

- [ ] **Step 2: 写 adapter**

```js
// popup_bridge_adapter.js
(function () {
  let _seq = 0;
  const _pending = new Map();
  window.flutter_inappwebview = window.flutter_inappwebview || {};
  window.flutter_inappwebview.callHandler = function (name) {
    const args = Array.prototype.slice.call(arguments, 1);
    const id = ++_seq;
    return new Promise(function (resolve) {
      _pending.set(id, resolve);
      window.chrome.webview.postMessage(JSON.stringify({ handler: name, args: args, id: id }));
    });
  };
  window.__hibikiBridgeResolve = function (id, jsonValue) {
    const r = _pending.get(id);
    if (r) { _pending.delete(id); r(jsonValue === undefined ? null : JSON.parse(jsonValue)); }
  };
})();
```
Run: `node hibiki/test/lookup/popup_bridge_adapter_test.mjs`
Expected: PASS。

- [ ] **Step 3: native 注入 adapter（document-start）+ 收 postMessage**

在 `ConfigureWebView` 加：
```cpp
// 注入 adapter（先于 popup.js 执行）
std::wstring adapter = LoadAdapterScript();  // 读 assets 的 popup_bridge_adapter.js
webview_->AddScriptToExecuteOnDocumentCreated(adapter.c_str(), nullptr);
// 收 JS postMessage
webview_->add_WebMessageReceived(
  Callback<ICoreWebView2WebMessageReceivedEventHandler>(
    [this](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
      wil::unique_cotaskmem_string json;
      if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && message_cb_)
        message_cb_(wide_to_utf8(json.get()));
      return S_OK;
    }).Get(), nullptr);
```

- [ ] **Step 4: RenderJson 用 ExecuteScript 调 popup 渲染**

```cpp
void GlobalLookupWindow::RenderJson(const std::string& json) {
  if (!webview_ready_) { pending_json_ = json; return; }
  std::wstring script = L"window.lookupEntries = " + utf8_to_wide(json) +
                        L"; window.renderPopup && window.renderPopup();";
  webview_->ExecuteScript(script.c_str(), nullptr);
}
```
> 注：实际注入键名/调用要对齐 `dictionary_popup_webview.dart:560/603` 的 `window.lookupEntries` + `window.renderPopup()`；M0 用从真机 dump 的一段 `popupJson` 验证键名一致。

- [ ] **Step 5: adapter 入 assets**

`pubspec.yaml` 确保 `assets/reader/popup_bridge_adapter.js`（或 popup 资源同目录）被打包。

- [ ] **Step 6: Commit**

```bash
git add hibiki/assets/reader/popup_bridge_adapter.js hibiki/test/lookup/popup_bridge_adapter_test.mjs hibiki/windows/runner/global_lookup_window.cpp hibiki/pubspec.yaml
git commit -m "feat: popup bridge adapter (callHandler->postMessage) + RenderJson via ExecuteScript"
```

### Task 0.7：M0 端到端打样验证（真机截图）

**Files:** 无新增（临时验证代码用后即删）

- [ ] **Step 1: 准备一段真实 popupJson**

在主 app 内查一个**带外字图**的词（如某汉字词典词），从 `dictionary_popup_webview` 加日志 dump 出 `result.popupJson` 存成 `test_popup.json`。

- [ ] **Step 2: 临时驱动覆盖窗渲染**

临时在 app 启动后调：
```dart
await GlobalLookupChannel.prepare(<flutter_assets popup 目录绝对路径>);
GlobalLookupChannel.setHandlers(
  onGetMedia: (url) async => await _resolveGaijiBytesFromHoshiDicts(url),  // 复用 HoshiDicts.getMediaFile
  onJsMessage: (m) => debugPrint('js: $m'),
);
await GlobalLookupChannel.showAt(x: 300, y: 300);
await GlobalLookupChannel.render(await rootBundle.loadString('test_popup.json'));
```

- [ ] **Step 3: 构建运行 + 截图取证**

Run: `flutter build windows --debug` 运行；或用 `tool/run_windows_itest.ps1` 离屏。
Expected（截图断言）：
1. (300,300) 出现无边框置顶窗，渲染出与 app 内一致的词典卡片（释义/频率/音高）。
2. **外字图正常显示**（image:// 经 Dart 回灌成功）。
3. 焦点不被夺走：先聚焦记事本，触发后记事本仍是前台（NOACTIVATE 生效）。

- [ ] **Step 4: 记录 M0 Gate 结论**

把三项截图与结论写入 `docs/specs/2026-06-25-global-lookup-webview-overlay-design.md` 的「风险」节（标记 ✅/⚠️）。**若 image:// 异步 deferral 或 adapter 键名有偏差，在此修正并更新 M1+ 细节。**

- [ ] **Step 5: 删除临时验证代码 + Commit**

```bash
git add -p   # 仅相关
git commit -m "test(windows): M0 spike verified — bare WebView2 renders popup card + gaiji via Dart"
```

### 🚪 M0 Gate（决策门）

M0 三项截图全绿 → 继续 M1。任一不成立（尤其 image:// 字节回灌或 NOACTIVATE 焦点）→ 停下，按实际现象回设计文档修订方案后再继续，不带病往下做。

---

## Phase M1：抓选区 + 全局热键 + 查词推送（结构）

**目标：** 全局热键 → 注入 Ctrl+C 抓外部 app 选区 → `AppModel.searchDictionary` → `popupJson` → `showAt(光标)` + `render`。

**Files:**
- Create: `hibiki/lib/src/lookup/selection_capture_ffi.dart`
- Create: `hibiki/lib/src/lookup/global_lookup_controller.dart`
- Create: `hibiki/test/lookup/selection_capture_test.dart`

**接口（锁定签名，供后续任务引用）：**
```dart
// selection_capture_ffi.dart
class SelectionCapture {
  /// 保存旧剪贴板 -> SendInput(Ctrl+C) -> 有界重试读剪贴板 -> 还原旧剪贴板。
  /// 返回前台选区文本；失败返回 null。注入期需抑制 clipboard_watcher 自触发。
  static Future<String?> captureForegroundSelection();
}
// global_lookup_controller.dart
class GlobalLookupController {
  Future<void> onHotKey();            // 抓选区->查词->showAt+render
  Future<Uint8List> resolveMedia(String imageUrl);  // HoshiDicts.getMediaFile
  void onJsMessage(Map<String, dynamic> msg);        // audio(M3)/制卡跳主app
}
```

**任务拆分：**
1. **selection_capture_ffi**：镜像 `desktop_foreground_guard.dart:54-72` 的 `DynamicLibrary.open('user32.dll')` 范式，新增 `SendInput`（构造 Ctrl down/C down/C up/Ctrl up 的 `INPUT` 数组）、剪贴板 `OpenClipboard/GetClipboardData(CF_UNICODETEXT)/SetClipboardData/EmptyClipboard/CloseClipboard`。读剪贴板复用 `desktop_lookup_service.dart:216-227` 的有界重试。**纯逻辑（剪贴板存/取/还原 + 注入抑制标记）抽函数单测**；SendInput 真注入靠 M1 集成测试。
2. **热键注册**：复用 `hotkey_manager` system scope（仅 keyDown，勘察 Q1 已确认无 keyUp），另设可配热键（区别于现 `desktop_lookup_service.dart:132-137` 的剪贴板查词热键），keyDown → `GlobalLookupController.onHotKey()`。
3. **controller 编排**：`onHotKey` = `captureForegroundSelection()` → 空则返回 → `appModel.searchDictionary(text)` → 取光标 `GetCursorPos`（经 channel 或 screen_retriever）→ `showAt` + `render(popupJson)`。`resolveMedia` 经 `HoshiDicts.instance.getMediaFile` 解析 `image://?dictionary=&path=`。
4. **prepare 接线**：app 启动桌面分支调 `GlobalLookupChannel.prepare(assetsDir)` + `setHandlers`（seed 一次，复用 popup WebView 常驻预热）。

**测试：** 选区抓取剪贴板存取/还原单测；端到端在记事本/Chrome 选词→热键→卡片出现（真机截图）；守卫扫描「热键仅 keyDown、未引入低级键盘钩子」。

---

## Phase M2：收起 + 还焦点（结构）

**目标：** Esc / 点卡外 / 再按热键 → hide + 把焦点还给触发前的前台窗。

**任务拆分：**
1. **记前台窗**：`onHotKey` 进入时 native `GetForegroundWindow()` 存 `prev_foreground_`（经 channel 或在 native 侧 ShowAt 时记）。
2. **Esc**：popup.js 监听 `keydown Esc` → `callHandler('dismiss')` → adapter→postMessage→native→`Hide()`。或 native 在 WebView2 收键。
3. **点卡外**：popup.js 已有 `tapOutside`（`dictionary_popup_webview.dart:800`）→ adapter→postMessage→`dismiss`。
4. **再按热键**：`onHotKey` 若 `isShowing()` 则 toggle 为 hide。
5. **还焦点**：`Hide()` 后 `SetForegroundWindow(prev_foreground_)`（user32 FFI / native 直接调）。
**测试：** 真机——触发后 Esc/点别处/再按键三路都收起且焦点回到原 app（截图 + 前台窗断言）；守卫扫描覆盖窗带 `WS_EX_NOACTIVATE`。

---

## Phase M3：发音（结构）

**目标：** 卡片上点发音 → 经 bridge 走 Dart 现有发音解析/播放。

**任务拆分：**
1. `onJsMessage` 分发 `handler=='resolveWordAudio'/'queryLocalAudio'/'playWordAudio'`（清单见设计 §4 + `dictionary_popup_webview.dart:1176-1214`），复用 `appModel.lookupRemoteAudio`/`audioSourceConfigs`/`TtsChannel`。
2. 回值经 `global_lookup_channel.invokeMethod` 反向（或 native `ExecuteScript(window.__hibikiBridgeResolve(id,json))`）解决 adapter 的 Promise。
**测试：** 真机点发音出声；adapter 回值 Promise 解决的 JS 单测。

---

## Phase M4：打磨（结构）

1. **嵌套查词**：卡里查词走 popup.js 已有栈逻辑，覆盖窗给足尺寸（必要时 `showAt` 扩大/重定位）。
2. **热键可配**：设置项暴露键位，避免与剪贴板查词冲突。
3. **多显示器定位**：`showAt` 用光标所在显示器 `rcWork` clamp，防卡片出屏。
4. **制卡/收藏降级入口**：卡片按钮 → `jsMessage` → 主 app 打开完整查词页（不在覆盖窗里写 DB）。
**测试：** 各项真机截图；守卫扫描不引入 tray_manager / 第二 Flutter engine。

---

## 自检（Self-Review）

**Spec 覆盖：**
- 设计 §3 组件 → M0（覆盖窗/channel/adapter）+ M1（controller/selection_capture）✅
- §4 数据流（热键→抓选区→查词→推送→渲染）→ M1 ✅；外字图 → M0 Task 0.4 ✅；发音 → M3 ✅；收起+还焦点 → M2 ✅
- §5 三道保证 → idle 不显示(M0 Hide)、仅热键触发(M1)、NOACTIVATE(M0 Task 0.2)+还焦点(M2) ✅
- §7 三风险 → M0 Task 0.3(render)/0.4(image://)/0.1+0.6(复用 SDK+adapter) ✅
- §8 测试策略 → 各 Phase 测试节对应 ✅
- §9 分期 M0–M4 → 一一对应 ✅
- §10 热键另设可配 → M1 任务2 + M4 任务2 ✅

**占位扫描：** M0 全部步骤含真实代码；M1–M4 为结构化任务（锁定接口签名 + 文件 + 测试策略），按计划惯例待 M0 Gate 后逐 Phase 细化为 bite-sized——这是有意为之（native 打样未验前不写投机代码），非占位失败。

**类型一致：** `ShowAt/Hide/IsShowing/Navigate/RenderJson/SetMediaCallback/SetMessageCallback`（native）与 `prepare/showAt/render/hide/setHandlers`（Dart channel）跨 Task 引用一致；`GlobalLookupController.onHotKey/resolveMedia/onJsMessage`、`SelectionCapture.captureForegroundSelection` 在 M1 接口节锁定。channel 名 `app.hibiki.reader/global_lookup` 全程一致。

---

## 备注：worktree / 提交纪律

- 本计划在独立 worktree 执行；首次进 worktree 跑 `tool/setup_worktree.ps1`（搬密钥 + bootstrap）。
- Windows 构建改动按 `docs/agent/build.md`：native/CMake 改动需 `flutter build windows`，发布相关再走版本号规则。
- 真机验证按 `docs/agent/integration-testing.md` 焦点驱动留证据。
