## BUG-1748 · 浏览器扩展页被设置 push 进来时没有返回键
- **报告**：2026-08-19（用户：设置 → 查词 → 浏览器扩展，进去之后没有返回键）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/pages/implementations/browser_extension_page.dart:143`
- **[x] ① 已修复** — `browser_extension_page.dart` 的 `FushiPageHeader` 按 `Navigator.canPop()` 补 `leading` 返回键
- **[x] ② 已加自动化测试** — `fushi/test/pages/browser_extension_page_back_button_guard_test.dart`（源码扫描守卫，已变异实测：退回无 leading 的原状必红）
- **备注**：最初以 BUG-1741 提交（见 commit 信息），开 PR 前 `bug.dart check` 报与在飞分支 `worktree-fix-four-issues-20260819` 撞号，按规则 `renumber 1741 1748`。

### 根因

`BrowserExtensionPage` 是**双身份页**，但只按其中一半写了页头：

1. 桌面顶层导航 tab（`home_page.dart` 的 `HomeTab`）——侧栏在旁边，`canPop()` 为 false，本就不该有返回箭头。BUG-1658 把顶层各 tab 页头统一成 `FushiPageHeader` 大标题时，只考虑了这一半。
2. 设置项 `settings_schema_lookup.dart:164` 的 `SettingsNavigationItem` 又把**同一个 widget** `pushSettingsPage` 成全屏 `MaterialPageRoute`（`settings_actions.dart:17-27`，裸 push 不套页壳）。此时它推在根 Navigator 上，**把左侧导航栏一起盖掉**，而 `FushiPageHeader(title: ...)` 没传 `leading`、`Scaffold` 也没有 `appBar` ⇒ 页面上不存在任何返回控件。

对照组说明这不是页壳的锅：相邻的「词典管理」走 `AdaptiveSettingsScaffold` → `FushiToolScaffold` 拿自动 leading；「自定义 CSS」「管理音频来源」是 dialog 自带关闭。

同仓 `DownloadsPage` 是**完全同构的双身份页**，它按 `canPop()` 分流（`downloads_page.dart:172-190`），注释原文写着「独立 push 进来（无 home 壳）时在 leading 位保留返回按钮——旧 AppBar 的自动返回键由这里承接」。本页漏掉了这一半。

### 不是死锁，但属 UI 缺失

Esc 实际可退：`ShortcutAction.globalBack` 默认绑 Esc / Alt+← / 手柄 B（`shortcut_defaults.dart:161-166`），处理体 `global_navigation.dart:222-230` 判 `_topRouteIsPopup` 为 false（这里是 `MaterialPageRoute` 不是 `PopupRoute`）⇒ 真 pop，且该页没写 `PopScope` 拦截。但没有任何视觉提示，鼠标用户唯一能做的就是关窗口。

### 修复

`browser_extension_page.dart:143` 照抄 `DownloadsPage` 既有范式，按 `Navigator.of(context).canPop()` 给 `leading`。作顶层 tab 时 `canPop()` 为 false，`leading` 仍是 null，**页头几何与 BUG-1658 的结论完全不变**。

未选用的替代方案：改用 `AdaptiveSettingsScaffold`/`FushiToolScaffold` 拿自动 leading——那会把顶层 tab 的页头几何换成小标题工具栏，正是 BUG-1658 修掉的东西，属回归。
