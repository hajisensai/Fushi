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
