## BUG-1236 · 移动端阅读器选区菜单阻断手柄拖动
- **报告**：2026-07-29（用户：Android 长按选区后无法继续拖动前后手柄）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:434` 的旧实现用 `showMenu`；它创建带全屏 `ModalBarrier` 的 `PopupRoute`，菜单显示期间 WebView 手柄收不到触摸，手柄松开又重弹菜单。
- **[x] ① 已修复** — commit `e6c5e5e98`：`chrome.part.dart:434-635` 改为非模态 `OverlayEntry`，手柄重入只刷新 payload/位置；清选区、收敛查词、隐藏手柄和页面 dispose 都移除并 dispose 操作条。Android 条内保留查词/复制并新增 `Share.share` 与系统网页搜索。
- **[x] ② 已加自动化测试** — commit `e6c5e5e98`：`hibiki/test/reader/reader_selection_action_bar_nonmodal_guard_test.dart` 锁定无 `showMenu/showDialog`、Overlay 生命周期、四项 Android 动作及普通原生选区菜单反向守卫；相关定向套件 39/39。
- **备注**：源码守卫不能代替 Android 触屏 WebView 真机拖柄复测；当前只能标 `implemented_unverified`，由非施工 reviewer 在受支持 Android 运行链验证。
