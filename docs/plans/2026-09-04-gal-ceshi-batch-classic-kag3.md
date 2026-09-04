# 计划与台账：ceshi 批量适配 · 经典 KAG3（Fate RN / フタマタ恋愛，无 textrender.dll）

日期：2026-09-04。分支 `worktree-gal-kirikiri-classic-kag3`（base `worktree-gal-kirikiri-z-ceshi@e60d631914`，即 PR #1205 之上；develop 基底 `22802b971d`）。
上一批（KiriKiri Z tenshi_sz，BUG-2112~2115）见 `2026-09-04-gal-ceshi-batch-kirikiri-z.md`；再上一批（SGRE / ATRI）见 `2026-09-03-gal-ceshi-batch-adapt.md`。

## 用户验收标准（不变）

1. 高通用性；一引擎一任务、一独立 worktree。
2. 游戏内查词：单击字形弹卡；悬浮 + Shift 弹卡。
3. 悬浮字有高亮块；点击后整个词在台词里保持高亮，卡片收起后回到悬浮高亮。
4. 点卡片外关闭卡片时台词不推进。
5. 制卡带视频（动图覆盖整句）+ 整句音频（按句从游戏资源直提，不是系统混音）。
6. 尽量不看 hook 代码；真正的 hook 缺口必须修，不能用降级冒充。
7. 窗口模式与全屏各验一次。

## 本任务范围与静态身份（2026-09-04，未启动游戏）

队列里「恋爱成双」交接时被写成 KiriKiri Z 汉化版——**不对**：它是 フタマタ恋愛（2016 exe，中文版 `劈腿之恋.exe` 同体积），exe 段布局 `.text/.adata/.rdata/...` 与 tenshi_sz 同形（MSVC 构建的 KiriKiri Z，无导出表、`V2Link` 兜底），plugin 是 `KAGParser.dll` + `kropus.dll`（opus 语音），**没有 textrender.dll**。engine-support.yaml 2026-08-19 的负向测量就是它：传感器不装、游戏内查词整体缺席。

| 样本 | 引擎 | 身份 | 查词采集面 |
|---|---|---|---|
| `Fate_stay night/Fate/Fate／stay night[Realta Nua] -Fate-.exe`（破解补丁替换后的主 exe） | KiriKiri2 **BCB**（段 `ConstSeg/DataSeg/CodeSeg`，导出 `TVPGetFunctionExporter` + `_TVP*Form`，RTTI 含 `tTVPCharacterData`），x86，sha256 `9c195563b8724131…` | 原始入口是主 exe；`FateSaber.exe` 带 `.securom` 段不是原始路径；`エンジン設定.exe` 是设置器 | 经典 KAG3，无 textrender.dll |
| `恋爱成双/フタマタ恋愛.exe`（`劈腿之恋.exe` 汉化 exe） | KiriKiri **Z**（MSVC，`.adata`），x86，sha256 `07a2a3d6aa665e3e…` / `0cb927556f83b41b…` | 目录里有 `.le.config`（用户曾用 Locale Emulator 启动）与一份 crash.dmp（7 月） | 经典 KAG3（KAGParser.dll），无 textrender.dll |
| `アマカノ3/Amakano3.exe` | Artemis / iarsys **x64**（`iarsys64.dll` + `Amakano3.pfs`） | yaml `artemis_pfs` 条目：PF8 语音资源与 DirectSound PCM 已 verified，文本 luna_auto 待验 | 另一引擎，另开任务 |

两款经典 KAG3 的共同第一边界：游戏内查词传感器在这类游戏上**采不到字**（BUG-2116）。

## 根因与修复（BUG-2116）

