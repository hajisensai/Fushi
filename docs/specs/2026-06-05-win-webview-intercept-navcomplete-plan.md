# Windows WebView2 拦截域假失败根治 (C+) 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Windows inappwebview fork 的引擎层根治 `hoshi.local` 拦截域触发的 `onReceivedError` 假失败，依据「主框架文档已被拦截器注入 2xx 响应」这一确凿事实纠正 WebView2 的 `IsSuccess=FALSE` 误判，从而删除阅读器页 Dart 层的事后补偿特例。

**Architecture:** WebView2 对主框架导航 `https://hoshi.local/...` 先走网络栈做 DNS 解析 → 解析不了 → `NavigationCompleted` 回 `IsSuccess=FALSE` + `HOST_NAME_NOT_RESOLVED`，尽管 `WebResourceRequested` 随后注入了 200 响应、内容已渲染。修复在 fork C++ 层：`WebResourceRequested` 注入主框架 document 的 2xx 响应时记下该 URL；`NavigationCompleted` 失败分支若当前 URL 命中该记录，则当 `onLoadStop` 成功处理。Dart 层 `reader_hibiki_page.dart` 的 `Platform.isWindows && host==kHost` 特例整段删除。

**Tech Stack:** C++ / WebView2 (ICoreWebView2)；Dart / Flutter；fork 经 `dependency_overrides` 的 `path:` 接入主 app。

---

## 背景：根因证据 (file:line)

- 拦截机制：`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:838` `AddWebResourceRequestedFilter("*")` + `:839` `add_WebResourceRequested`；主框架注入点 `:888` `nonNullSuccess`（`args->put_Response(...)`）。
- 假失败映射：`in_app_webview.cpp:542` `add_NavigationCompleted`；`:570` `isSuccess` → `onLoadStop`；`:573` `else if (!isSslError && navigationAction)` → `:588` `onReceivedError`。`isSslError` 白名单 `:1872` 只含证书错误，不认「响应已注入」。
- 错误码来源：`hoshi.local` DNS 解析失败 → `COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED`，落进 `:586` `httpStatusCode < 400` 分支调 `onReceivedError`。
- 主框架 URL 形式：`hibiki/lib/src/media/sources/reader_hibiki_source.dart:63` `https://$kHost/...`，`kHost = 'hoshi.local'`（`:49`）。
- Dart 事后补偿特例（待删）：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1973-1994`。
- 成员声明锚点：`in_app_webview.h:195` `navigationActions_`、`:185` `isSslError` 声明。
- 清理锚点：`in_app_webview.cpp:1893` `navigationActions_.clear();`。
- 响应状态码字段：`web_resource_response.h:16` `const std::optional<int64_t> statusCode;`（注入回调里可读 `response->statusCode`）。

## 关联手段说明（为何用 URL 匹配而非 navigationId）

`ICoreWebView2WebResourceRequestedEventArgs`（`:842`）**不携带 navigationId**，无法与 `NavigationCompleted` 的 `navigationId`（`:552`）对齐。因此用 **URL 匹配**：注入主框架 document 的 2xx 响应时记下 `request->url`，`NavigationCompleted` 用 `get_Source()` 得到的 URL 比对。两者对同一次主框架导航一致。子资源（CSS/字体/图片）虽也走 `hoshi.local`，但其 URL 不等于主框架 `get_Source()`，不会误命中；再以 `ResourceContext == DOCUMENT` 过滤做第一道闸。比对前统一截断 `#` 之后的 fragment 以消除规范化差异。

## File Structure

- 修改：`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.h`
  - 新增 private 成员 `mainFrameInjectedOkUrls_`（已注入 2xx 的主框架 URL 集合）。
  - 新增 private 方法声明 `rememberMainFrameInjectedOk` / `consumeMainFrameInjectedOk`。
- 修改：`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp`
  - `WebResourceRequested` 注入回调记录主框架 2xx URL。
  - 新增两个 helper 方法实现 + 匿名命名空间 `stripFragment`。
  - `NavigationCompleted`：失败分支前加豁免；成功分支顺手清理。
  - reset 点清空集合。
- 修改：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
  - 删除 `onReceivedError` 里 `Platform.isWindows && host==kHost` 特例（`:1973-1994`），换为说明根因已下沉 fork 的注释。
- 新建：`hibiki/test/reader/reader_windows_intercept_guard_test.dart`
  - 源码扫描守卫：断言 reader 页不再含 Windows onReceivedError 特例字符串，防回归重引入。

