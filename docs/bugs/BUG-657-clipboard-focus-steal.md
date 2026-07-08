## BUG-657 · 桌面剪贴板变化把 Hibiki 拉到前台/抢焦点打断用户
- **报告**：2026-07-09（用户：不要在剪贴板变动的时候把我拉到 Hibiki 焦点，无论指定哪种窗口策略）
- **真实性**：✅ 真 bug。根因：桌面剪贴板自动查词的**被动剪贴板变化**会唤主窗前台/抢焦点。
  链路：`hibiki/lib/src/sync/desktop_lookup_service.dart:70` `submitText()`（由 `:220`
  `_handleClipboardChange` 在用户于**别的 app** 复制时调用）排队查词请求时用了默认
  `foregroundPolicy: DesktopLookupForegroundPolicy.bringToFront`；消费侧
  `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:183-186`
  `_runDesktopLookup()` 见 `bringToFront` 即调 `DesktopLookupService.bringPendingLookupToFront()`
  （`desktop_lookup_service.dart:316-317` `windowManager.show()` + `windowManager.focus()`
  → Windows `SetForegroundWindow`）→ 用户正在别的窗口工作时剪贴板一变就把 Hibiki 弹到前面
  抢走焦点。`DesktopLookupForegroundPolicy.none` 早已定义但从未接线，剪贴板一直落到默认
  `bringToFront`。与窗口置顶策略（`DesktopClipboardWindowMode` normal/lookup/always）无关，
  任一策略下都抢焦点。
- **[x] ① 已修复** — commit `dbf83a5de`。剪贴板来源统一改带
  `DesktopLookupForegroundPolicy.none`：`submitText()` 显式传 `foregroundPolicy:
  DesktopLookupForegroundPolicy.none`（`desktop_lookup_service.dart`），消费侧原本已按
  `foregroundPolicy == bringToFront` 门控唤前台，故 `none` 只在后台准备查词结果（词典页照常
  搜索、结果就绪），**不** show/focus/抢焦点。显式意图路径不变：全局热键（Ctrl+Shift+D，
  origin=hotkey）与悬浮字幕点词（origin=explicit）仍 `bringToFront`。属纯 Dart 改动，无需
  重编原生。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/desktop_lookup_service_test.dart`：
  ① `submitText` 用例断言剪贴板请求 `foregroundPolicy == none`；② `clipboard hit ...` 用例加断言
  剪贴板命中排队后策略为 `none`；③ 新增 `consumer only foregrounds when foregroundPolicy is
  bringToFront (TODO-1355)` 守卫消费侧唤前台被 `bringToFront` 门控住（源码级）；④ 新增
  `submitText source pins clipboard origin to foregroundPolicy.none (TODO-1355)` 守卫剪贴板来源不回退默认。
- **备注**：TODO-1355。仅改桌面剪贴板被动查词路径；Android 悬浮词典服务路径未涉及。
