## BUG-193 · 外部查词弹窗结果空白（popup 引擎漏注册 inappwebview）
- **报告**：2026-06-11（用户：TODO-110）
- **真实性**：✅ 真 bug。根因 `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictPluginRegistrant.java:12`（`registerWith` 漏注册 `com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin`，连带漏 `url_launcher_android.UrlLauncherPlugin`）。
- **[x] ① 已修复** — 提交 `5695cbdf8`：在 `FloatingDictPluginRegistrant.registerWith()` 补注册 `InAppWebViewFlutterPlugin`（popup 引擎用 `DictionaryPopupWebView` 的 `InAppWebView` 渲染词条，缺它平台视图建不出→结果区永久空白）与 `UrlLauncherPlugin`（`dictionary_popup_webview.dart:1088` 词条外链点击 `launchUrl`）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart`：新增源码扫描守卫，断言 `FloatingDictPluginRegistrant.java` 必须注册 `InAppWebViewFlutterPlugin` 与 `UrlLauncherPlugin`，且不得带回 `integration_test`/`GeneratedPluginRegistrant`（撤改转红）。
- **备注**：
  - 链路：外部查词（PROCESS_TEXT / SEND / TRANSLATE / `hibiki://lookup`）走独立 `:popup` Flutter 引擎 `PopupDictFlutterActivity → PopupEngineHolder.ensureEngine → FloatingDictPluginRegistrant.registerWith → popupMain → PopupDictionaryPage → DictionaryPageMixin → DictionaryPopupWebView(InAppWebView)`。该引擎用手写 registrant（BUG-146 / commit a2edde24a 为避免带入 integration_test dev 插件，从 `GeneratedPluginRegistrant` 改成手写），迁移时漏补 inappwebview/url_launcher。主引擎 `GeneratedPluginRegistrant.java:104/209` 有注册故 app 内查词正常。
  - 只补 popup 渲染真正需要的运行时插件（inappwebview + url_launcher）；**不带回 integration_test**（保住 BUG-146 初衷）。popup 自动发音走项目自有 `TtsChannel`（原生 MethodChannel，非 pub 插件 registrant），不在补齐范围。
  - 真机安卓「其它 app 选词 → PROCESS_TEXT → hibiki 弹窗结果不空白」需用户复测（平台进程边界 host 测不到）。