---

## Task 1: fork 头文件——新增成员与方法声明

**Files:**
- Modify: `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.h:185,195`

- [ ] **Step 1: 在 `navigationActions_` 旁新增成员**

在 `in_app_webview.h:195` `std::map<UINT64, std::shared_ptr<NavigationAction>> navigationActions_ = {};` 下一行追加：

```cpp
    // 已被 shouldInterceptRequest 注入 2xx 响应的主框架 document URL（去 fragment）。
    // 用于 NavigationCompleted 纠正 hoshi.local 这类自定义拦截域的 DNS 假失败。
    std::set<std::string> mainFrameInjectedOkUrls_ = {};
```

- [ ] **Step 2: 在 `isSslError` 声明旁新增两个 private 方法声明**

在 `in_app_webview.h:185` `static bool isSslError(const COREWEBVIEW2_WEB_ERROR_STATUS& webErrorStatus);` 下一行追加：

```cpp
    void rememberMainFrameInjectedOk(const std::string& rawUrl);
    bool consumeMainFrameInjectedOk(const std::string& rawUrl);
```

- [ ] **Step 3: 确认 `<set>` 与 `<string>` 可用**

`in_app_webview.h` 已包含 `<map>` / `<string>`（`navigationActions_` 用到）。确认头部 include 区是否有 `#include <set>`；若无，加上：

Run: `grep -n "#include <set>\|#include <map>\|#include <string>" packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.h`
Expected: 至少看到 `<map>`/`<string>`。若无 `<set>`，在 `<map>` include 行下方加 `#include <set>`。

- [ ] **Step 4: Commit**

```bash
git add packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.h
git commit -m "feat(inappwebview-win): declare main-frame injected-OK URL tracking"
```

---

## Task 2: fork 实现——helper 方法与 fragment 规范化

**Files:**
- Modify: `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp`（在 `isSslError` 实现 `:1872` 附近新增）

- [ ] **Step 1: 在 `isSslError` 实现下方新增 helper**

定位 `in_app_webview.cpp:1872` 的 `bool InAppWebView::isSslError(...)` 实现，在其闭合 `}` 之后新增（同一文件，匿名命名空间放本翻译单元内的局部 helper；若文件已有匿名 namespace 习惯则并入，否则用 static 局部函数）：

```cpp
namespace {
  // 截断 '#' 之后的 fragment，消除主框架 URL 在注入侧与导航完成侧的规范化差异。
  std::string stripFragment(const std::string& url) {
    const auto hashPos = url.find('#');
    return hashPos == std::string::npos ? url : url.substr(0, hashPos);
  }
}

void InAppWebView::rememberMainFrameInjectedOk(const std::string& rawUrl)
{
  mainFrameInjectedOkUrls_.insert(stripFragment(rawUrl));
}

bool InAppWebView::consumeMainFrameInjectedOk(const std::string& rawUrl)
{
  const auto it = mainFrameInjectedOkUrls_.find(stripFragment(rawUrl));
  if (it == mainFrameInjectedOkUrls_.end()) {
    return false;
  }
  mainFrameInjectedOkUrls_.erase(it);
  return true;
}
```

- [ ] **Step 2: 编译期不可单测，跳过运行验证（见 Task 6）**

C++ 引擎层无单测框架，本步仅保证语法可编译；可行性在 Task 6 真机构建时一并验证。

- [ ] **Step 3: Commit**

```bash
git add packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp
git commit -m "feat(inappwebview-win): add injected-OK URL helpers + fragment strip"
```

---

## Task 3: fork——注入主框架 2xx 响应时记录 URL

**Files:**
- Modify: `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:888`

- [ ] **Step 1: 改 `nonNullSuccess` 捕获列表，纳入 `request`**

当前 `in_app_webview.cpp:888`：

```cpp
              callback->nonNullSuccess = [this, deferral, args](const std::shared_ptr<WebResourceResponse> response)
                {
                  args->put_Response(response->toWebView2Response(webViewEnv));
                  failedLog(deferral->Complete());
                  return false;
                };
```

替换为（捕获 `request`，注入后记录主框架 document 的 2xx URL）：