- 旧 else 分支给 `global.Layer.drawText` / `global.MessageLayer.processCh` 赋值。TJS2 源码（krkrz `tjs2/tjsNative.cpp` `tTJSNativeClass::CreateNew`：`FuncCall(0, NULL, …, dsp) // add member to dsp`；`tjs2/tjsInterCodeExec.cpp` `tTJSInterCodeContext::CreateNew`：`ExecuteAsFunction(dsp, …)`）证明实例化把成员**拷进每个实例**，类对象上的赋值对实例永远不可见。2026-08-14 Fate RN「包装一次都没被调用」正是这个语义，不是时序也不需要原生 detour。
- 修复：逐实例补丁 `fushiLookupPatchClassicLayer` + `fushiLookupSweepClassicLayers`（安装时 + `fushiLookupRefreshCaptureBridges` 的 KAG stable 边沿），`fushiLookupCaptureDrawText` 加影/边重绘去重（±4px 同字合并、钉最小 x/y）。
- 守卫：`kirikiri_lookup_source_guard_test.py` 规则 3 取消 else 豁免 + 正向规则 `find_classic_sweep_missing` + 5 条变异；131/131 绿。`adapter_structure_test.py` 38/38 绿。
- 双架构 `build_distribution.ps1` + CTest：见下「验证记录」。

## 验证记录

- 2026-09-04 静态门：`kirikiri_lookup_source_guard_test.py` 131 OK；`adapter_structure_test.py` 38 OK。
- 双架构构建 + CTest（2026-09-04 13:17）：`tools/build_distribution.ps1` exit 0，`voice_hook_x86.zip` sha256 `069a4dee2611b483…`、`voice_hook_x64.zip` sha256 `58af80692aad572e…`；ctest x64 57/57、x86 57/57。
- 真机门：**未跑**。原因：用户此刻正在使用桌面（前台 QQ / Chrome，光标在动）；真机验证需要 SetCursorPos / mouse_event / 前台切换，与用户操作互斥。本轮起隔离 Fushi 做 KiriKiri Z 的 ① 复验时，两次 `fclick`（WindowFromPoint）落进了盖在隔离窗上面的用户 Chrome（2363,1311）与 QQ（1204,1425）窗口，随即停手、关闭隔离实例。**教训**：隔离 Fushi 不保证在最上层；点它必须用 `click <FLUTTERVIEW 子窗 hwnd>`（PostMessage 到指定 hwnd）而不是 `fclick`；且用户在用机器时不得驱动物理输入。

## 真机门（接手人照做）

1. 桌面空闲（用户确认或前台长期是空闲桌面）。库里先「导入 → 添加游戏」加入 Fate RN 主 exe（`japanese_locale_mode` 开：BCB KiriKiri2 需要 CP932）与 フタマタ恋愛（可先试 `劈腿之恋.exe` 也是同一 exe）。
2. 用 kirikiri-z worktree 已有的 Fushi 构建（Dart 侧本任务未改）+ 本分支 helper x86：`tools/install_into_bundle.ps1` 或直接把 `dist/voice_hook_x86.zip` 解到 `fushi/build/windows/x64/runner/Release/voice_hook/x86/`（`installed.sha256` 跟着换）。
3. 隔离实例 `launch_fushi_iso.ps1`（改 `-Exe` 指向那份构建）；启动游戏后 `EnableWindow(FALSE)` 主窗（memory `reference_test_hidden_fushi_steals_foreground_from_game`）。
4. 判据顺序：`fushi_voice_lookup_probe` 的 `classic_patch_installed`（bit 0x100）→ **`classic_geometry_captured`（0x200，决定性：字真从实例 drawText 经过）** → `geometry_observed` → 单击字形弹卡。若 0x100 亮而 0x200 灭：KiriKiri 控制台 / `Debug.notice` 看 `fushiLookupClassicSource` 位 3（0x8 = 至少挂上一个实例）——灭则 `kag.fore.messages` 结构非标准；亮而 0x200 灭则该游戏字不走 `this.drawText`（TYPE-MOON 定制路径），下一边界。
5. 通过后再按验收 2→7 走：Shift 悬浮、整词高亮、点外不推进（mclick 前 40ms 核 `GetForegroundWindow()==game`，`state_during=0`）、制卡（kropus/vorbis 语音走 KiriKiri 资源流）、全屏一轮。

## 未做 / 堵塞

