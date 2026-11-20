## BUG-4906 · 「选一种库页布局」点「稍后再说」后紧接着又弹「库页现在默认封面网格」
- **报告**：2026-11-19（用户：本地 debug 包启动反复被问库页布局）
- **真实性**：✅ 真 bug。首页首帧串行弹两个各自独立判定的一次性弹框：G1 选择框
  `maybeShowShellLayoutChoice`（`fushi/lib/src/pages/implementations/home_page.dart:750`）与 pr3454 提示
  `maybeShowLibraryLayoutDefaultNotice`（`home_page.dart:770`）。选择框点「稍后再说」不写 `shell_content_layout`，
  提示的判定 `decideLibraryLayoutDefaultNotice`（`fushi/lib/src/pages/implementations/library_layout_default_notice.dart:45`）
  看到「升级用户、没选过布局」就再弹一遍，且两者对「新默认」的说法相反（选择框标拼贴为新，提示说默认改封面网格）。
- **[x] ① 已修复** — 判定加 `layoutChoiceOffered`（本安装出厂判定不是 `ShellLayoutInstallDefault.fresh`，即归 G1
  选择框管）：这类安装只落标记、不弹提示。选择框已覆盖「拼贴仍可选」的告知。
- **[x] ② 已加自动化测试** — `fushi/test/pages/library_layout_default_notice_test.dart`
  「归「选一种库页布局」选择框管的升级用户：只落标记，不在「稍后再说」后再弹一遍」。
- **备注**：修复后 pr3454 提示的 `show` 分支实际只剩出厂判定为 `fresh` 却已有 `first_time_setup` 的极端情形，
  基本不可达；是否整体删掉这条提示（及其 4 个 i18n key）留给维护者定。未做设备肉眼复测（纯判定逻辑，单测覆盖）。
