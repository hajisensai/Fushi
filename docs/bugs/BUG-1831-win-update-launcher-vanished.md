## BUG-1831 · 改名让路后新 launcher 被回滚删除，安装目录再无 launcher，自更新永久卡死
- **报告**：2026-08-24（用户：「自动更新修复生效没有，你看看」+ 截图「下载失败: UpdateInstallerException: update launcher not found: D:\APP\Hibiki\fushi_update_launcher.exe」）
- **真实性**：✅ 真 bug —— BUG-1786 修复自身带出的第四层缺陷，现场证据齐全（安装目录清单 + 应用日志 + updates 目录）

### 用户现场

用户问的是「BUG-1786 那个自动更新修复生效没有」。答案是**没有，而且这台机器已经卡进一个比
BUG-1786 更死的状态：应用内更新连安装器都起不来了**。

| 证据 | 值 |
|---|---|
| `D:\APP\Hibiki\data\app.so`（全部 Dart 代码） | **2026-08-19 05:12** |
| `D:\APP\Hibiki\fushi.exe` | 2026-08-23 18:56 |
| `D:\APP\Hibiki\fushi_update_launcher.exe` | **不存在** |
| `D:\APP\Hibiki\fushi_update_launcher.old.exe` | 存在（2026-08-19 05:18） |
| `%APPDATA%\Fushi\Fushi\updates\` | 8-18 ~ 8-24 共 13 个 `.meta.json`，**一条 `.install.log` 都没有**，历次 setup.exe 全被回收 |

即 BUG-1786 记录的半更新态（新 exe + 8-19 的 Dart 代码）原样还在——那一版修复**从没装进这台
机器**，所以用户点更新走的仍是旧逻辑、旧判据。应用日志（2026-08-24 19:35，连续三次）：

```
WindowsInstaller.handoffPrepared  target=2.2.1-debug.12215, installer=...\fushi-2.2.1-debug.12215-windows-setup.exe
WindowsInstaller.launchFailed     UpdateInstallerException: update launcher not found: D:\APP\Hibiki\fushi_update_launcher.exe
  #0 WindowsInstaller.runAndExit (platform_updater.dart:718)
```

包下载完好（249 MB 落盘），**安装器一次都没起来**——所以 updates 目录里连一条 Inno 日志都不会
产生，任何基于日志的诊断都拿不到材料。

### 根因

`fushi_update_launcher.old.exe` 这个名字全仓库**只有一处**能产生：`fushi.iss` 的
`MakeWayForRunningLauncher`（BUG-1786 修复第 3 条「改名让路」）。所以链条是：

1. 某次应用内更新跑了**带 BUG-1786 修复的新包**，Inno 探测到 launcher 被自己占用 →
   改名成 `.old` 让路（这一步按设计工作了）；
2. 那次安装在后面某个文件上**仍然回滚了**。关键在于：**改名之后
   `fushi_update_launcher.exe` 这个路径是空的，Inno 往里写的是一个「新建」文件，而 Inno 的回滚
   会删除本次新建的文件**——只有被覆盖的已存在文件才像 BUG-1786 ② 说的那样原样保留。
   于是原件（已改名成 `.old`）+ 新件（被回滚删掉）双失，`{app}` 下**再也没有 launcher**；
3. 此后每一次应用内更新都在 `runAndExit`（`fushi/lib/src/utils/misc/platform_updater.dart:718`）
   撞 `update launcher not found` 并直接抛出，安装器一次都起不来。

BUG-1786 备注里写的「存量用户下一次应用内更新即自愈」那条通道，被修复自己切断了：它假定
安装目录里**总有**一个 `fushi_update_launcher.exe` 可用，而「改名让路」恰恰把这个文件从
「必然存在」变成了「可以永久消失」。用户只剩手动跑安装包一条路，且不做就永远收不到任何更新。

`MakeWayForRunningLauncher` 还会**主动毁掉**唯一的恢复材料：它开头无条件
`if FileExists(Stale) then DeleteFile(Stale)`，然后才 `if not FileExists(Launcher) then Exit`。
即在「原件已消失、只剩残留」这个状态下先把残留删了再退出——把「还能自愈」变成「彻底没救」。

### 修复

1. **`platform_updater.dart`**：新增 `resolveWindowsUpdateLauncherSource()`——按序解析一份
   **实际存在**的 launcher 映像：原件 → `fushi_update_launcher.old.exe` → 带序号的退让名
   （前缀 + `.exe` 扫描，不硬编码名字清单）。`runAndExit` 用它做 stage 源与 executable，
   两者皆无才抛 not found。`.old` 与原件是同一份映像，拿它把这次安装跑完，Inno 就会把新
   launcher 装回原位——**这台机器下次点更新即自愈**，不需要手动装包。
   回退时打一条 `WindowsInstaller.staleLauncher` 日志，不让自愈变成静默行为。
2. **`fushi.iss`**：`MakeWayForRunningLauncher` 补上恢复语义与顺序不变式——
   原件不在而残留在 ⇒ `RenameFile(Stale, Launcher)` **改回去**再退出（本次安装随后正常覆盖它）；
   删残留只在「原件在位且未被占用」的分支里做。另外让路目标删不掉时（残留可能正是拉起本
   安装器的那个进程，即自愈路径）退让到带序号的名字，不因一个删不掉的残留放弃整次安装。

- **[x] ① 已修复** — `fushi/lib/src/utils/misc/platform_updater.dart`（`resolveWindowsUpdateLauncherSource` + `runAndExit` 改用它）、`fushi/windows/installer/fushi.iss`（`MakeWayForRunningLauncher` 恢复分支 + 顺序 + 序号退让）
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_launcher_vanished_test.dart`（6 条：解析优先级四态 + 前缀误命中负例 + 走真实 `runAndExit` 黑盒断言「只剩 `.old` 时拉起的是 `.old`」，直接钉住用户现场的磁盘状态）
  + `fushi/test/build/windows_installer_launcher_lock_guard_test.dart` 追加 1 条（钉住 iss 的恢复分支与「先判原件在不在、再谈删残留」的顺序）

### 备注

- **仅 Windows 受影响**：这条链路是 Inno + `fushi_update_launcher.exe` 专有。
- 用户机器当前仍是半更新态（新 exe + 8-19 的 app.so）。装上本修复之前它发不出任何更新，
  需**手动跑一次完整安装包**（已下载好的 `fushi-2.2.1-debug.12215-windows-setup.exe` 即可）恢复
  一致；装上之后 `.old` 兜底与 iss 恢复分支同时到位，这个状态不会再出现。
- **未做（明确记一句）**：本轮没有真机复跑「只剩 `.old` → 点更新 → 装完整」这条端到端路径
  （需要一台处于该状态的机器 + 一个含本修复的正式包）。Dart 侧行为由走真实 `runAndExit` 的
  黑盒测试覆盖，iss 侧只有源码守卫，恢复分支本身**未经 ISCC 运行期实测**。
- BUG-1786 ② 里「已经复制成功的文件原样保留」这句话只对**被覆盖**的文件成立；对改名让路后
  变成「新建」的文件，回滚会删掉。这个区别正是本 bug 的全部内容，后续再动让路逻辑时须记住。
