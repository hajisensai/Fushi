## BUG-5060 · 「选一种库页布局」点「稍后再说」后紧接着又弹「库页现在默认封面网格」
- **报告**：2026-11-19（用户：本地 debug 包启动反复被问库页布局）；外部 PR #3756（samutw）
- **真实性**：✅ 真 bug。首页首帧串行弹两个各自独立判定的一次性弹框：G1 选择框
  `maybeShowShellLayoutChoice`（`fushi/lib/src/pages/implementations/home_page.dart`）与 pr3454 提示
  `maybeShowLibraryLayoutDefaultNotice`（原 `fushi/lib/src/pages/implementations/library_layout_default_notice.dart`）。
  选择框点「稍后再说」只把 `shell_content_layout_install_default` 记成 `grid`、不写 `shell_content_layout`，
  提示的判定看到「非全新安装、没选过布局」就再弹一遍，且两者对「新默认」的说法相反（选择框标拼贴为新，提示说默认改封面网格）。
- **根因**：设计重叠。pr3454 提示是在「所有人默认改封面网格」时加的；之后 G1 把出厂值拆成「新安装 = 拼贴、
  升级用户 = 封面网格 + 弹一次选择框」（`ShellLayoutInstallDefault`），升级用户的告知已由选择框承担，
  pr3454 提示的对象已不存在，判定却没跟着收：
  - 升级用户（出厂值 `upgradeChoicePending` / `upgrade`）：本该归 G1 管，提示照弹 → 本 bug。
  - 出厂值 `fresh` 的安装：此时没选过布局生效的是**拼贴**，提示说「默认封面网格」本身就是错话；唯一能走到
    `show` 的路径是首次启动在新手引导里杀进程（`first_time_setup` 已写、提示还没来得及落标记），下次启动就会给新用户弹这条错误提示。
  - 即 `show` 分支要么该由 G1 代劳，要么内容错误，没有一条正确的可达路径。
- **[x] ① 已修复** — PR 原修法是给判定加 `layoutChoiceOffered` 只落标记，`show` 分支随之成为死代码 / 错误路径；
  按拍板台 pr3756（维护者 2026-11-21 拍「做」）收敛成根本修复：整体删除 pr3454 提示（`library_layout_default_notice.dart`、
  首页首帧调用、`AppModel` / `PreferencesRepository` 的已处理标记读写、只服务它的 `shellContentLayoutChosen`、
  4 个 i18n key 经 `i18n_sync --remove`、集成测试夹具里的种子）。偏好键 `library_layout_default_notice_handled`
  冻结不改名，留在 `kKnownPreferenceKeys` / `ProfileKeys` 排除表里只为键名不被复用、存量行不进 Profile 快照。
- **[x] ② 已加自动化测试** — `fushi/test/pages/shell_layout_choice_dialog_test.dart`
  「首页首帧只有这一个库页布局提示（BUG-5060）」；「稍后再说」后选择框不再弹由
  `fushi/test/settings/shell_style_settings_effect_test.dart` 咬住。
- **备注**：未做设备肉眼复测（首帧弹框接线 + 纯判定，源码守卫与单测覆盖）。
