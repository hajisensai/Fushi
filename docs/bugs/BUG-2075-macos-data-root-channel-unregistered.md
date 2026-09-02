## BUG-2075 · macOS 更改数据位置失败：data_root_access 通道未注册
- **报告**：2026-09-02（GitHub #1159；macOS `Version 2.2.1.12447 (12447)` 更改数据位置时报 `MissingPluginException`）
- **真实性**：✅ 真 bug。`fushi/macos/Runner/MainFlutterWindow.swift:26-27` 已把窗口顶层 controller 换成 `MacOSWindowUtilsViewController`，真正的 Flutter controller 位于其 `flutterViewController` 属性；但 `fushi/macos/Runner/AppDelegate.swift:10` 仍把顶层 `contentViewController` 直接转成 `FlutterViewController`。该转换恒失败，包住 `app.fushi/data_root_access` 与 `app.fushi.reader/foreground_selection` 的注册块被静默跳过；Dart 在 `macos_data_root_access.dart:22` 调 `createBookmark` 时因此收到 `MissingPluginException`。
- **[x] ① 已修复** —（本提交）`AppDelegate.applicationDidFinishLaunching` 改从 `MacOSWindowUtilsViewController.flutterViewController` 取得真实 engine messenger，再注册数据根与前台选中文本两个手写 MethodChannel；包装器缺失时写原生日志，不再静默跳过。
- **[x] ② 已加自动化测试** — `fushi/test/storage/macos_data_root_bookmark_guard_test.dart` 新增源码守卫：掩掉注释后钉住主窗包装结构，并分别验证两个通道的内部 engine messenger、`setMethodCallHandler` 与正确委托目标，禁止恢复顶层 `FlutterViewController` 强转。相关守卫 16 项通过，`flutter build macos --debug --no-pub` 成功。

### 两个通道的性质不同：一个是恢复，一个是首次启用

同一处强转挡住两个通道，但它们的历史完全不同，**验收标准也不同**：

| 通道 | 性质 | 依据 |
|---|---|---|
| `app.fushi/data_root_access` | **回归修复**（曾经能用约 11 小时，随后坏了约 2 个月） | 引入 `95b99c1881`（2026-07-02 15:47，`fix: stabilize macos migration and dictionary downloads`），经 merge `bdd10a2993`（2026-07-02 17:42）进 develop；被 `342f48d4ea` 弄坏（committer date 2026-07-03 04:24） |
| `app.fushi.reader/foreground_selection` | **首次启用**（从诞生起就没在任何 build 里注册成功过） | 引入 `0927fe3aa6`（2026-07-07，`feat(lookup): capture selection sentence context on macOS via Accessibility (TODO-1030 M1)`），**晚于**破坏者 `342f48d4ea`。`git show 0927fe3aa6:hibiki/macos/Runner/AppDelegate.swift` 显示它一出生就被包在已经恒假的 `if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController` 里；同一 ref 的 `MainFlutterWindow.swift` 早已是 `self.contentViewController = MacOSWindowUtilsViewController()` |

**验收含义**：`data_root_access` 只需回归验证「更改数据位置不再 `MissingPluginException`」。
`foreground_selection` 必须**按新功能在 macOS 真机单独验一次 AX 上下文捕获**——全局查词开启上下文捕获后，
`selection_capture_ffi.dart` 的 `captureForegroundContext` 能否真的从前台 App 拿到选中句子；
它从未在真机上跑通过，不能靠「通道注册好了」推断功能可用。**本轮未做这项真机验证**（本机是 Windows）。

### 考古：谁弄坏的、怎么坏的

破坏者 `342f48d4ea`（`feat(macos): port native macos_ui shell onto current develop (Approach C, Dart layers)`，
author 2026-07-01、committer 2026-07-03，**单父直推、没有 PR 号**，所以在 PR 列表里查不到）。

它在 `MainFlutterWindow.swift` 里做了这两件事：

```diff
-    let flutterViewController = FlutterViewController()
-    self.contentViewController = flutterViewController
+    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
+    self.contentViewController = macOSWindowUtilsViewController
...
-    RegisterGeneratedPlugins(registry: flutterViewController)
+    RegisterGeneratedPlugins(
+      registry: macOSWindowUtilsViewController.flutterViewController)
```

关键点：`MacOSWindowUtilsViewController` 是 **`NSViewController` 的子类，不是 `FlutterViewController` 的子类**，
真引擎躺在它的 `flutterViewController` 属性里。所以 `as? FlutterViewController` 恒为 nil。

该 commit **同步改了 `RegisterGeneratedPlugins(registry:)`**（生成插件因此一直正常），
**却完全没碰 `AppDelegate.swift`**（`git show 342f48d4ea --stat` 里没有这个文件）——
手写 MethodChannel 的注册块就此被静默跳过。这是「同一处结构变更有两个消费点，只改了显眼的那个」的典型形状：
生成代码那一侧有编译器和插件功能兜底，手写那一侧只在运行时静默失效。

- **备注**：异常发生在 `DataRootMigrator.migrate` 之前，未关闭数据库、未移动文件、未写 `data_root`，本次失败不会留下半迁移数据。
