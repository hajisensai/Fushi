## BUG-1364 · 搜索中占位层未接对话框隐藏计数，可能盖住对话框
- **报告**：2026-08-02（看板 TODO-2510，BUG-797 同族旧遗留复核，非近期 PR 引入）
- **真实性**：✅ 真 bug（层级契约漏项）。根因
  `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart:790-840`
  的 `buildPopupLoadingPlaceholder`（「搜索→就绪才显示」期间画的加载占位卡）**没接**
  同文件 `:151` 的 `_popupHidingDialogDepth`。
  - **层级机理**：三个走**根 Overlay** 的宿主（`video_hibiki_page.dart:3941` /
    `home_dictionary_page.dart` / `texthooker_page.dart:1743` 各自 `overlay.insert`）
    与常驻 `main.dart` 根 builder 的 `floating_lyric_lookup_host.dart:183`，整棵浮层
    子树都排在 `showAppDialog` 推的路由**之上**。浮层子树三个组成部分里，barrier 走
    `shouldShowLookupDismissBarrier`（BUG-1327 已接）、弹窗层走 `parkedPopupLayer` 的
    `visible && _popupHidingDialogDepth == 0`（BUG-797/1040 已接），只剩这张占位卡漏了。
  - **这一层不是平台视图**：占位卡是纯 Flutter（`HibikiPopupSurface` +
    `LinearProgressIndicator`），不是 WebView。所以它盖住对话框**不是** BUG-797 的
    airspace 原因，而是根 Overlay 的 Flutter z-order；对应地，让位也不需要
    `parkedPopupLayer` 的「停靠屏外」补偿，`Visibility` 就真的不画不吃点击。
  - **为什么当初漏掉**：BUG-797 只盯「原生平台视图盖住对话框」，占位卡不是平台视图；
    BUG-1327 只盯「barrier 吃掉命中测试」。两次都没把「浮层子树整体让位」当成一条契约，
    于是这条纯 Flutter 分支两次都不在视野内。
  - **触发时序真实可达**：对话框打开期间再起一次**顶层**查词时，
    `DictionaryPopupController.beginTop`（`dictionary_popup_controller.dart:201-237`）
    把复用热槽 / 新目标一律置 `visible = false` → `hasVisiblePopup` 变假 →
    `pushNestedPopup` 的 `if (!controller.hasVisiblePopup) controller.beginSearchUi(rect)`
    成立 → 占位卡出现在对话框上面。这类顶层查词不需要点到 app 本体（对话框模态遮罩
    挡不住它们）：悬浮歌词是独立系统窗口、texthooker / 全局查词的文本来自 app 外。
  - **reader 车道不受影响**：`base_source_page.dart:685` 的 `_buildLoadingPlaceholder`
    画在页面路由内，对话框路由在其之上，天然不遮（同理其 barrier 也没接计数）。
- **[x] ① 已修复** — 在**单一入口** `buildPopupLoadingPlaceholder` 里把这一层纳入既有的
  嵌套安全计数：外层 `Positioned` 不动（宿主 Stack 子项数与布局不变），内层包
  `Visibility(visible: _popupHidingDialogDepth == 0)`。四个宿主全部经此方法构造占位卡，
  故无需改任何调用点，也不会再出现「某个宿主忘接」的漂移。顺带补上占位卡的稳定 key
  `kLookupSearchPlaceholderKey`（对齐 reader 车道的
  `base-source-popup-loading-placeholder`，barrier 插拔时不与弹窗层按位置错配，BUG-941 同族）。
  提交：见下方备注。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/lookup_search_placeholder_dialog_test.dart`
  （**行为级**，非源码扫描）：在 mixin 宿主上构造「搜索中 → 此时打开对话框」的真实时序，
  断言占位卡内容不再渲染、`Positioned` 槽位保留、对话框关闭后复原；第二条覆盖嵌套对话框
  （内层 `finally` 不得提前放出占位卡）。变异实测：把 `visible:` 改回恒 `true` → 两条全红；
  反向替换还原后全绿。
- **备注**：未做真机复验（本轮为契约层修复，无 UI 观感变化）。另发现两处**未纳入本轮范围**
  的同族疑点，供后续判断：① `floating_lyric_lookup_host.dart:75` 的
  `shouldBlockHitTest`（= `isSearchingUi || hasVisiblePopup`）同样没接对话框计数，对话框
  期间该 host 仍参与命中测试（其子层此时都不可命中，故当前无实际症状，但判据与
  `shouldShowLookupDismissBarrier` 不同源）；② 目前「浮层子树整体让位」这条契约由三处
  各自表达（barrier 纯函数 / 弹窗层 `parkedPopupLayer` / 占位卡 `Visibility`），没有
  单一守卫钉住「新加的浮层子项必须接计数」——若再加第四种子项，仍可能重演本条。
