## BUG-2129 · 真机 WoH(HUNEX)合并构建:拉起/hook/音频/文本/风险确认均通过,原生几何 fail-closed 退到 attached 需标定
- **报告**：2026-09-03(代理按用户「测试 WoH」逐引擎真机验证;分支 codex/gal-generic-lookup-cards,已合并上游 develop 的 Windows Debug 构建)
- **真实性**：✅ 真机证据(单会话)。原始路径 `launch D:\smb\魔法使之夜\WITCH ON THE HOLY NIGHT\WoH.exe`(x64,SHA-256 `4475cc2f…5463ada`,库内转区档为空 → auto → x64 不转区)。逐阶段观测:
  - **process/helper/ipc/hook**:首拍 `launch_injection_failed` 后 `engine.attach_recovered (attempt:1)` + `engine.hook_ready`——**游戏未自退**(明显好于本会话早前 WoH 那次「native loopback ack 超时后游戏自退」,见 BUG-2126 备注前的 04:28 记录)。
  - **audio**:`audio.tracks_refreshed count:26`、`game_resource_late_ready`,`xaudioDiagnostics 0x78080001 / diag2 0x0000000c`。
  - **text**:文本 hook 抓到 8 行 typemoon 旁白(「……有珠、まだ帰ってきてないんだ」「重苦しい鉄の門は静かに…」「―――丘の上にはお化け屋敷が建っている。」「たとえば、もう何年も前に朽ち果てた廃屋なのに、夜になると明かりが灯ったりする。」),`audio=pending/game_resource`,WGC 抓窗口真实像素与屏上文字逐字一致。
  - **window**:`window.auto_bound`,WGC `shot game` 成功(窗口先挪到在线显示器)。
  - **risk gate**:初始 `attached=needsRiskAcceptance`,profile `unsafeLeftClickAccepted:false`、`request` 非空(BUG-2028 的持久请求 token 在 `suspended` 期仍在)。驱动 `accept` → `accept=true`、profile 变 `unsafeLeftClickAccepted:true`、request 清空——**本会话合并的 BUG-2028 风险确认流程真机生效**。
  - **geometry/lookup**:确认风险后 `attached=needsCalibration`,`variants:[]`。即 **HUNEX 原生 exact provider 未发布几何(fail-closed,与 BUG-2024 记录一致)**,回退到 attached 校准表面,而它需要标定(拖框 + start/middle/end 三点探针 + commit)才能映射字形。因此**点字弹卡这一步未能在本轮完成**。
- **[ ] ① 未修复/未验收** — 两条独立路可通向 WoH 点字弹卡,均未在本轮打通:① 让 HUNEX 原生 exact provider 真正发布几何(注入侧 hook 工作,本会话按用户边界未读改 hook,属 BUG-2024 范围);② attached 校准表面完成标定后走本会话改动的吞点击/Shift 悬浮路径。②的自动化难点:WoH 是全屏旁白,文本逐行换位置,`beginCalibration → updateCalibration(三点探针) → commitCalibration` 的探针必须命中 start/middle/end 真实字形,对移动文本很脆,`gal_realgame_driver_itest.dart` 目前无标定命令。
- **[ ] ② 未加自动化测试** — 待选定路径后补(HUNEX 原生 submit 契约 / attached 标定 → 点击吞噬 E2E)。
- **备注**：本条是 WoH 合并构建的**运行期边界证据**,不改 `engine-support.yaml` 的 `hunex_gge` 状态(仍 implemented_unverified)。正向结论:合并没有破坏 WoH 的 launch/hook/audio/text/window/risk 链,且风险确认流程可用。下一步「WoH 点字弹卡」需在 ①(hook)或 ②(标定自动化)里择一投入,均需真机 + 用户在场。真机驱动见 `fushi/integration_test/gal_realgame_driver_itest.dart` 的 `accept`/`profile`/`shot game`。

### 2026-09-03 第二轮（分支 claude/hunex-woh-lookup，base 52a188cb11）

**做了什么**：补齐本条 ② 点名缺失的驱动工具，并在原始路径上重跑取证。