- 真机门整个未跑（桌面占用）；yaml 状态不改。
- KiriKiri Z ① 「卡内 SentenceAudio 时长 = 源资源」复验：同样因桌面占用未做，工具链齐（`media_probe.py <query> <textseq>`）。
- アマカノ3（artemis_pfs x64）：文本线程真机待验，另开任务。
- 队列其余：Sakura Swim Club、AngelBeats trial、chronoclock trial、manosaba、昨日魔女、ISO 类（姫様LOVEライフ / 恋愛フェイズ / 屋上の百合霊さん / カスタムメイド3D2）：未盘点。

## 恢复指引

- worktree `D:\APP\vs_claude_code\hibiki\.claude\worktrees\gal-kirikiri-classic-kag3`，分支 `worktree-gal-kirikiri-classic-kag3`（堆叠在 PR #1205 分支上，#1205 合入后 rebase 到 develop 再开 PR）。
- 构建脚本：`C:\Users\wrds\.claude\jobs\a188f70d\tmp\build_dist.sh`（unset 小写代理变量 → `tools/build_distribution.ps1` → 双架构 ctest）。真机驱动脚本沿用 `C:\Users\wrds\.claude\jobs\3f9f84ac\tmp\`（launch_fushi_iso.ps1 / drive/galdrive.ps1 / media_probe.py）。
- 守卫：`native/galgame_hook` 下 `python tests/kirikiri_lookup_source_guard_test.py` / `adapter_structure_test.py`。
## 静态 probe 与遗留日志（2026-09-04 下午，桌面仍被占用）

`tool/galhook.ps1 probe` 三份脱敏包在 worktree `native/galgame_hook/build/probes/p{1,2,3}.zip`（不入库）：

| 样本 | exe SHA-256 | 架构 | 要点 |
|---|---|---|---|
| Fate RN 主 exe | `9c195563b8724131cfc5cfd7b32767597efba136d98bb81dfda2fdb242695c2a` | x86 | imports 只有系统 DLL（BCB 静态链接）；目录 `krmovie.dll` / `paul.dll` / `lang.ini` |
| フタマタ恋愛.exe | `07a2a3d6aa665e3e2c4958fbf9fecfd93a5c9baac797813a152736b1edba3245` | x86 | imports 含 MF/MFPlat/QUARTZ/dbghelp（KiriKiri Z MSVC）；plugin 目录 116 项含 KAGParser/ExtKAGParser/kropus/krdstheora/krmovie |
| Amakano3.exe | `5132eed8c2e4a7d0ec4d853cd2b8247f3a0641c4a3825a8210fd435530e7d716` | x64 | imports DSOUND/DINPUT/D3DCOMPILER_47/MF；`artemis_pfs` 引擎 |

Fate RN 引擎版本（来自用户 7-24 遗留 `krkr.console.log`，UTF-16）：**Kirikiri 2.31.2010.425 + KAG 3.25 beta 10 TYPE-MOON customized**。两份日志：
- 游戏目录 `savedata/krkr.console.log`：8 次会话**全部**在 `override.tjs(28) Plugins.link("fstat.dll")` 处 `Access Violation(write 0x0)`（fstat.dll 解到 `%TEMP%\krkr_*`），启动即崩。
- `Documents\FateRealtaNua_savedata\krkr.console.log`：5 次会话中 4 次正常、1 次同样 fstat 崩。→ 该崩溃**间歇**且与 Fushi 无关（7-24 早于 hook 工作），真机时若撞上就重开一次；不要把它记成 hook 缺口。两份日志都没有 `[HibikiLookup]` 行（8-14 那次的控制台输出没落盘）。

## 真机门第一轮（2026-09-04 13:40–13:50，桌面短暂空闲时）

**隔离 harness 本身有 bug（先于任何游戏结论）**：上一批沿用的 `launch_fushi_iso.ps1` 用 `APPDATA`/`LOCALAPPDATA` 环境变量隔离偏好与库——**无效**。path_provider 走 `SHGetKnownFolderPath`，不读环境变量，所以「隔离实例」一直在读写用户**生产库** `D:\APP\HIBIKI_date\support\fushi.db`（证据：往 `HIBIKI_gal_test\support\fushi.db` 插 Fate RN 行 + 把 tenshi_sz 改名成 `tenshi_sz (iso-marker)`，实例两次重启都不显示；实例运行期间该库无 `-wal/-shm`；库页 5 款与生产库逐条相同）。**推论：上一批（SGRE/ATRI/tenshi_sz）隔离实例的制卡、游戏会话、学习统计都写进了用户生产库**，schema 相同不会损坏，但活动记录里会多出测试会话。
正确隔离：`FUSHI_TEST_ROOT=<root>`（测试根优先于 dataRoot，`fushi/lib/src/storage/app_paths.dart` 顺序铁律），`<root>/app-support/fushi.db` 放快照、`<root>/app-documents` junction 到词典目录、`<root>/temp`。新脚本 `C:\Users\wrds\.claude\jobs\a188f70d\tmp\launch_fushi_iso2.ps1`，已验证：库页出现 `tenshi_sz (iso-marker)` 与 Fate RN，`test-root/app-support` 下出现 `-wal/-shm`。

**Fate RN 启动门（第一个未通过边界）**：库内点卡启动 → injector（staged `voice_hook_runtime/0dd3f669f39926fa/x86`，DLL sha 与本分支 dist 一致 `F75951C3…`）→ `Fate／stay night[Realta Nua] -Fate-.exe` PID 92360 起 → 立刻弹「スクリプトで例外が発生しました EAccessViolation」，主窗从未出现。krkr 控制台日志（游戏目录 `savedata/krkr.console.log` 第 9 个会话，13:45:29）：`Plugins.link("fstat.dll")` 处 `Access Violation(write 0x0)`，EIP 落在 `%TEMP%\krkr_*\fstat.dll` 偏移 `…A111`，与 7-24 用户自己经 Fushi 启动的 8 次完全同形。**相关性**：崩溃会话全部先有 `file://./c/users/wrds/documents/faterealtanua_savedata/ が存在していません`（目录实际存在），经 Fushi 启动 9/9 崩、普通启动 5 次仅 1 崩（那次也带同一「不存在」行）。Fushi 对 KiriKiri2 x86 默认 `auto` → 转区（Locale Emulator）；假说：转区下游戏对 Documents 路径的存在性判定失败 → 存档目录缺失 → `fstat.dll` 链接时写空指针。**下一门**：`galgames.japanese_locale_mode='off'` 已写入 test-root 快照（Fate RN 行），重启隔离实例后再点卡：若主窗出现 → 转区是根因（记 Fushi 侧 auto 判据缺口，另立 BUG）；若仍崩 → 与转区无关，回到 hook 早注入排查。桌面在 13:50 被用户占用，本轮到此。

