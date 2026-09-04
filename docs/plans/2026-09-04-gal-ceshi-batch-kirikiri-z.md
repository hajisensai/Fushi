# 计划与台账：ceshi 批量适配 · KiriKiri Z（tenshi_sz 全验收 + BUG-2070）

日期：2026-09-04。分支 `worktree-gal-kirikiri-z-ceshi`（base `develop@22802b971d`）。
上一批（SGRE / ATRI，PR #1182 + BUG-2082~2087）见 `2026-09-03-gal-ceshi-batch-adapt.md`。

## 用户验收标准（不变）

1. 高通用性；一引擎一任务、一独立 worktree。
2. 游戏内查词：单击字形弹卡；悬浮 + Shift 弹卡。
3. 悬浮字有高亮块；点击后整个词在台词里保持高亮，卡片收起后回到悬浮高亮。
4. 点卡片外关闭卡片时台词不推进。
5. 制卡带视频（动图覆盖整句）+ 整句音频（按句从游戏资源直提，不是系统混音）。
6. 尽量不看 hook 代码；真正的 hook 缺口必须修，不能用降级冒充。
7. 窗口模式与全屏各验一次（BUG-2083 教训）。

## 本任务范围

- 样本 1：`TenShiSouZou_R18/tenshi_sz.exe`（KiriKiri Z，x86，plugin 含 textrender.dll / DrawDeviceD2D.dll / wuopus.dll / wuvorbis.dll）。库内已有条目。
- 样本 2：`ATRI -My Dear Moments-`（KiriKiri Z 1.2.0.3，x86，wuopus）—— BUG-2070 原报告样本，用于复验修复。
- 目标缺口：**BUG-2070** 语音恒降级 `system_loopback · engine_utterance_unavailable`。静态事实：`kirikiri_adapter.inc` 已 hook `wuopus.dll` 的 `opus_decoder_create / opus_decode / opus_decoder_destroy`（C.2c）与引擎内部 `TVPCreateStream`（C.2d，按 storagename 含 `voice` 或后缀 `.ogg/.opus` 过滤）——实现存在但运行时没产出 utterance，必须真机分型：opus hook 是否装上（reserved_luna 0x2/0x800）、opus_decode 是否触发（0x10/0x20）、资源流 hook 是否就绪/落盘（0x20000/0x80000）、storagename 是否命中过滤。

## 环境（本轮实测）

- 用户自己的 Fushi（`D:\APP\Hibiki\fushi.exe`，2.2.4-debug.13075）正在运行，**不动它**。
- 本轮用 worktree 构建 + 隔离运行时：`FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1`（跳过单实例互斥、窗口可见），APPDATA/LOCALAPPDATA/WebView2 目录隔离到 job tmp；数据根 `D:\APP\HIBIKI_gal_test`（`support/fushi.db` 由 sqlite backup API 从生产库拷快照 user_version=94，`documents` 为 junction 回 `D:\APP\HIBIKI_date\documents` 以复用词典）。
- helper 构建坑：bash 里同时 export 小写 `http_proxy/no_proxy` 与大写会让 MSBuild 起 CL.exe 抛 ArgumentException → cmake 报 `No CMAKE_CXX_COMPILER could be found`。只留大写即过。

## 身份台账（SOP §2）— tenshi_sz

