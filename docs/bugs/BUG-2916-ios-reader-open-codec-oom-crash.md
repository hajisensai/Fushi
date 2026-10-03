## BUG-2916 · iOS 打开/阅读书时主线程 CFAutorelease(NULL) 崩溃（解码超大方法调用字符串失败）
- **报告**：2026-10-03（用户：TestFlight 反馈 2 条，均 2.3.0、iPhone18,3 iOS 27——build 14191「打开书崩溃了」、build 14343「看书崩溃了」，2026-09-10）
- **真实性**：⚠ 崩溃真实，根因**未确认**（未复现）。两份日志同栈：主线程 `CFAutorelease.cold.1 ← CFAutorelease ← FastReadValue (FlutterStandardCodecHelper.cc:165) ← -[FlutterStandardMethodCodec decodeMethodCall:] ← -[FlutterMethodChannel setMethodCallHandler:]_block_invoke`，`EXC_BREAKPOINT`；14191 那份带 `Kernel Triage: mach_vm_allocate_kernel failed within call to vm_map_enter`。
  - 对照 Flutter 3.41.6 / 3.44.0 引擎源码：`:165` 是 map value 的 `FastReadValue`（内联），落到 `FlutterStandardCodecHelperReadUTF8`：`CFStringCreateFromExternalRepresentation(UTF8)` 返回 NULL 后直接 `CFAutorelease(NULL)` 断言。Dart 的 `utf8` 编码器把孤立代理项替换成 U+FFFD（实测 `utf8.encode('\uD800a') == [239,191,189,97]`），不会产出非法 UTF-8，所以 NULL 只能来自**大字符串分配失败**——某条 Dart→iOS 方法调用的参数 map 里有一个超大字符串。
  - 最强候选：开书时 `base_source_page.dart` `_seedWarmPopup()` 预热隐藏词典弹窗，就绪后 `dictionary_popup_webview.dart` `_pushResults()` 经 `evaluateJavascript` 下发静态段；iOS/macOS 上 `kInAppPopupFontUrlSupported == false`（`dictionary_webview_media.dart:50`），导入的词典字体整份 `data:…;base64,` 内联（`dictionary_font_css.dart`），注释自述两个 CJK 字体 base64 后三十多 MB，嵌套弹窗每层重发。前提是该用户导入了词典字体——**未核实**。
  - 次候选：每章整段重发的阅读器 setup 脚本（`reader_fushi/webview.part.dart`，~147K 字符；有声书书还拼本章 `sentenceAudioCuesJson`）。
  - 2.3.0 之后这两条路径未改（字体 URL 化 `8408b83dde` 早于 2.3.0 且只覆盖 Android/Windows），若根因成立当前 develop 仍会崩；同一用户 2.7.0 起只再报了视频崩溃（BUG-2915），可作弱反证。
- **[ ] ① 未修复** — 待确认根因。需要：该用户是否导入了词典字体（及大小）、或开书前后的 Fushi 日志（`LookupPerfTrace` 的 `push static=…B`）。若确认是字体内联：根因修法是让 iOS/macOS 弹窗文档从自定义 scheme（与 `fushi.local` 同源）加载，字体改走 URL，不再经方法通道传字节；不是加大小上限或跳过预热这类绕法。
- **[ ] ② 未加自动化测试** —
- **备注**：与 BUG-2915 同批 TestFlight 反馈分析得出。
