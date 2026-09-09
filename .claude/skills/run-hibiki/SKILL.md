---
name: run-hibiki
description: Launch and drive the real Hibiki app (Flutter desktop/mobile) and look at what it renders — the off-screen Windows integration runner, deterministic navigation hooks, focus-driven interaction, and real-pixel screenshot evidence. Use this whenever you need to run the app rather than the unit-test suite.
---

# 跑起真 app 并驱动它（Hibiki）

「跑起来」= 启动**真的 Fushi app** 并操作它，然后**看截图**。不是 `flutter test`
跑单测，也不是 import 一个内部函数打印返回值。

Hibiki 有一条已验证的落地路径：**Windows 离屏集成测试 runner**。它启动真 app、
真数据库、真渲染树，抓真像素，而且**不抢用户焦点**（用户可以继续用别的窗口）。
默认先走这条；三端等价跑法（Android 模拟器 / Mac 跨机）见
[docs/agent/integration-testing.md](../../../docs/agent/integration-testing.md)。

## 0. 工具链（本机 flutter 不在 PATH）

一律用 `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat`（3.44.0，与 CI 同版），
`dart.bat` 同目录。**不要**用 `D:\flutter_sdk\flutter_3.41.6\...` 跑 `pub get` / `dart run`
——它会把 `.dart_tool/package_config.json` 与 `pubspec.lock` 切到 3.41.6，3.44 的
analyze 随即报一堆假错。其余本机约定见仓库根 `CLAUDE.local.md`。

## 1. 写一个驱动脚本（integration_test/*.dart）

runner 跑的是一份 `integration_test/` 下的 Dart 文件。骨架：

```dart
import 'package:integration_test/integration_test.dart';
import 'helpers/observe_capture.dart';   // captureFlutterFrame / captureReaderWebView
import 'helpers/library_fixture.dart';   // readyAppModel
import 'support/test_app_launcher.dart'; // launchFushiTestApp
import 'test_helpers.dart';              // waitForHome

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('说清这一跑要证明什么', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));

    final AppModel appModel = await readyAppModel(tester); // 等 initialise() 真完成

    HomePage.debugSelectTab?.call(HomeTab.settings);       // 确定性开页，别去点底栏
    await tester.pump(const Duration(seconds: 2));

    final ObserveShot shot = await captureFlutterFrame(tester, '01-settings');
    expect(shot.saved, isTrue);
    debugPrint('[my-probe] 当前帧文案: ${...}');            // 可 diff 的文本证据
  });
}
```

要点：

- **`HomePage.debugSelectTab`** 是确定性开页钩子；`ReaderFushiPage.debugCaptureWebView`
  是「阅读器 WebView 已建」信号（`readerWebViewReady()`）。
- **改了偏好就在 `finally` 里逐个还原**。同一份脚本在模拟器 / Mac 上跑的是用户真库
  （Windows runner 会重定向 APPDATA 到隔离根，但别指望）。
- **操作控件一律焦点驱动**（`FocusDriver` / `tester.sendKeyEvent`）：`Tab` 遍历 →
  Switch/按钮用 **Enter**（**不是空格**，app 把裸空格中和成了 `DoNothingIntent`）→
  Slider/Stepper/Segmented 用方向键。**禁止 `tester.tap` 与坐标点击**。
- 断言要挑**真的渲染出来过**的东西。设置主页是滚动列表，视口外的行根本不在树里；
  拿它们断言就是把「没滚到」当成「已隐藏」。做法：先抓基线帧的可见文案，只对基线
  里出现过的条目断言变化，并把覆盖数打印出来——覆盖数掉到 0 就说明测试已空转。

## 2. 跑（离屏、不抢焦点）

```powershell
# 在 fushi/ 下
.\tool\run_windows_itest.ps1 integration_test/module_gating_test.dart
```

- **target 用正斜杠**。经 Bash 工具转发时反斜杠会被吃掉，`integration_test\x.dart`
  会变成 `integration_testx.dart` → "Does not exist"。
- 默认离屏（`WS_EX_NOACTIVATE` + 屏外），完全不打扰用户。只有当 WebView 区域抓回来
  是空白时才加 `-Visible`（窗口挪到屏角、仍不夺焦点）。
