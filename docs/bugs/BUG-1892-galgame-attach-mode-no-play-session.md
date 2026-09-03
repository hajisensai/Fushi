## BUG-1892 · galgame 附着模式不记录游玩时长，停止捕获也不结算
- **报告**：2026-08-27（用户：「通过附着的方式游玩，不会获得游玩记录，需要修复」）
- **真实性**：✅ 真 bug。`fushi/lib/src/mining/gal_hook_session_controller.dart`（修前）：`_startPlayTracker` 全仓只有两个调用点（`:1418` 注入失败但游戏在跑、`:1516` 正常成功），都在 `launchGame()` 内；`startAttachedCapture()`（`:1133-1248`）整条路径从不创建计时器，`galgame_sessions` 零写入。更底层的原因是 `_startPlayTracker` 首行 `if (gameId == null || gameId.isEmpty) return;`，而 attach 只拿到 `ExternalWindowInfo`（hwnd/pid/title），**从头到尾没解析过 `galgames.id`，也没有游戏目录**——`GalgamePlaySessionMachine` 的候选进程组重扫（`galgame_play_tracker.dart:299-311`）依赖 `gameDirectory`。
  当时的取舍写在 `:3218-3223` 的注释里（「裸 exe 启动没有库内身份，`galgame_sessions.gameId` FK 无处指向，刻意不落账」），但这理由今天已不成立：launch 路径自己早就解决了「裸 exe → 库内身份」的反查（`texthooker_page.dart:889-892` 的 `findGalgameByExePath`），attach 只是没跟上。而 attach 缺的最后一环——PID → exe 全路径——`_targetImagePathProbe`（`QueryFullProcessImageNameW`）**早就在这个类里**，`_lunaPcHooksForPid`（`:1084`）已经在用同一条链，只是没人把它接到身份解析上。
  同一根因族另外两处（一并修）：`stopCapture()`（`:1589-1641`）只 `_flushGameActivity()` + `_stopSources()`，**没有 `_stopPlayTracker()`**，点了「停止捕获」计时器还挂着跑到游戏进程死或 App 退出；`startAttachedCapture` 递增了 generation 却没 `_stopPlayTracker()`，launch→attach 切换时上一场计时器带着**旧 gameId** 继续累加（launch 自己在 `:1270` 做了这件事）。
- **[x] ① 已修复** — 消除「两条路径两套身份」这个特殊情况，而不是给 attach 补一份平行实现：
  - 新增 `GalHookSessionIdentity`（gameId / title / executablePath + `canTrackPlaytime`），作为 launch 与 attach 的**唯一**身份表示；两件必需事实缺一都不计时，且 gameId 缺席（不在库里）与 exePath 缺席（查不到路径）语义分开，不混成一个 bool。
  - 新增 `_resolveSessionIdentity()`：上层给了 `galgames.id` 就采信，没给就按 exe 路径反查；**exe 路径本身在 attach 下由 `_targetImagePathProbe(pid)` 得到**。反查走与库页启动同一个纯函数 `findGalgameByExePath`，两条路径不可能给出不同答案。
  - `startAttachedCapture` 接线：先 `_stopPlayTracker()` 结算上一场，再解析身份 → `_beginActivitySession(mediaKey: identity.gameId)`（不再是空 mediaKey + 会变的窗口标题）→ `_startPlayTracker`。计时起点放在附着动作本身，不挂任何一条 hook 成功分支上——附着时游戏**已经在跑**，注入成功与否不改变「用户此刻正在玩」。
  - `stopCapture()` 补 `_stopPlayTracker()`。
  - `ExitFlushRegistry` 登记在共用的 `_startPlayTracker`（`:3368`）内，attach 自动覆盖，桌面点 X 走 `exit(0)` 时结算照样写穿。
  - 唯一降级：exe 路径查不到、或查到了但不在 `galgames` 表里 → 不落游玩账（FK 无处指向）。这条不吞掉任何本可解析的情况。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_hook_session_controller_test.dart` 新增 5 条 + 2 条源码守卫：attach 接线计时并在进程退出后落库（含 `galgame_sessions` 行与 `activity_events` 时长行的 mediaKey/title/durationMs 一致性）、不在库里不落账、PID 查不到 exe 不落账、停止捕获当场结算、launch→attach 切换先结算旧场。整套 47 条通过，EXIT=0。
  变异实测：删掉 `_resolveSessionIdentity` 里的 PID→exe 反查 → 精确红「attach 接线计时」「停止捕获当场结算」「launch→attach 切换」3 条，两条降级用例仍绿（它们本就期望不落账）；还原后 sha256 与变异前一致（`b9e75483a5bd0a8a…`）。
- **备注**：Windows-only（galgame 域硬规则）。真机验证未做（用户已取消该环节）——未在真实游戏上跑过「附着 → 玩够 60s → 退出 → 查游玩记录」的 E2E，`kMinSessionSeconds` 门槛与前台归属判定在真机下的表现属于待补缺口。