- **驱动补了两条命令**（`fushi/integration_test/gal_realgame_driver_itest.dart`，仅测试代码，未加生产 API）：
  - `calibrate <l> <t> <w> <h> [fontPerH] [lineHeight] [align] [valign]`：用给定归一化文本框+排版直接走 `GalAttachedTextController.handleCalibrationCommitted`（`riskAccepted:true`、`calibrationProbeMask:7`）提交一份 profile，**绕过三点探针**，把 `needsCalibration` 一步推到 `activeAttached`。这正是本条 ② 记的「对移动文本很脆」的绕行办法。
  - `mine`：对当前会话最新台词行走与浮窗 ➕ 同一条采集链（`GalHookMiningCoordinator.mineLine`，封面/动图/静图格式与音质档全部取自真实偏好，写真 `BaseAnkiRepository`），打印 `noteId` / `result` / `audioMissing` / `degradedToStill` 供 AnkiConnect 取证。

- **真机结果：本轮卡在更靠前的 `text_ready`，未能推进到标定/查词/制卡。** 台账（本机唯一在线显示器，物理桌面 3840×2160 @200%，WoH 客户区 1788×1006 物理、原点 (1954,618)）：
  - **经 Fushi `launch` 拉起（PID 44220 / 49088 / 38468 三次）**：injector 日志 `[inject] remote LoadLibraryW fushi_voice_hook.dll wait=0 exit=0xCC150000` → `[launch] hook failed; game resumed without hooks so it still starts` → `ERR reason=readyTimeout`；随后 `engine.attach_recovered` + **`engine.hook_ready`**。但该恢复只带起了**音频**侧：`audio.game_resource_late_ready`、`tracks_refreshed count:26`、`xaudioDiagnostics 0x78080001` 全部正常，而**文本一行都没有到宿主**（`lines=0`，`phase` 始终 `waitingSignals`），期间用驱动 `click` 真实推进剧情 18+ 句、截图逐帧确认剧情在走（`shot_3/shot_6/shot_7`）。⚠️ **`engine.hook_ready` 的文案是「Engine hook and IPC are ready」，但此时 LunaHook 文本 hook 并未安装**——这正是 SOP 禁止的「用前一阶段推断后一阶段」，值得单独收口（见下）。
  - **用户手动启动游戏后 `attach`（PID 38008）**：出现 **`text.thread_hook_ready` / `engine.text_hook_ready {audioMode: text_only}`**，与 `launch` 路径明显不同；但宿主侧 `TexthookerService.entries` 仍为 0（`describeLines` 读的是未过滤全量表，故不是线程筛选造成的），选 `thread 3805832321809344322`（上一会话可用的 threadKey `luna:34d1085520256742`）后仍为 0。
  - **helper 身份已按哈希排除版本错配**：主 checkout / gal-generic 工作树 / 本工作树三份 `voice_hook\x64` 的 `fushi_voice_hook.dll`、`fushi_voice_injector.exe`、`LunaHook64.dll` SHA-256 与 `installed.sha256`（`0dfeaf40c65c282b…`）**逐一相同**，与本条第一轮取证时是同一份 helper。故本轮 `text_ready` 失败不是 helper 版本问题，也与本分支改动无关（本分支只动了音频收口与测试驱动）。
  - 对照：本条第一轮（同一天、同一 helper）`launch` 后文本是通的。故该失败**不稳定复现**，倾向于早注入 `LoadLibraryW` 失败 + 恢复路径只补音频的时序条件，而非确定性回归。
- **顺带确认的结构性限制（截图 `shot_3.png`）**：WoH 旁白是 **NVL 堆叠**——历史行淡出留在屏上，当前行在其**下方**逐行下移。attached 校准表面的模型是「单个 `bodyRect` + 等距行推进 + 每句从框原点重排」，**无法跟随逐句下移的当前行**；即便本轮 `calibrate` 命令可用，一份固定 profile 也只在当前行恰好落进标定带时有效。要在 WoH 上做到稳定点字查词，正路仍是本条 ① 的**注入侧原生几何 provider**（BUG-2024），attached 表面只能作单块固定文本框引擎的兜底。
- **状态**：`engine-support.yaml` 的 `hunex_gge` **仍为 `implemented_unverified`，本轮不提升**（`text_ready` 未过，`paired` / `e2e_verified` 更无从谈起）。①② 保持未勾。
- **下一步候选**：(a) 收口「`engine.hook_ready` 在文本 hook 缺席时不得宣称 ready」——把文本/音频两侧 readiness 拆开上报，避免会话显示成功却零台词；(b) 查早注入 `remote LoadLibraryW exit=0xCC150000` 的失败原因（与 BUG-2126 的 x86 KiriKiri `0xC0000005` 是不同码，需单独定性）；(c) HUNEX 原生几何 provider（BUG-2024）。三条都需要读/改 hook 侧，本轮按用户边界未动。