```cpp
              callback->nonNullSuccess = [this, deferral, args, request](const std::shared_ptr<WebResourceResponse> response)
                {
                  args->put_Response(response->toWebView2Response(webViewEnv));
                  // 根治准备：拦截器为主框架 document 注入了 2xx 响应时记下其 URL，
                  // 供 NavigationCompleted 把 hoshi.local 的 DNS 假失败纠正为成功。
                  COREWEBVIEW2_WEB_RESOURCE_CONTEXT resourceContext;
                  const int64_t statusCode = response->statusCode.value_or(200);
                  if (request->url.has_value() && statusCode >= 200 && statusCode < 300 &&
                      SUCCEEDED(args->get_ResourceContext(&resourceContext)) &&
                      resourceContext == COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT) {
                    rememberMainFrameInjectedOk(request->url.value());
                  }
                  failedLog(deferral->Complete());
                  return false;
                };
```

注：`request` 在外层 `:847` 已构造为 `auto request = std::make_shared<WebResourceRequest>(webResourceRequest);`，捕获安全。`get_ResourceContext` 是 `ICoreWebView2WebResourceRequestedEventArgs` 标准方法。

- [ ] **Step 2: Commit**

```bash
git add packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp
git commit -m "feat(inappwebview-win): record main-frame document 2xx injected URLs"
```

---

## Task 4: fork——NavigationCompleted 豁免 + 清理

**Files:**
- Modify: `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:570-590,1893`

- [ ] **Step 1: 成功分支顺手清理，失败分支加豁免**

当前 `in_app_webview.cpp:570-590`：

```cpp
            if (isSuccess) {
              channelDelegate->onLoadStop(url);
            }
            else if (!InAppWebView::isSslError(webErrorType) && navigationAction) {
              auto webResourceRequest = std::make_unique<WebResourceRequest>(url, navigationAction->request->method, navigationAction->request->headers, navigationAction->isForMainFrame);
              int httpStatusCode = 0;
              wil::com_ptr<ICoreWebView2NavigationCompletedEventArgs2> args2;
              if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&args2))) && SUCCEEDED(args2->get_HttpStatusCode(&httpStatusCode)) && httpStatusCode >= 400) {
                auto webResourceResponse = std::make_unique<WebResourceResponse>(std::optional<std::string>{},
                  std::optional<std::string>{},
                  httpStatusCode,
                  std::optional<std::string>{},
                  std::optional<std::map<std::string, std::string>>{},
                  std::optional<std::vector<uint8_t>>{});
                channelDelegate->onReceivedHttpError(std::move(webResourceRequest), std::move(webResourceResponse));
              }
              else if (httpStatusCode < 400) {
                auto webResourceError = std::make_unique<WebResourceError>(WebErrorStatusDescription[webErrorType], webErrorType);
                channelDelegate->onReceivedError(std::move(webResourceRequest), std::move(webResourceError));
              }
            }
```

替换为：

```cpp
            if (isSuccess) {
              // 正常成功：清掉本次主框架可能记下的注入标记，避免集合泄漏。
              if (url.has_value()) {
                consumeMainFrameInjectedOk(url.value());
              }
              channelDelegate->onLoadStop(url);
            }
            else if (!InAppWebView::isSslError(webErrorType) && navigationAction) {
              // 根治 hoshi.local 假失败：拦截器已为该主框架 URL 注入 2xx 响应，
              // 内容已渲染，引擎因自定义域 DNS 解析失败误报 IsSuccess=FALSE —— 当成功。
              if (url.has_value() && consumeMainFrameInjectedOk(url.value())) {
                channelDelegate->onLoadStop(url);
              }
              else {
                auto webResourceRequest = std::make_unique<WebResourceRequest>(url, navigationAction->request->method, navigationAction->request->headers, navigationAction->isForMainFrame);
                int httpStatusCode = 0;
                wil::com_ptr<ICoreWebView2NavigationCompletedEventArgs2> args2;
                if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&args2))) && SUCCEEDED(args2->get_HttpStatusCode(&httpStatusCode)) && httpStatusCode >= 400) {
                  auto webResourceResponse = std::make_unique<WebResourceResponse>(std::optional<std::string>{},
                    std::optional<std::string>{},
                    httpStatusCode,
                    std::optional<std::string>{},
                    std::optional<std::map<std::string, std::string>>{},
                    std::optional<std::vector<uint8_t>>{});
                  channelDelegate->onReceivedHttpError(std::move(webResourceRequest), std::move(webResourceResponse));
                }
                else if (httpStatusCode < 400) {
                  auto webResourceError = std::make_unique<WebResourceError>(WebErrorStatusDescription[webErrorType], webErrorType);
                  channelDelegate->onReceivedError(std::move(webResourceRequest), std::move(webResourceError));
                }
              }
            }
```

