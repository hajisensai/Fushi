## BUG-1483 · Windows 装进不可写目录后 WebView2 数据目录建不出来（启动必弹错 + 更新失败）
- **报告**：2026-08-10（用户：QQ 截图 ×4，Hibiki 1.2.0）
- **真实性**：✅ 真 bug。用户把 Hibiki 装到 `D:\Program Files\Hibiki`（普通用户不可写），一根因三症状：
  1. 安装器 `PrivilegesRequired=lowest`（`fushi/windows/installer/fushi.iss:32`）不提权，也没有选目录预检——手选不可写目录后复制阶段才蹦 `Error 5: 拒绝访问` 中断安装；
  2. 装进去之后（用户手动提权装成功），运行期 WebView2 默认把用户数据目录建在 **exe 旁**（`<exe>.WebView2\EBWebView`）：fork 默认环境点 `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:199` 在 `FUSHI_WEBVIEW2_USER_DATA_FOLDER` 未设时传 `nullptr`，而生产从不设该变量 → 普通权限进程写不进 Program Files → 每次启动弹「Microsoft Edge 无法读取和写入其数据目录」，阅读器/查词 WebView 整体不可用（截图 2/4，hibiki.exe 与 fushi.exe 两代都中招）；
  3. 应用内更新器写预检 `ensureWindowsInstallTargetWritable`（`fushi/lib/src/utils/misc/platform_updater.dart:1189`）如实报 `Cannot write to installation directory`（截图 3）——这是症状不是缺陷，预检本身工作正常。
  对照组：全局查词浮窗早已用 `%LOCALAPPDATA%`（`fushi/windows/runner/global_lookup_window.cpp:154` `OverlayUserDataFolder`），所以只有主应用内嵌 WebView 落在 exe 旁。
- **[x] ① 已修复** — 两层根因修复（commit 见 PR）：
  1. `fushi/windows/runner/main.cpp`：新增 `EnsureWritableWebView2UserDataFolder()`，在 Flutter engine 起来之前用探针文件实测 exe 旁可写性——变量已设（itest harness）原样尊重；exe 旁可写（含既有 `<exe>.WebView2` profile 可写）什么都不做，存量安装 profile 位置字节不变；不可写才把 `FUSHI_WEBVIEW2_USER_DATA_FOLDER` 指到 `%LOCALAPPDATA%\Fushi\WebView2`（fork 两个环境创建点都读这个变量）。值只由 exe 路径与 ACL 决定，同一 exe 多进程仍算出同一目录，单实例守卫（BUG-437）职责不变。
  2. `fushi/windows/installer/fushi.iss`：`NextButtonClick(wpSelectDir)` 写入预检（`InstallDirWritable`，探针文件实测），选到不可写目录当场中文提示改用户可写目录/提权后果，不再装到一半 Error 5。
- **[x] ② 已加自动化测试** — `fushi/test/tools/bug_1483_webview2_userdata_fallback_guard_test.dart`（源码扫描守卫，最强可落地层：C++/Inno 无法单测）。四条断言：runner 探测+回退存在、回退先于 engine 创建、fork 两环境点仍读覆盖变量、安装器选目录页预检存在。已做变异实测：注掉调用点 / 改 SetEnvironmentVariableW 变量名 / 改安装器探针名，三个变异分别被三条测试逮住（`+1 -3`）后反向还原复绿。
- **备注**：给已中招用户的现场处置——把 Hibiki/Fushi 重装到默认目录 `%LOCALAPPDATA%\Fushi`（用户数据/书库在数据根不在安装目录，重装不丢）；或对现有安装目录补写权限 `icacls "D:\Program Files\Hibiki" /grant "%USERNAME%:(OI)(CI)M"`。修复版对旧安装位置零迁移诉求：exe 旁 profile 可写就继续用，不可写的机器上本来也从没建成过 profile，没有可丢的状态。
