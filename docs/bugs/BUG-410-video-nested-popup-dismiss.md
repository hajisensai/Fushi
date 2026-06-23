## BUG-410 · 视频嵌套查词点外不关顶层(字幕命中抢先replaceStack)

- **报告**：2026-06-23（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:2161` `_onDismissBarrierTap`：查词暂停态字幕仍在屏幕底部清晰渲染，其字符全局矩形被 `_subtitleHitTester` 持续绑定。该 barrier 处理**无条件先跑** `_subtitleHitTester.hitTest(globalPos)`，命中即 `_handleSubtitleLookupTap` → `_lookupAt(replaceStack:true)` 换整栈 `return`，永远到不了下面 BUG-403 已修好的逐层关栈 `_popNestedPopupAt(_topVisiblePopupIndex)`。嵌套查词（index 0 父词 + index 1 子词）时用户点第 2+ 个窗外面，落点常就是底部那条字幕文字 → barrier 命中 → 整栈被替换成新顶层词，顶层窗没关而是被替换。位置相关、间歇（落字幕上复现，落纯空白正常）。这套「点字幕换词」对单层合理，对嵌套栈语义错误。reader 无此问题（无字幕反查并行入口）。
- **[x] ① 已修复** — 把「点外先反查字幕换词」门控在**非嵌套**时才生效，不动 `_popNestedPopupAt` / `dismissAt` / `lastVisibleIndex` 任何被测试锁定的栈原语：
  - 新增纯函数 `VideoHibikiPage.shouldSwitchWordOnBarrierTap({topVisibleIndex, hitSubtitle})`（`video_hibiki_page.dart:307`，`@visibleForTesting`）：`topVisibleIndex <= 0 && hitSubtitle`。`<=0` = 单层（或仅剩隐藏热槽返回 -1）才保留「点同句另一字换词」；`>0` = 有父层时一律返回 false。
  - `_onDismissBarrierTap`（`video_hibiki_page.dart:2177`）：`_subtitleHitTester.hitTest` 仍跑，但反查分支改由 `shouldSwitchWordOnBarrierTap` 门控；嵌套态命中字幕也直接落到 `_popNestedPopupAt(_topVisiblePopupIndex)` 逐层关一层（与 reader `dismissTopPopup` 同语义），关到 0 自然触发会话收尾（恢复播放/清草稿/收回焦点）。
  - 不回归：BUG-072 续播（恢复播放仍在关栈到底 `stackEmpty` 判据）/ BUG-093/095 热槽（热槽 index 0 隐藏 `_topVisiblePopupIndex` 返 -1 走旧路无害）/ 单层「点同句另一词换词」（`<=0` 时保留）/ 草稿会话收尾（关到 0 才清）。

  提交哈希：`95cf95e85`（分支 `todo-758-nested-dismiss`）。
- **[x] ② 已加自动化测试** — 纯函数行为测试 + 源码扫描守卫，均扩展 `hibiki/test/pages/dictionary_child_popup_close_guard_test.dart`：
  - 行为：`VideoHibikiPage.shouldSwitchWordOnBarrierTap` 真值表——`topVisibleIndex>0 && hitSubtitle` 一律 `false`（嵌套态点字幕也不换词）；`topVisibleIndex<=0 && hitSubtitle` 为 `true`（单层保留换词）；`hitSubtitle==false` 任意层为 `false`（点空白逐层关）；`topVisibleIndex==-1`（仅热槽=无可见弹窗）命中字幕为 `true`（首次查词走旧路，无害）。撤门控（无条件反查）则嵌套态用例转红。
  - 源码守卫：断言 `_onDismissBarrierTap` 的字幕命中分支被 `VideoHibikiPage.shouldSwitchWordOnBarrierTap(` 门控、且仍含逐层关原语 `_popNestedPopupAt(_topVisiblePopupIndex);`，不再无条件 `if (hit != null)` 直接换词。
- **备注**：嵌套弹窗真实点击坐标命中底部字幕是 WebView/渲染几何产物，widget 测试照不到几何；门控判据（栈深度 → 是否换词）已由纯函数行为测试在 Dart 层覆盖。最终交互（在视频字幕里查词→弹窗内再查词→点第 2 个窗外面退回父词、再点外关栈续播）留真机/模拟器肉眼确认一次。