- runner 会隔离 APPDATA / TEMP / WebView2 profile（每次是**干净库**，没有用户数据），
  并回收上一次崩掉的同 worktree runner 进程。

### 已知坑：CMake 配置阶段的 nuget（本机）

症状：`Unable to generate build files` +
`CMake Error ... Failed to install nuget package Microsoft.Windows.CppWinRT.2.0.210806.1`。

成因两段，**缺一不可**：

1. `permission_handler_windows` 的 CMakeLists 在**配置期**无条件跑
   `find_program(NUGET nuget)` + `nuget install`。
2. 本机 PATH 上的 `WinGet\Links` 里那个 `nuget.exe` 是**符号链接**，Windows 拒绝遍历
   （"无法遍历该路径，因为它包含不受信任的装入点"）。于是 `nuget install` 退非零 →
   `message(FATAL_ERROR)`。

关键陷阱：`find_program` 的结果被写进 **`build/windows/x64/CMakeCache.txt` 的
`NUGET:FILEPATH`**。第一次踩坑之后它就钉在那个坏链接上了——**光改 PATH 再跑没用**，
后续每次配置都读缓存。改缓存里那一行指向真身：

```bash
# build/windows/x64/CMakeCache.txt
NUGET:FILEPATH=C:/Users/Wight/AppData/Local/Microsoft/WinGet/Packages/Microsoft.NuGet_Microsoft.Winget.Source_8wekyb3d8bbwe/nuget.exe
```

（真身路径 = `Get-Item <链接> -Force` 的 `.Target`。包本来就在
`build/windows/x64/packages/` 里，nuget 联网核一下就返回 "already installed"；
runner 默认的 `-Proxy http://127.0.0.1:34151` 常常没起、探测失败会退成 `proxy=(none)`，
本机可用的是 `-Proxy "http://127.0.0.1:7890"`。）

## 3. 看结果——必须真的看截图

证据落在 `fushi/.codex-test/windows-itest/<runId>/`（不入库）：

| 文件 | 含义 |
|---|---|
| `screenshots/observe-*.png` | **权威**：`captureFlutterFrame` 直接对根 RenderView 的 OffsetLayer 抓图，与 OS 抓屏无关，离屏/被遮挡都拿得到真像素 |
| `screenshots/shot-NN.png` | PrintWindow 抓的窗口；Flutter/WebView 下**通常是全黑**，只证明窗口存在 |
| `command.log` | 完整 stdout/stderr + 实际命令行 + proxy/isolation 参数 |
| `exit-code.txt` | 真实退出码（脚本自己恒退 0，**别只看它**） |

**用 Read 工具打开 `observe-*.png` 看**。空白帧 = 启动失败，不是「跑过了」。
`captureFlutterFrame` 抓不到 WebView 原生纹理——EPUB 正文要用
`captureReaderWebView`（走 CDP `Page.captureScreenshot`，离屏可用）。

判绿只认 `command.log` 里的**退出码 + 实际执行数**；`| tail -N` 的退出码是 `tail` 的，
恒为 0，构建失败时零测试执行会被伪装成通过。

## 4. 需要真跑一个 Release 包时

```powershell
Get-Process fushi -ErrorAction SilentlyContinue | Stop-Process -Force   # exe 被占用时 install 步会静默不覆盖
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build windows --release --no-pub
```

新 worktree 首次 Release 构建要从主 checkout 拷
`native/fushi_torrent/prebuilt/windows-x64/*.dll`（gitignored）。

真机自动化只操作窗口类 `FLUTTER_RUNNER_WIN32_WINDOW`；**绝不要最大化
`FushiGlobalLookupWindow`**（Fushi Lookup，停在屏外）——WebView 平台视图销毁时会
abort（0xc0000409）。

## 5. 相关文档

- [docs/agent/integration-testing.md](../../../docs/agent/integration-testing.md) — 三端架构、焦点驱动、AnkiDroid provisioning、DB 查询
- [docs/agent/computer-use-testing.md](../../../docs/agent/computer-use-testing.md) — 离屏/非焦点抓真实像素、确定性开页钩子、证据留存
- [docs/agent/reader-debugging.md](../../../docs/agent/reader-debugging.md) — 阅读器 WebView / 分页 / 恢复位置排障