注：豁免依据是「注入过 2xx」而非特定错误码——响应已就绪时引擎报什么网络错误都不该当失败。真正的加载失败（拦截器没注入、或注入非 2xx）不会进集合，仍如常报 `onReceivedError`/`onReceivedHttpError`。

- [ ] **Step 2: reset 点清空集合**

在 `in_app_webview.cpp:1893` `navigationActions_.clear();` 下一行追加：

```cpp
    mainFrameInjectedOkUrls_.clear();
```

- [ ] **Step 3: Commit**

```bash
git add packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp
git commit -m "fix(inappwebview-win): treat injected-2xx main-frame nav as success on DNS-fail"
```

---

## Task 5: Dart——删除阅读器页 Windows 特例 + 守卫测试

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1973-1994`
- Create: `hibiki/test/reader/reader_windows_intercept_guard_test.dart`

- [ ] **Step 1: 先写失败的源码守卫测试**

Create `hibiki/test/reader/reader_windows_intercept_guard_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：Windows WebView2 拦截域假失败已在 fork 引擎层根治
/// （packages/flutter_inappwebview_windows，NavigationCompleted 依据「主框架
/// 已注入 2xx」纠正 IsSuccess=FALSE）。阅读器页不得再用 Dart 层
/// `Platform.isWindows && host==kHost` 事后补偿特例掩盖该假失败。
void main() {
  test('reader onReceivedError 不再含 Windows 拦截域事后补偿特例', () {
    final File source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    );
    expect(source.existsSync(), isTrue,
        reason: '阅读器页源文件应存在；测试需在 hibiki/ 目录下运行');
    final String code = source.readAsStringSync();

    // 特例的特征：onReceivedError 分支内同时判 Platform.isWindows 与拦截域 host。
    final bool hasWindowsHostSpecialCase = code.contains('Platform.isWindows') &&
        code.contains('request.url.host == ReaderHibikiSource.kHost');
    expect(hasWindowsHostSpecialCase, isFalse,
        reason: 'Windows 拦截域假失败应由 fork 引擎层根治，阅读器页不得重新引入特例');
  });
}
```

- [ ] **Step 2: 运行测试，确认失败（特例仍在）**

Run: `cd hibiki && flutter test test/reader/reader_windows_intercept_guard_test.dart`
Expected: FAIL —— `hasWindowsHostSpecialCase` 当前为 true（`:1977-1978` 特例尚在）。

- [ ] **Step 3: 删除 `reader_hibiki_page.dart:1973-1994` 特例**

当前 `onReceivedError` 体（`:1969-2003`）中段：

```dart
          // WebView2 on Windows reports NavigationCompleted with isSuccess=false
          // for intercepted hoshi.local URLs because the domain doesn't resolve
          // at the network layer, even though shouldInterceptRequest provided a
          // valid response. The content IS rendered — treat as onLoadStop.
          if (Platform.isWindows &&
              request.url.host == ReaderHibikiSource.kHost) {
            _isNavigatingToChapter = false;
            final int chapterSnapshot = _currentChapter;
            if (_lyricsMode) {
              await _onChapterLoadComplete(controller);
              return;
            }
            final String expectedUrl = _chapterUrl(chapterSnapshot);
            if (Uri.parse(request.url.toString()).path !=
                Uri.parse(expectedUrl).path) {
              debugPrint('[ReaderHibiki] Windows onReceivedError: stale page '
                  '(expected=$expectedUrl), ignoring');
              return;
            }
            await _onChapterLoadComplete(controller);
            return;
          }
```

整段删除，替换为一行注释（保留其余真错误处理 `:1995-2001` 不动）：

```dart
          // Windows 拦截域 (hoshi.local) 的 NavigationCompleted 假失败已在 fork
          // 引擎层根治（packages/flutter_inappwebview_windows：主框架已注入 2xx
          // 时按成功走 onLoadStop），此处不再做事后补偿；下面是真实加载失败处理。
```

- [ ] **Step 4: 检查 `_chapterUrl` / `Platform` import 是否变成死引用**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`
Expected: 无 error。`Platform` 仍被文件其他处使用则保留 import；若 analyzer 报 `unused_import`，删对应 import 行。`_chapterUrl` 在 `onLoadStop`（`:1960`）仍用，保留。

