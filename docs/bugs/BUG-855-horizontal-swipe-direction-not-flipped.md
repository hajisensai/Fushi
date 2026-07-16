## BUG-855 · 横排滑动翻页方向未随书写方向翻转（和竖排一样，应与日语相反）
- **报告**：2026-07-16（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的 `onSwipe` handler（旧代码只用 `invertSwipeDirection` 映射 `'left'/'right'`→forward/backward，不读书写方向）。对照：键盘方向键早已在 `hibiki/lib/src/shortcuts/reader_space_override.dart:80` 用 `leftIsForward = rtl ^ reverse` 按书写方向翻转，滑动路径漏了。
- **[x] ① 已修复** — 提交 <PENDING>
  - 根因：触摸/鼠标滑动翻页方向此前只看 `invertSwipeDirection`（默认 true，为竖排 vertical-rl 调），横排 `horizontal-tb` 复用同一套映射 → 横排「下一页」方向与竖排相同（错），本该相反：竖排 RTL 下一页在左，横排 LTR 下一页在右。
  - 修复：新增纯谓词 `swipeLeftIsForward({invert, rtl}) => invert ^ rtl`（`reader_space_override.dart`），与键盘 `rtl ^ reverse` 同构；`onSwipe` handler 改用它算 `leftIsForward`，`_isRtlReading` 传入。四象限：竖排默认(rtl=T,invert=T)→false（右滑前进，**与历史一致，不破坏手感**）；横排默认(rtl=F,invert=T)→true（左滑前进，LTR 下一页在右）。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/swipe_page_turn_direction_test.dart`（锁 `swipeLeftIsForward` 四象限：横竖排恒相反、竖排默认不变、invert 开关整体取反）。
- **备注**：真机需在横排模式复测滑动方向；竖排行为不变（回归风险低）。与 [[BUG-854]] 同 PR、同一次真机验证。
