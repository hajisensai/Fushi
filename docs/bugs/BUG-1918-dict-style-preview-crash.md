## BUG-1918 · 打开词典样式可视化编辑器闪退（Windows）

- **报告**：2026-08-28（用户：设置 → 查词 → 词典样式，打开就闪退）
- **真实性**：✅ 真 bug。Windows 事件日志 + 完整 minidump 双证：
  - `Application Error`：`fushi.exe 2.2.1.12458` / 模块 `flutter_inappwebview_windows_plugin.dll` / `0xC0000005` / 偏移 `0x6c768`，2026-08-28 20:04:09 与 20:05:25 两次同一 fault bucket（可复现，非偶发）。
  - `cdb -z C:\Users\wrds\AppData\Local\CrashDumps\fushi.exe.80380.dmp` → `.ecxr`：
    `movzx eax, byte ptr [rdx+40h]`，`rdx = 0`，即**空指针解引用**；上一条是 `mov rdx,[rdx]`，
    调用链 `user32!DispatchMessageWorker → flutter_windows → plugin`（平台线程上处理 method channel 回复）。
    崩点所在函数就地构造 `std::string("null")`（`mov dword ptr [rbp-40h], 6C6C756Eh`，size 4 / cap 15），
    对应 `in_app_webview.cpp:772` 的 `std::string json = "null";`。
- **根因**：
  `packages/flutter_inappwebview_windows/windows/in_app_webview/webview_channel_delegate.cpp:35`
  （修前）`CallJsHandlerCallback::decodeResult = [](const flutter::EncodableValue* value) { return value; };`
  —— `T = const EncodableValue*`，返回值要转成 `std::optional<T>`。Dart 侧回复 **null** 时，
  Flutter 的 `StandardMethodCodec::DecodeAndProcessResponseEnvelopeInternal`（cpp_client_wrapper
  `standard_codec.cc`）走的是**无参** `result->Success()` → 这里收到的 `value == nullptr`。
  直接 `return value` 会装出一个 `has_value() == true` 但值为 `nullptr` 的 optional，于是
  `types/base_callback_result.h:28` 的 `nonNullSuccess(result.value())` 判为「非空成功」，
  最终 `in_app_webview.cpp:773` 的守卫
  `if (response.has_value() && !response.value()->IsNull())` 直接解引用空指针 → 进程级闪退
  （EncodableValue 是 `std::variant`，判别位在 +0x40，正是崩指令读的偏移）。

  **触发条件**：JS 调了一个 Dart 侧**没有 `addJavaScriptHandler` 注册**的 handler 名 ——
  `flutter_inappwebview_windows` 的 `_handleMethod` 在 `onCallJsHandler` 里查不到名字就走到末尾
  `return null`（已注册的走 `jsonEncode(...)`，null 也会变成字符串 `"null"`，不触发）。

  `fushi/lib/src/pages/implementations/dict_style_preview.dart` 跑的是**真的** popup.js，
  popup.html 加载的脚本一共能发起 21 个桥调用，而预览只注册了 4 个
  （`favoriteCheck` / `duplicateCheck` / `popupRendered` / `resolveWordAudio`）。
  漏掉的里面有 `reportJsError`（预览环境里任何 JS 报错都会调）和 `tapOutside`（点空白处就调），
  所以一进可视化页几乎必崩。

  同文件的 `PermissionRequestCallback::decodeResult` 是同一个缺陷形状（裸 `*value`），一并修。

- **[x] ① 已修复** — 两层：
  - 原生根因：`webview_channel_delegate.cpp` 两处 `decodeResult` 补空守卫，空回复降成
    `std::nullopt`，让下游 `has_value()` 守卫真的能拦住（这一层修掉的是**整类**崩溃：
    今天任何未注册 handler 名都能把 app 打死）。
  - 消费端：`dict_style_preview.dart` 把 popup 脚本能调的 21 个名字全注册成 no-op
    （`kDictStylePreviewNoopHandlers`）——预览里制卡 / 播音 / 跳转 / 上报都不该真发生，
    但每个桥调用都得有确定的 Dart 侧语义，不靠平台兜底空回复。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dict_style_preview_handler_coverage_test.dart`：
  ① 扫 popup.html 实际加载的脚本里的 `callHandler('X')`，断言 `kDictStylePreviewNoopHandlers`
  与之完全对齐（缺了红、多了也红）；② 源码扫描钉住 `CallJsHandlerCallback::decodeResult`
  的 `!value` → `std::nullopt` 空守卫（C++ 崩点 flutter test 跑不到，但那行的有无是二元的）。
  两条都做了变异实测：删 `'reportJsError'` → ①红；删 C++ 里的 `if (!value) return std::nullopt;` → ②红。
- **备注**：同一轮把该编辑器尺寸改成与 `LapisStyleEditorPage` 一致（对话框 maxWidth 640 → 1180、
  去掉写死的 0.55 屏高、宽于 820 时左预览右控件 340 的分栏），见同分支提交。