- [ ] **Step 5: 运行守卫测试，确认通过**

Run: `cd hibiki && flutter test test/reader/reader_windows_intercept_guard_test.dart`
Expected: PASS。

- [ ] **Step 6: 跑相邻 reader 测试，确认无回归**

Run: `cd hibiki && flutter test test/reader/`
Expected: 全绿（若有与本改动无关的预存红，记录基线后对比，确保不是本改动引入）。

- [ ] **Step 7: Commit**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/test/reader/reader_windows_intercept_guard_test.dart
git commit -m "fix(reader): drop Windows onReceivedError special-case (rooted in fork)"
```

---

## Task 6: Windows 真机构建 + 设备验证（无法单测的引擎层）

**Files:** 无（验证任务）

- [ ] **Step 1: 构建 Windows app（编译 fork C++）**

Run: `cd hibiki && flutter build windows --debug`
Expected: 构建成功，无 C++ 编译错误。若 `get_ResourceContext` / `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT` 报未定义，确认 WebView2 SDK 头已含（fork 既有代码已用 `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL`，同一枚举族，应可用）。

- [ ] **Step 2: 真机打开书，确认正常加载（原假失败路径）**

启动 app，打开一本 EPUB，翻若干章。
Expected: 章节正常渲染、翻页正常；日志不再出现 `[ReaderHibiki] onReceivedError`（因引擎层已按成功处理），`onLoadStop` 正常触发 `_onChapterLoadComplete`。留截图/日志证据。

- [ ] **Step 3: 验证真错误仍能报错（不被误吞）**

人为构造一次真实加载失败（例如临时让拦截器对某主框架 URL 返回非 2xx 或不注入），确认 `onReceivedError` 仍照常触发、阅读器进入错误处理路径。验证后还原。
Expected: 真失败不被豁免（集合里没有该 URL）。

- [ ] **Step 4: 离屏集成测试（若适用）**

Run: `cd hibiki && pwsh tool/run_windows_itest.ps1`（按 docs/agent/integration-testing.md 的 Windows 离屏流程）
Expected: reader 相关集成测试绿。

- [ ] **Step 5: 记录验证证据**

在 `docs/BUGS.md` 追加本次根治条目（根因 `in_app_webview.cpp:573` + 修复提交哈希 + 守卫测试文件 + 真机证据），勾选「根因修复」与「自动化测试」两框。

---

## Self-Review

**1. Spec coverage**
- C+ 核心（注入侧记录 + 完成侧豁免）：Task 3 + Task 4 ✓
- 关联手段（URL 匹配 + DOCUMENT 过滤 + fragment 规范化）：Task 2（stripFragment）+ Task 3（ResourceContext 过滤）✓
- 集合不泄漏（成功分支 + reset 清理）：Task 4 Step 1/Step 2 ✓
- 删 Dart 事后补偿特例：Task 5 ✓
- 防回归守卫：Task 5 Step 1（源码扫描测试）✓
- 引擎层无法单测 → 真机验证：Task 6 ✓

**2. Placeholder scan** — 无 TBD/TODO；每个代码步给出完整代码块。Task 6 的「人为构造真失败」是验证手段描述，非代码占位。

**3. Type consistency**
- `rememberMainFrameInjectedOk(const std::string&)` / `consumeMainFrameInjectedOk(const std::string&)`：声明（Task 1 Step 2）与实现（Task 2 Step 1）与调用（Task 3/Task 4）签名一致 ✓
- `mainFrameInjectedOkUrls_`（`std::set<std::string>`）：声明（Task 1 Step 1）、helper 使用（Task 2）、reset 清理（Task 4 Step 2）一致 ✓
- `stripFragment`：匿名 namespace 内定义，仅本翻译单元用 ✓
- `response->statusCode`（`std::optional<int64_t>`）：与 `web_resource_response.h:16` 一致 ✓

**风险点**
- `get_Source()` 返回 URL 与注入侧 `request->url` 的编码差异：已用 stripFragment 消除 fragment；若真机发现 percent-encoding 差异导致不匹配，回退方案为比对 `host + path`（解析后），在 Task 6 Step 2 暴露时再收敛。
- iframe document 的 `ResourceContext` 同为 DOCUMENT：其 URL 不等于主框架 `get_Source()`，不会误命中；EPUB 主框架通常无 iframe。
