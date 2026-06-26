## BUG-429 · video _onDismissBarrierTap 守卫期望 _topVisiblePopupIndex 但 TODO-834 已改回 _popNestedPopupAt(0)
- **报告**：2026-06-26（用户：）
- **真实性**：（沿真实代码路径验真伪后填：✅ 真 bug / ❌ 未复现，附根因 `file:line`）
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：


## 根因
`test/media/video/video_player_keyboard_static_test.dart:382` 守卫断言 `_onDismissBarrierTap` 体内顺序 hitTest→`_handleSubtitleLookupTap`→`_popNestedPopupAt(_topVisiblePopupIndex)`。
- `c8dab2fe0` 为 BUG-403「分层 dismiss」把守卫期望更新成 `_popNestedPopupAt(_topVisiblePopupIndex)`。
- `cd23a912a`(TODO-834·反转 TODO-720) 把代码改回一次性清整栈 `_popNestedPopupAt(0)`（video_hibiki_page.dart:2320·注释明确意图：dismissAt(0) 保留隐藏热槽 BUG-092 + 关栈汇聚收尾 BUG-072），**但未更新守卫**。
- 结果守卫 `popAt=indexOf('_popNestedPopupAt(_topVisiblePopupIndex)')` 恒 -1 → 断言红。develop APK CI 自 commit 233(852) 起一直红（CI run 28222998973「Run unit tests」exit 1，唯一失败即本条），阻断所有 APK 发布。

## 修复
- [x] `video_player_keyboard_static_test.dart` 守卫 popAt 改匹配 `_popNestedPopupAt(0)`（TODO-834 意图），reason 同步更新。代码 `_popNestedPopupAt(0)` 是故意，守卫陈腐故修守卫不动代码。提交：见本轮 integration commit。

## 测试
- [x] `flutter test test/media/video/video_player_keyboard_static_test.dart` 由红转绿（23/23）。守卫仍钉死「hit→handler→else dismiss」结构，仅放开 pop 调用的参数到 TODO-834 实际值。