| 类别 | 事实 |
|---|---|
| 样本身份 | `TenShiSouZou_R18/tenshi_sz.exe` x86，KiriKiri Z 1.2.0.3（`TVP(KIRIKIRI) Z core`），天使☆騒々 RE-BOOT! ver1.12 官方多语言版（菜单「文本语言(L)」可切主文本/字幕语言；文本语言**不持久化**，每次启动默认中文，须手切日本語）。plugin：textrender / msdfrender / DrawDeviceD2D / wuopus / wuvorbis / krkrsteam / PackinOne。exe 有 `.sig`（krkrsteam 签名），`voice.xp3` 条目名被哈希（`坋`）。 |
| 进程身份 | 库内卡片点击启动 → `fushi_voice_injector.exe`（x86，staged `voice_hook_runtime/4a19ca968ced8875/x86`）→ `tenshi_sz.exe`（两次会话 PID 94080 / 95228，窗口类 `TVPMainWindow`，无子窗，1942×1166 窗口模式） |
| 组件身份 | worktree 构建 Fushi（`fushi/build/windows/x64/runner/Release`，develop@22802b971d + 本分支）；helper x86 dist `voice_hook_x86.zip`（本分支 `tools/build_distribution.ps1` 产出，源码指纹随包）；探针 `build/x64/Release/fushi_voice_lookup_probe.exe` / `fushi_voice_ring_probe.exe`（IPC v21） |
| 生命周期 | 点卡片 → 3 s 内 injector+游戏起 → 4 s 内 `engine.text_hook_ready` + `audio.game_resource_late_ready`（资源 hook 晚到升格为主音源）→ 标题画面时 decdiag=0x071e0903（vorbis+opus 解码 hook 已装、内部 TVPCreateStream hook 就绪并已 dump、KrkrZ 版本确认、exe 未导出 exporter 走 V2Link 兜底）、lookup_diag `sensor_installed` geometry=1/1 |
| 首个未通过边界 | 无（text/resource/paired/lookup 全通）；用户验收项里的缺口是消费端与采集面（见下） |

### 阶段证据

| 阶段 | 证据 |
|---|---|
| process_found | `tenshi_sz.exe` PID 95228 承载 `TVPMainWindow`；injector 是父进程 |
| helper_ready | diag `sensor_installed`、`text_hooked=1 luna_active=1`；decdiag 见上 |
| ipc_ready | 探针读到 `Local\FushiVoiceHook_95228 version=21` |
| text_ready | 线程 `EmbedKrkrZ · 0xd22188`（Luna 精确整行；**日文与中文两份都出**，中文行紧跟日文行 ~0.1 s；ruby 句还多出一份读音替换变体）。`KiriKiriZ · 0xe1c450` 的全部 ctx 子线程是逐字 ×2/×3 重绘伪影（native 已丢，预览计数仍在）→ BUG-2112 |
| resource_ready | 角色台词 → `game_resource` `yuz_001_0004.ogg`…（voice.xp3，vorbis）；**误捕获**：SE `★炎９(Loop).ogg`、系统 SE、`bgm24.opus`、`voice.tjs` 等 → BUG-2115（本轮已修）。opus 解码 hook 在本样本只被 BGM 触发 |
| paired | JP 行 #104「またぁ？…」↔ `yuz_001_0004.ogg`；#139「体調に問題ないなら…」↔ `yuz_001_0010.ogg`；中文重复行走 loopback（预期） |
| 查词 | Shift 悬浮「多」→ 卡「多分」（hits+1，frames+1，卡贴台词上方 [561..1509,694..1342]）；单击「好」→ 卡「好き」、台词**不推进**；单击「な」→ 卡「なかった」 |
| 悬浮高亮 | 光标字格蓝色高亮块（TJS 层）✓；整词高亮 ✗ 只亮点击字 → BUG-2114（本轮已修，待复验） |
| 点外不推进 | 3 次有效实验（游戏前台且卡片可见）：LL 钩子吞掉（`GetAsyncKeyState(VK_LBUTTON)` 按下期间读 0）、卡关、`text_writes` 不变 ✓。前两次「推进」是测试环境伪失败：`FUSHI_TEST_HIDDEN` 隔离实例每 ~1.25 s 抢回前台（焦点修复闸门被测试模式豁免），`ShouldConsumeGameClientClick` 要求 `GetForegroundWindow()==game` 故放行；`EnableWindow(FALSE)` 禁用主窗后消失 |
| e2e_verified | ✗ 制卡「+」→ `ankiConnect:false` 静默失败（BUG-2113，本轮已修，待复验） |

## 本轮修改

