## BUG-1424 · 漫画阅读器里 Esc 是死键：无词典弹窗时退不出漫画
- **报告**：2026-08-02（用户：要求 Esc 统一成「返回上一级」时排查发现）
- **真实性**：✅ 真 bug。根因是**两处叠加**：
  - `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:325`
    `inputActionForShortcut` 只认 `mangaDismissDict`，且**弹窗不可见时返回 null**
    —— 漫画 scope 里根本没有任何「退出」动作（阅读器有 `readerExitBook`、视频有
    `videoEscape`，只有漫画没有）。
  - 解析出 null 之后事件**不会**冒泡到最外层那条硬编码 Escape 兜底：漫画正文是原生
    WebView，键走 JS 桥 `navigationKeyBridgeScript`（`stopPropagation: true`，见同文件
    `webViewKeyBridgeScript` 调用）交给 Dart 的 `onMangaNavigationKey` handler
    （`manga_hibiki_page.dart:1942 _handleNativeNavigationKey`），Dart 侧丢弃后这一次
    按键就结束了，Flutter 的 KeyEvent 冒泡链根本没参与。
  - 于是：**有词典弹窗时 Esc 关弹窗（看起来是好的），没弹窗时 Esc 什么都不做**。
    用户只能用鼠标点顶栏返回或手势返回。框选识别模式（`_rescanModeActive`）下同理。
- **[x] ① 已修复** — 与「返回上一级全 app 统一」同一改动落地：新增
  `ShortcutScope.universal` + `globalBack`（默认 Esc / Alt+← / 手柄 B），漫画页在
  `manga scope` 未命中后兜底解析它，并新增 `MangaReaderInputAction.backOrExit`
  执行体（`Navigator.maybePop()`，走本页 PopScope 闸门）。阶梯语义：框选模式 →
  退出框选；有词典弹窗 → 关弹窗；否则 → 退出漫画。
  提交见本 PR（分支 `worktree-unified-escape-back`）。
- **[x] ② 已加自动化测试** — `hibiki/test/shortcuts/universal_back_test.dart`
  的「漫画：globalBack 有弹窗关弹窗、无弹窗退出（此前 Esc 是死键）」源码切片守卫：
  钉死 `MangaReaderInputAction.backOrExit` 存在、解析必须兜底 `ShortcutScope.universal`、
  以及 `globalBack` 分支的两级判据。另有「两个『只关词典』动作默认无键盘绑定」逐平台
  守卫，防止有人把 Esc 绑回 `mangaDismissDict` 而再次遮蔽退出那一级。
- **备注**：同一改动一并消灭了阅读器那条「设置页写着退书是 Ctrl+W、实际靠最外层硬编码
  Esc 才退得出去」的双轨（改键改不动真正生效的键），并把退书 / 退漫画 / 退视频 / 退
  设置页合并成**一个**配置项（用户拍板）。schema v7 → v8 迁移见
  `hibiki/lib/src/shortcuts/shortcut_registry.dart`。
