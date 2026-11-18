## BUG-4851 · 切 tab 时所有访问过的隐藏保活页跟着重建重排（外壳顶部让位挂在共同祖先上）
- **报告**：2026-11-16（用户：转来群反馈录屏「切 tab 变卡了」，只截了侧栏；逐帧拆出 7 处 130～420 ms 停顿）
- **真实性**：✅ 真 bug（Windows profile 构建实测复现，探针 `fushi/integration_test/home_tab_switch_perf_itest.dart`，数据根为安装版真实库拷贝，3840×2160 @2x / 144 Hz）。在库页（书架 / 漫画 / 视频 / 音乐 / 游戏 / 浏览 / 浏览器）与首页 / 查词 / 复习 / 设置之间切，那一帧 build 30～100 ms；同类之间切（漫画 ↔ 视频 ↔ 浏览）是干净的（< 16 ms）。timeline 里能看到切到「设置」「音乐」的那一帧，与本次切换无关、藏着的书架网格（`reader_fushi_history_page.dart` 的 `RefreshIndicator > … > SliverGrid`）被整份重建。
  - 根因：`fushi/lib/src/pages/implementations/home_page.dart:1697-1712`（修前行号，下同）按**当前可见 tab**（`_visibleTab`）算外壳大标题让出的顶部高度 `titleInset`——叠放标题的库页是 `kFushiFloatingChromeGap`（8），其余 tab 是 0——并在 `:1743` 用 `FushiFloatingChromeInset(top: titleInset, child: content)` 挂在 `_withAppleScrollChrome` 里，也就是**全部保活 tab 的共同祖先**上。跨类一切这个 InheritedWidget 的值就翻一次（`updateShouldNotify` 为真），所有访问过的隐藏保活页里读它的浮动工具区（`FushiFloatingChromeOverlay` 再算出嵌套 inset）、主滚动视图、网格全部被通知重建 + 重排，代价随访问过的 tab 数增长。`_hiddenTabContent`（BUG-2976）只挡住了「自上而下的 widget 重建」，挡不住祖先 InheritedWidget 的通知。
  - 与外壳改版（#3397）的关系：拿改版前一个提交（`c6e6e3664cb^1`）跑同一探针，各 tab 的耗时与改版后同一量级——这条不是改版引入的回归，是既有问题。
- **[x] ① 已修复** — `home_page.dart`：让位高度改为按 **tab 自己**算（`_shellTitleInsetFor(tab)`），由 `_buildTabContent` 在各 tab 自己的子树里下发 `FushiFloatingChromeInset`；`_withAppleScrollChrome` 不再下发。可见 tab 读到的值与修前一致，隐藏 tab 读到的值不再随可见 tab 变。提交 `67fae6543a5`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_tab_switch_hidden_inset_stable_test.dart`：挂真的 `HomePage`，访问书架后切到首页再切回，断言藏起的那一页读到的外壳让位高度始终是它自己的那份（修前旧代码上红：藏起的书架读到 0）。
- **备注**：
  - 实测对比见 PR 描述（修前 / 修后同一探针、同一数据根）。
  - 当时未处理、后续已另记并修（同一 PR）：查词 / 复习的整页重挂 → BUG-4849；书架切入的整页重建 → BUG-4847；回首页时藏着的书架被动重建 → BUG-4848；全屏设置卸载正文 → BUG-4850。设置与浏览器两页刻意不保活（理由见 BUG-4849 备注）。原记录：① 非保活 tab（查词 / 复习 / 设置 / 浏览器）每次切入整页重挂，首帧 build 30～80 ms，是「切走即销毁」设计的固有代价；② 可见 tab 每次 HomePage 重建都拿到新 widget 实例、整页重建一遍（书架 36～50 ms）；③ 没有自绘标题栏的平台（Linux、横屏安卓平板）进设置走 `_buildDesktopLayout` 的全屏分支（`home_page.dart:2043`），整个正文连同全部保活页被卸载，回来全部冷启动——本次未实测，只在写测试时撞到。
