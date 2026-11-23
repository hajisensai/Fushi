## BUG-5349 · 小说与漫画左右翻页方向判据不一致
- **报告**：2026-11-23（应用内反馈 #uz_2m0E_Eu，开发者本人：「怎么感觉书籍的方向键左右翻页和漫画的翻页不太一样」，Windows，竖排小说 + 有声书）
- **真实性**：✅ 真 bug（方向判据部分）。两个阅读器各写一份「左右翻页跟随阅读方向」：
  - 漫画 `fushi/lib/src/shortcuts/manga_arrow_override.dart:20`（`resolveMangaArrowPageTurn`）与 `:79`（`resolveMangaDpadPageTurn`）只判「该键是不是翻页动作」，随后一律按跨页方向改写——用户把右键改绑成「上一页」，在 ltr 漫画里会被改回「下一页」。小说早在 BUG-3805 改成「只接管出厂绑定」，漫画没跟上。
  - 小说手柄入口 `fushi/lib/src/pages/implementations/reader_fushi/caret.part.dart:521`（`_handleGamepadButton`）直接按注册表执行，不看阅读方向：竖排（vertical-rl）书里 D-pad 左 = 上一页，而同一本书的键盘 ← 与日漫里的 D-pad 左都是下一页。
- **[x] ① 已修复** — 新增唯一原语 `fushi/lib/src/shortcuts/directional_page_turn.dart` `resolveDirectionalPageTurn`（物理侧 + 出厂绑定判据 + `rtl ^ reverse`），小说键盘 `resolveReaderArrowPageTurn`、新增的小说 D-pad `resolveReaderDpadPageTurn`、漫画键盘 / D-pad 两个函数都只委托它，不再各写方向判据；小说 `_handleGamepadButton` 接上 D-pad 校正。「反转方向键翻页」开关仍只管小说键盘（TODO-120 定义）。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/directional_page_turn_parity_test.dart`：五个平台的真实默认键位表，按键事件 → 注册表 → 方向校正整条链路，rtl / ltr × 键盘 ← → / D-pad 左右，断言小说与漫画翻向同一侧；ltr 书里右键改绑「上一页」两种书都尊重；原语真值表；源码守卫（小说手柄入口经过 D-pad 校正、两个 override 文件不再自写方向判据）。`fushi/test/shortcuts/manga_arrow_override_test.dart` 旧的「与原绑定前进/后退无关」不变式改为与小说同判据。
- **备注**：反馈里的「不太一样」还包含几处**有意设计**的差异，不在本条改、已写进拍板台（id uz_2m0E_Eu）交维护者取舍：有声在场时裸 ← → 漫画是上下句、小说仍翻页；长按 ← → 小说连发翻页、漫画刻意不连发；查词弹窗开着时漫画 ← → 关弹窗并翻页、小说不处理；「反转方向键翻页」开关只在小说。真机未复测新构建。