- **BUG-2112**（Dart）伪影主导线程在选择器里像干净线程：`isArtifactDominated` 统一判据 + 副标题提示 + 记忆恢复/自动选跳过 + 选中告警；探针 `--dump-thread-previews`。
- **BUG-2113**（hook+Dart）KiriKiri `text_generation=hit_seq` → 文本道按整句反查 `TextSlot.seq`，未知发 0；host 未知时最近 8 行原文精确回查。
- **BUG-2114**（hook）直连路由整词高亮被 `g_lookup_card_shown` / `card.visible` 门吃掉 → 去门。
- **BUG-2115**（hook）语音资源过滤按归档/目录段含 voice/koe，裸 .ogg/.opus 不再当语音。

## 修正版构建真机复验（2026-09-04）

四条修复已构建随包（helper x86 sha `ba5eea43…` 已 install_into_bundle）并真机复验：
- BUG-2113 制卡：由月/主角行单击字形弹直连卡、点「+」→ 写出 Anki 卡（note 1788466468644「見た」等，MiscInfo=天使☆嚣嚣 RE-BOOT!），旧版恒 ankiConnect:false。
- BUG-2115 语音落盘名带扩展名 + VoiceStreamDumped 位置位 + 女主有声句 `game_resource`（详见 BUG-2115 复验段）。
- BUG-2114 整词高亮 / BUG-2112 伪影线程提示：代码 + 测试落地，视觉复验交用户（截图见 `.codex-test` 未留，属证据缺口）。

## 未做 / 堵塞

- **制卡卡内 SentenceAudio 时长 = 源资源**：唯一没采到的硬证据。测试模式隔离实例每 ~1.25s 抢回前台→卡片不发布，量不到干净卡（EnableWindow(FALSE) 也会被 mine 脚本的推进/点击重置）。真机（用户自己的 Fushi、前台稳定）应能直接复验。
- 全屏模式（Alt+Enter）一轮：未做。
- BUG-2070（ATRI wuopus）真机复现与根因：未做。
- 语音资源**字节哈希一致性**与纯人声分类证据未采（yaml 仍 implemented_unverified / partial 不变，本轮未改 yaml 状态）。
- EmbedKrkrZ 日中双份 + ruby 变体：消费端未做语言过滤（无可靠判据），只作观察记录。
- 队列其余游戏（恋爱成双/Fate RN/アマカノ3/Sakura/AngelBeats/manosaba/ISO 类/chronoclock/昨日魔女）：未开始。

## 恢复指引（给接手人）

- 分支 `worktree-gal-kirikiri-z-ceshi`（base develop@22802b971d），worktree `D:\APP\vs_claude_code\hibiki\.claude\worktrees\gal-kirikiri-z-ceshi`。
- 构建：helper `native/galgame_hook/tools/build_distribution.ps1`（**先 unset 小写 http_proxy** 否则 MSBuild 撞大小写→cmake 报 No CMAKE_CXX_COMPILER）；Fushi `flutter build windows --release`（缺 torrent 预编译 DLL 时从主 checkout `native/fushi_torrent/prebuilt/windows-x64/` 拷 4 个；缺 ffmpeg/ffprobe 从 `D:\APP\Hibiki\` 拷）；再 `cmake --install build/windows/x64 --config Release` 把 helper 打进包。四条脚本在 `C:\Users\wrds\.claude\jobs\3f9f84ac\tmp\`（build_dist.sh / build_win.sh / cmake_install.sh / ctest_both.sh）。
- 真机驱动：隔离实例启动脚本 `.../tmp/launch_fushi_iso.ps1`（数据根 `D:\APP\HIBIKI_gal_test`，隔离 APPDATA）；操作库 `.../tmp/drive/galdrive.ps1`（fclick/mclick/shot/list/prop/fwheel/setrect…）；`advance_to_voiced.ps1` / `mine_test.ps1` / `media_probe.py`。**测试实例会抢前台**：EnableWindow(FALSE) 禁用主窗后游戏稳前台（见 memory reference_test_hidden_fushi_steals_foreground_from_game）。
- 验证门：`native/galgame_hook` 下 `python tests/adapter_structure_test.py` / `kirikiri_lookup_source_guard_test.py` / `engine_support_manifest_test.py` + 双架构 `ctest`；`fushi/` 下改动文件定向 `flutter test`；合入 develop 前全量 `dart run tool/flutter_test_failures.dart --no-pub` + 目录枚举守卫整批。
