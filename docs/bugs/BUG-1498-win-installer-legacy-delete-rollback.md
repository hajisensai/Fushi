## BUG-1498 · Windows 升级中途失败后 app 彻底消失：[InstallDelete] 先删旧名二进制且不可回滚
- **报告**：2026-08-08（用户：升级后 app 完全打不开）
- **真实性**：✅ 真 bug，根因 `fushi/windows/installer/fushi.iss:56-67`（修复前）
  - 现场证据：注册表 `HKCU\...\Uninstall\{8F2C1A3E-...}_is1` 的 `InstallLocation=D:\APP\Hibiki\`（自定义目录），
    该目录里 `hibiki.exe` 与 `fushi.exe` **都不存在**，只剩 `unins000.exe`；时间戳显示那次安装只写了
    `data` / `magpie_bundle` / `mihon_bridge` / `unins000.*`，绝大多数 DLL 还停在前一天 —— 安装跑到一半没完成。
  - 根因 1：`[InstallDelete]` 在**复制任何新文件之前**执行，且 Inno 明确**不会**在安装失败/取消时回滚这些删除。
    旧脚本把 `{app}\hibiki.exe` / `hibiki_update_launcher.exe` / `hibiki_torrent_ffi.dll` / `hoshidicts_ffi.dll`
    放在该段，于是任何一次中途失败的升级都把用户从「还剩个能跑的旧版」变成「一个可执行文件都没有」。
    这几个旧名文件又都不与新文件同名，「复制前删」本来就没有任何必要性。
  - 根因 2：旧名快捷方式只清了 `{userdesktop}\Hibiki.lnk` 和 `{group}\Hibiki.lnk`，漏了任务栏固定项
    `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Hibiki.lnk`，它悬空指向
    已被删除的 `hibiki.exe` —— 用户点任务栏图标毫无反应。
  - 顺带：Inno 默认 `UsePreviousGroup=yes`，升级时从卸载键读回旧组名 `Hibiki`，`{group}` 解析成
    `...\Programs\Hibiki`，新建的 Fushi 快捷方式会落进一个叫 Hibiki 的文件夹（实测该目录现在是空的）。
- **[x] ① 已修复** — 旧名二进制 + 三处旧名快捷方式下沉到 `[Code]` 的 `CurStepChanged` / `ssPostInstall`
  （新文件全部落地之后才删）；`{app}\galgame_helper` 留在 `[InstallDelete]`（新包同样往 `{app}` 写 helper 组件，
  必须复制前删，且它不是可执行入口）；补上任务栏固定项清理；`UsePreviousGroup=no` + 清理遗留的
  `{userprograms}\Hibiki` 程序组。提交见分支 `fix/win-installer-legacy-cleanup`。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `fushi/test/build/windows_installer_legacy_cleanup_guard_test.dart`
  （4 条：`[InstallDelete]` 不得再出现旧名；ssPostInstall 必须删四个旧名二进制；ssPostInstall 必须覆盖
  desktop / group / TaskBar 三处快捷方式；`UsePreviousGroup=no` + 遗留程序组清理）。守卫读的是
  `CurStepChanged` 过程体并**剥掉 `//` 注释**，把断言字面量塞进注释骗不过它（已变异实测：
  注释掉任务栏那行仍然转红）。
- **备注**：平台限制（如实记录）——Windows 不提供程序化「固定到任务栏」的公开接口，所以任务栏那条
  只能删掉死链接，**无法**自动改指 `fushi.exe`、也无法重新固定；已经丢了固定项的用户需要手动再固定一次。
