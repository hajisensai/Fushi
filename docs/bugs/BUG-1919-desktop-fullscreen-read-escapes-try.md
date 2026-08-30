## BUG-1919 · Linux/macOS 上桌面全屏读写的异常逃出 try，漫画页 widget test 在 CI 上全红
- **报告**：2026-08-28（发现者：合并值班，CI 红回溯）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/shortcuts/global_navigation.dart:391 / 399 / 469`（修前为裸 `return`）

  `readDesktopWindowFullscreen` / `setDesktopWindowFullscreen` 的每个平台分支都包在
  try/catch 里，目的只有一个：platform channel 不可用时安静返回 null——调用点是
  `unawaited(_readInitialFullscreenState())`（`manga_fushi_page.dart:960`），逃出去
  的异常没有任何人接。

  但 async 函数里 **`return <future>;` 不受外层 try/catch 保护**：try 块在那个
  future 完成之前就已经退出，只有 `return await <future>;` 才会被收住。修前：

  | 分支 | 写法 | 结果 |
  |---|---|---|
  | Windows | `final bool fullscreen = await windowManager.isFullScreen();` | TypeError 被 catch → 返回 null → 无害 |
  | Linux | `return windowManager.isFullScreen();` | 同一个 TypeError **逃出 catch** → 未处理 zone 异常 |
  | macOS | `return WindowManipulator.isWindowFullscreened();` | 同上 |

  异常本身来自 `window_manager 0.5.x`：`Future<bool> isFullScreen() async =>
  await _channel.invokeMethod('isFullScreen')`，widget test 里该 channel 没有
  handler、返回 null，`Null` 转 `bool` 抛 TypeError。

  症状：**每一条挂载漫画页的 widget test 在 Linux CI 上全红，本机 Windows 恒绿**
  （`manga_fushi_page_test` 2 条 + `manga_spread_double_page_test` 2 条）。而且报错
  只有一句 `Test failed. See exception logs above.`——因为 `flutter_test` 把异常正文
  走 `print` 事件吐出，而 `flutter_test_failures.dart` 当时完全不收 print 事件
  （同批一起修，见下）。两个缺陷互相掩盖：Linux-only 让本机复现不了，报告器吞诊断
  让 CI 上看不出原因。

  生产影响不限于测试：Linux / macOS 上任何一次全屏状态读取失败（channel 未就绪、
  插件缺失）都会变成未处理异常，而这段代码写出来就是为了吞掉它。

- **[x] ① 已修复** — `95420d4e95` 之后的提交：三处裸 `return` 全部改成 `return await`
  （`global_navigation.dart:391 / 399 / 469`）。同批把 `flutter_test_failures.dart`
  的 print 事件收集补上，否则这类红在 CI 上永远没有诊断信息。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/desktop_fullscreen_error_containment_guard_test.dart`
  两条：①源码守卫，`global_navigation.dart` 里不得出现裸
  `return windowManager.… / return WindowManipulator.…`（带锚点断言，改名后不会静默空转）；
  ②语义前提测试，直接钉住「裸 return 逃出 try、`return await` 不逃」这条 Dart 语义。
  变异实测：把 Linux 读分支改回裸 return，守卫立刻红（`Actual: ['return windowManager.isFullScreen(']`），
  sha256 校验回滚。
- **备注**：引入于 `acfbd54a42 feat(windows): stabilize immersive reader chrome`
  （给漫画页 initState 加了 `unawaited(_readInitialFullscreenState())`）。在
  develop 上从 2026-08-28 11:40 那次 push 起持续红。这类「只在非本机平台红」的缺陷
  只有 CI 能抓，本地 Windows 全量永远绿——判绿不能只看本机。
