## BUG-1028 · 捕获工作台查词弹窗每次冷建WebView加载缓慢
- **报告**：2026-07-23（用户：点台词查词「要等好久加载」，弹窗长时间空白）
- **真实性**：✅ 真 bug。`TexthookerPage` 是全 app 唯一不做 warm-slot 预热的查词表面：`_onWordTap`（`hibiki/lib/src/pages/implementations/texthooker_page.dart:433-446`）走 `pushNestedPopup(replaceStack:true)` → `DictionaryPopupController.beginTop(reuseWarmSlot:false)`（`hibiki/lib/src/pages/implementations/dictionary_popup_controller.dart:179-215`）冷路径，每次点词新建 `DictionaryPopupEntry` + 冷建 WebView2 表面（载 popup.html + 注词典 CSS），且 `revealWhileSearching:false` + `markPendingReveal` 让结果就绪后仍等 `popupRendered` 首帧（或 1800ms 兜底）才翻可见——空白期主要是冷 WebView2 首帧，不是词典 FFI 查询。对照组：阅读器 `base_source_page.dart:93-96/246`、首页词典 `home_dictionary_page.dart:161-162/752`、视频 `video_hibiki_page.dart:3580-3581` 全部 `seedWarmSlot()` 常驻复用 + `reuseWarmSlot:true`。
- **[x] ① 已修复** — 544d08724。`TexthookerPage.initState` 对齐 `home_dictionary_page` 做 `seedWarmSlot()` 预热（含 lowMemory 赋值），`_onWordTap` 改 `reuseWarmSlot:true`，冷建成本从每次点词提前到进页一次。
- **[x] ② 已加自动化测试** — 544d08724。测试文件 hibiki/test/pages/texthooker_toolbar_warmslot_guard_test.dart。源码扫描守卫（texthooker_page.dart 必须含 seedWarmSlot 与 reuseWarmSlot）。
- **备注**：与 BUG-1027 同轮 galgame Hook UX 重构（工具栏重组/音轨自动刷新/游戏库卡片精简）一并落地。
