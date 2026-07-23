## BUG-1022 · galgame 引擎组件下载确认弹窗点击不立即出现且多次点击叠出多个弹窗

- **报告**：2026-07-23（用户：截图「需要下载 galgame 引擎组件」确认框）
- **真实性**：✅ 真 bug。两个独立根因：
  - **根因 A（点了不立即弹）**：`GalgameHelperInstaller.ensureInjector`
    （`hibiki/lib/src/mining/galgame_helper_installer.dart:150`，修复前）在弹确认对话框
    **之前** `await _probeSize(arch)`。`_probeSize` 是一次 HTTP `HEAD`，连接超时 10s，且逐个
    镜像候选（`galgameHelperCandidateUrls`：直连 + 5 个 gh 代理前缀）串行尝试。弱网/GFW 直连
    卡住时，点击后要等 `_probeSize` 整轮返回（可达数秒）对话框才出现——用户感知为「点了没反应」。
  - **根因 B（多次点击多弹窗）**：两个启动调用点都无再入守卫：
    `games_library_page.dart:109` `_launchGame`（卡片 `onTap: () => unawaited(_launchGame(...))`）
    与 `texthooker_page.dart:302` `_launchGalgameEngineHook`。启动流程含位数探测、helper 确认/
    下载对话框、注入会话等多个 await，持续数秒；等待期间每次重复点击各自开一条独立启动流程，
    各自 `ensureInjector` → 各弹一个确认对话框，叠出多个。

- **[x] ① 已修复** — 提交 `<pending>`
  - 根因 A：`ensureInjector` 改为**立即**弹确认对话框（大小先填 `t.galgame_helper_size_unknown`），
    `_probeSize` 以 `unawaited(sizeProbe.then(...))` 在后台并发进行，返回后经 `ValueNotifier<String>`
    就地把「约 N MB」回填进对话框。`_confirmDownload` 参数由 `String` 改为 `ValueListenable<String>`，
    正文用 `ValueListenableBuilder` 监听刷新。对话框关闭后置 `dialogClosed` 守卫再 `dispose`，
    避免向已释放 notifier 写值。expectedSize 复用后台探测结果 `probedSize`（未就绪则 null，下载阶段
    仍靠 Content-Length / sha256 兜底）。
  - 根因 B：`_launchGame` 加实例 `bool _launching`、`_launchGalgameEngineHook` 加实例
    `bool _launchingGalHook` 再入守卫（进入即 `if (flag) return;`，`try/finally` 复位），等待
    期间的重复点击被忽略，只有一条启动流程、一个确认对话框。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_helper_launch_guard_test.dart`
  （静态守卫，本层为最强可落地层：`ensureInjector` 首行 `if (!Platform.isWindows) return false`，
  非 Windows 测试宿主进不了对话框流程，且对话框依赖真实网络探测，故以剥注释后的源码结构守卫锁死修复）：
  - A：`ensureInjector` 不得出现 `await _probeSize(`；探测必须 `unawaited(sizeProbe`；
    `_confirmDownload` 参数为 `ValueListenable<String>` 且正文含 `ValueListenableBuilder`。
  - B：两个启动方法体各含 `if (flag) return;` + `flag = true` + `finally` 内 `flag = false`。
- **备注**：main checkout 落后 origin/develop 881 commit，本修复基于 origin/develop 在 worktree
  `fix/galgame-helper-dialog-latency` 完成。Windows 真机验收：点击游戏卡片/引擎-hook 按钮应
  **立即**弹出确认框（大小随后从「未知」刷新为「约 1.0 MB」），弱网下连点多次只出一个框。
