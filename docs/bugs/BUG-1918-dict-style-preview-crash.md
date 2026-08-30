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
- **同轮查出的第二个真缺陷（同一条链，白屏而非闪退）**：
  `dict_style_preview.dart` 调的是**裸的** `DictionaryPopupWebViewState.buildInlinePopupHtml(...)`，
  而那个构造函数假定四份内联资产（popup.css / dict-media.js / selection.js / popup.js）
  已装载。装载只有两条路径：`main.dart:444` 启动时 fire-and-forget 的
  `preloadInlinePopupAssets()`，和真弹窗 `build()` 里的同步兜底
  `_ensureInlinePopupAssetsLoaded()` + 四项非空校验（不满足就回退 file:// URL）。
  预览两条都没走 → 预读未完成时拼出 `<style></style><script></script>` 空壳：
  没有 popup.js，预览白屏，`window.renderPopup` 都不存在。
  真 WebView2 集成测试里 `document.querySelectorAll('.entry').length` 恒为 0 就是这一支。

  修法：把「确保装载 + 四项非空 + 拼装」收成一个原语
  `buildInlinePopupHtmlIfReady`（未就绪返回 null，调用方回退 file://），
  **真弹窗的 build 也改用它** —— 两个入口不可能再漂移出两种加载行为。
  测试 `fushi/test/pages/popup_inline_assets_readiness_test.dart` 三条。

- **真机证据**：Windows 集成测试
  `fushi/integration_test/dict_style_preview_null_reply_crash_itest.dart`
  （`.\tool\run_windows_itest.ps1`，离屏、隔离 WebView2 profile）。
  用例① 在真 WebView2 里已通过：调未注册 handler → promise resolve 成 null，
  之后再发一次 JS 仍有回应（进程存活）；修前这一步即 0xC0000005。

- **合并时复核补修（PR #1038 合入 develop 当轮）**——PR 基于 17 个提交之前的 develop，合并前逐条复核：
  1. **`decodeResult` 全目录复核**（本条最要紧，因为 PR 只声称修了两处）：`packages/flutter_inappwebview_windows/windows/` 下共 7 处 `decodeResult`。`webview_channel_delegate.cpp` 里 6 处——ShouldOverrideUrlLoading / CreateWindow / ShouldInterceptRequest / LoadResourceWithCustomScheme 原本就先判 `!value`，未判的正是 CallJsHandler 与 PermissionRequest 这两处，即 PR 修的两处；第 7 处是 `types/base_callback_result.h:19` 的基类默认实现 `return std::nullopt;`，天然安全。**没有漏网的同形缺陷。**
  2. **名单陈旧会当场把 CI 打红**。`kDictStylePreviewNoopHandlers` 里的 `'panelSentenceLookup'` 在当前 develop 的 popup.js 上已无任何调用（PR 落后期间被删），而覆盖守卫会把它判为 stale。删掉该行。变异实测：加回去 → `Actual: ['panelSentenceLookup']` 变红，说明守卫真的在跟 popup.js 对账，不是断言硬编码列表。
  3. **C++ 注释是双重编码乱码**。PR 给 `webview_channel_delegate.cpp` 注入的 9 行中文注释是 UTF-8 被当 Latin-1 再编一次的产物（`根` → `æ ¹`），develop 上该文件为 0 行乱码。解释根因的那几段等于不可读，已按 `latin-1 → utf-8` 逆运算还原，复查 0 残留。
  4. **白屏那一支的判据原本是空转的**。`popup_inline_assets_readiness_test.dart` 的「非空壳」断言只查 `<style></style>` / `<script></script>`；但资产字段是 `String?`，实现真退化成不判就绪时插值产物是 `<style>null</style>`，原判据放它过去。已把两种 `null` 形状一并纳入。变异实测（拿掉 `buildInlinePopupHtmlIfReady` 里的四项判空）：**原有两条断言在同一变异下全部通过**，新增的 `<script>null</script>` 那条报红——空转是实测出来的，不是推断。
  5. **第三条守卫有半条恒真**：它对 `dictionary_popup_webview.dart` 断言「本文件含 `buildInlinePopupHtmlIfReady`」，而那正是该函数的定义所在文件。改成断言真弹窗侧的**调用点**，并加一条「裸构造 `_buildInlinePopupHtml(` 只允许出现 3 次（定义 + 就绪原语内 + 测试别名内）」——多一处就是新开的绕过口；同时把负向判据从大小写敏感的 `buildInlinePopupHtml\s*\(` 扩成显式禁用公开别名 `debugBuildInlinePopupHtml`（前者命中不了后者）。变异实测：注入第 4 个裸构造调用点 → `Expected: <3> / Actual: <4>` 变红。
- **已知弱点（未改，因为改了就无法重验）**：itest 用例② 里的 `expect(sent, 'sent')` 近似空转——`window.__fushiStyleProbe = 'sent'` 与 `__fushiReportJsError(...)` 在同一段 `evaluateJavascript` 里同步相邻，只要这段 JS 跑了它就恒成立，证明不了桥答复回来过；而 `__fushiReportJsError` 不把 `callHandler` 的 promise 传出来，就地改不成真判据。该用例真正的存活证据是随后 `2 + 3 == 5` 那次新往返。作者已在真 WebView2 上验证过这个文件通过，改动后本轮无法重验（需重建 Windows 产物），故保持原样并记录于此。
- **CI 不跑这条 itest**：三个 itest job 均为 `comprehensive-test --only=appSmoke`，而 `fushi/tool/test_flow/comprehensive_test_matrix.dart` 把 `appSmoke` 唯一映射到 `integration_test/app_smoke_test.dart`。本文件的回归保护只来自上述单测守卫。
- **合并当轮验证**：`flutter analyze --no-pub` No issues found；定向 `dict_style_preview_handler_coverage` + `popup_inline_assets_readiness` + `dictionary_css_editor_dialog` + `source_guard_adoption` + `bugs_per_file_guard` → **29 tests PASSED**。

- **备注**：同一轮把该编辑器尺寸改成与 `LapisStyleEditorPage` 一致（对话框 maxWidth 640 → 1180、
  去掉写死的 0.55 屏高、宽于 820 时左预览右控件 340 的分栏），见同分支提交。
