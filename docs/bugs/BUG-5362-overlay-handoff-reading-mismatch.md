## BUG-5362 · 覆盖窗转交高级制卡：同表记异读音时定位到错词条
- **报告**：2026-11-24（外部审查报告 HBK-AUDIT-005 P2，针对 #4296 覆盖窗转交主窗高级制卡）
- **真实性**：✅ 真 bug（根因 `fushi/assets/popup/popup.js`（修前 :7158）：`fushiPopupEntryDomIndexFor` 第三级只比表记；覆盖窗选的是 生（なま），主窗结果里只剩 生（せい）（或 なま 那条被隐藏词典过滤掉没有 DOM）时仍回 せい 的下标，预填和制卡都用错词条。与同函数注释「找不到回 -1、不猜下标」的设计意图矛盾）
- **[x] ① 已修复** — 转交带了读音时只认「表记 + 读音」（第一级再加命中文本），找不到回 -1 走现有「词条找不到」分支（记日志、不开对话框）；只有转交没带读音时才退到只认表记
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` `testEntryDomIndexForHandoff`（node 真跑 popup.js：不同读音回 -1、なま 被隐藏只剩 せい 回 -1、结果已完整加载；修前该断言红）；`fushi/test/lookup/advanced_mining_handoff_test.dart` 源码守卫（JS 行为测试不在 CI 里跑，CI 靠这条拦回归）
- **备注**：同批 [BUG-5361](BUG-5361-overlay-handoff-stale-locate-reply.md)