## 队列其余游戏引擎盘点（静态，未启动）

| 目录 | 引擎 | yaml 条目 | 备注 |
|---|---|---|---|
| `AngelBeats-trial/StartData/gamedata/SiglusEngine.exe` | SiglusEngine | `siglus`（查词诊断位齐全） | 入口 `Start.exe` 是启动器 |
| `Sakura Swim Club/` | Ren'Py（`renpy/`、`lib/`、`.py`） | `renpy_ffmpeg` | 英文游戏，验收「日语查词」意义待用户定 |
| `昨日魔女今日的梦1.0汉化版/kinomajo/` | Unity（`Engine/`、`Manifest_UFSFiles_Win64.txt`） | `unity_il2cpp` | 汉化版，另有「带修改器启动.exe」 |
| `chronoclock-trial/.../cmvs32.exe / cmvs64.exe` | CMVS（Purple Software） | **无** | 新引擎，需骨架 |
| `manosaba_Ver1.0.3.part1~4.rar` | 未解压 | — | 先解压再判 |
| `bgimage/`（BootStrap.exe + plugin/…） | KiriKiri Z（库内 id 1785146004529760 也指向它的 tenshi_sz.exe） | `kirikiri_z` | 是天使☆騒々的另一份/引导器目录，非新游戏 |
| ISO 类（姫様LOVEライフ / 恋愛フェイズ / 屋上の百合霊さん / カスタムメイド3D2） | 未挂载 | — | 上一批已判堵塞 |
