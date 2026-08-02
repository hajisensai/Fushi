## BUG-1448 · injector 存在即跳过 ensureInjector，随包新组件永不换入

- **报告**：2026-08-02（用户报「捕获组件与本体版本不一致」后要求「你自己拿我 hibiki
  试试不就知道了」，在其真实安装 `D:\APP\Hibiki` 上取证定性）
- **真实性**：✅ 真 bug（根因 `hibiki/lib/src/pages/implementations/games_library_page.dart:561`
  等三处调用点，修复前）

### 用户机器上的一手证据（2026-08-02，本体 1.3.1+1171）

真实安装是 `D:\APP\Hibiki`（不是 `%localappdata%\Hibiki`，那份是 0.4.1+32 的陈年安装）：

| 项 | 值 |
|---|---|
| `galgame_helper/voice_hook_x86.zip.sha256`（随包，8/2 07:18） | `3a1c4192…` |
| `voice_hook/x86/installed.sha256`（已装，7/28 22:49） | `b72b437a…` |
| 随包 zip 实测 sha256 | `3a1c4192…` = 侧车，**完整性 OK**，安装器不会 fail closed |
| `voice_hook/x64/` | **不存在** |

逐文件比对随包 zip 与已装目录：

| 文件 | 结果 |
|---|---|
| `hibiki_voice_hook.dll` | **不同** |
| `hibiki_voice_injector.exe` | **不同** |
| `LunaHook32.dll` / `LunaHost32.dll` | 相同 |

只有 Hibiki 自编的两件变了、vendored 的 Luna 没变——正是 IPC v13 的指纹。取证时无任何
进程加载该 DLL（`tasklist /m` 空），排除「文件被占用导致换入失败」。

### 根因

版本对账逻辑本身是对的。`_ensureBundledVersion`（`galgame_helper_installer.dart:414`，
BUG-1246）会拿已装 marker 与随包侧车摘要对账，不一致就原子换入。

**但三个启动入口都把它挡在门外**：

```dart
if (GalHookSessionController.defaultInjectorResolver(is32Bit: is32Bit) == null) {
  final bool installed = await GalgameHelperInstaller().ensureInjector(...);
  if (!installed || !mounted) return;
}
```

而 `defaultInjectorResolver`（`gal_hook_session_controller.dart:933-941`）只做一件事：

```dart
return File('$directory\\voice_hook\\$arch\\hibiki_voice_injector.exe').existsSync()
    ? path : null;
```

于是「injector 文件在」⇒ 整个分支跳过 ⇒ **版本对账从不执行**。文件在、版本却是上一个
app 版本留下的，恰恰是最需要换入的情形，却是唯一被跳过的情形。

完整因果链：

1. 7/28 装下 x86 组件（marker `b72b437a`）
2. 8/2 本体更新到 `1.3.1+1171`（含 IPC v13，`kSharedVersion` 12 → 13）
3. 启动 32 位游戏 → resolver 看到 7/28 的 `injector.exe` 存在 → 返回非 null
4. → `ensureInjector` 整段跳过 → 随包 8/2 的新组件永远换不进去
5. → 注入 7/28 的旧 hook DLL → 建出 **v12** 契约的共享内存段
6. → 本体 want **v13** → `ProtocolMatches` 判否 → `protocol_mismatch`
7. → 降级 system loopback（用户截图的「降级运行 · 系统 Loopback（混音）」）
8. → 而 [BUG-1446](BUG-1446-gal-fallback-detail-dropped-in-session-card.md) 让
   `shm=12/want 13` 这条唯一能确诊的证据在会话卡上看不见

这也解释了为什么文案里那句「先彻底关掉游戏再重开一次」对用户无效：重开游戏只会用**同一份
旧 DLL** 再注入一次。BUG-1345 判定「包内不可能对不上」是对的——对不上的从来不是包内，
而是**磁盘上那份从未被更新的已装组件**。

### 修复与测试

- **[x] ① 已修复** —— 三个启动入口（`games_library_page.dart` / `galgame_home_page.dart` /
  `texthooker_page.dart`）删掉 `defaultInjectorResolver == null` 前置门，无条件调用
  `ensureInjector`。「要不要装」不该用文件存在性近似，「版本对不对」才是判据；
  `ensureInjector` 本身幂等，已就位且版本一致时快速返回 true。
  代价是每次启动游戏多一次随包 zip 的 SHA-256（x64 约 35 MB，~100 ms）——这是
  `_ensureBundledVersion` 有意的 fail-closed 设计（注释明写：不许让 marker fast path
  绕过「摘要不符必须拒装」的发布边界），放在秒级的游戏启动路径上可接受，不做妥协。
- **[x] ② 已加自动化测试** —— `hibiki/test/mining/gal_helper_version_check_reachable_test.dart`：
  逐个入口断言 ①确实仍在调用 `ensureInjector`（否则「没有短路」会因「压根没调用」假绿，
  那是更严重的回归）②源码中不得再出现 `defaultInjectorResolver`（短路的唯一形态）。
  变异实测：在 `games_library_page.dart` 上恢复原前置门 → 如期判红；反向替换还原后复绿。

- **备注**：已装组件目录里还留着 `backup-x86-before-claude-20260725-1331` /
  `backup-x86-before-codex-20260724-1955` 两个 backup 目录（历史 agent 手工干预的产物）。
  它们不在 `galgameHelperRequiredFiles` 清单里、也不参与换入，对本条无影响，但说明该目录
  曾被手工改过——**用户侧要真正恢复，装上修复版后启动一次 32 位游戏即可自动换入**；
  在那之前也可手工删除 `voice_hook/x86/installed.sha256` 强制走一次完整安装。
