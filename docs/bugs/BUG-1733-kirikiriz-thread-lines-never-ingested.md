## BUG-1733 · 选中 KiriKiriZ 文本线程后实时台词恒 0，伪影门把逐字重绘串全丢了
- **报告**：2026-08-19（用户：真机验证游戏内查词制卡时发现）
- **真实性**：✅ 真 bug，已在真机稳定复现。根因 `native/galgame_hook/injector/injector_main.cpp:830` + `native/galgame_hook/include/luna_text_selector.h:71`
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：见下

### 复现（真机，2026-08-19）

游戏《天使☆嚣嚣 RE-BOOT!》（`tenshi_sz.exe`，KiriKiri Z，中文版），由 Fushi 2.1.1-debug.11887
「启动游戏」拉起（pid 94928，injector 同时起）。

1. 工作台选文本线程 `KiriKiriZ · 0x54c450 · #0a47`。
2. 推进剧情。**下拉框自己的计数在涨**：`#0a47 · 1` → `· 4` → `· 5`。
3. 但左侧「实时台词」恒为 **0**，中间一直是「尚未收到台词」，状态卡在「正在监听 / 等待信号」。
4. 换选 `EmbedKrkrZ · 0x452188` → **实时台词立刻变成 8 条**，逐句正确列出（`#16`…`#20`）。

第 4 步是判别实验：摄取链本身是通的，**只有 `KiriKiriZ` 这一类线程的台词进不来**。

同一会话里注入侧探针显示 `text_writes=18`、`lookup_diag=0x0000106F`
（`sensor_installed,geometry_observed,hit_submitted,buffer_route_ready,frame_presented,expression_ready`），
即**游戏内查词本身完全正常**，问题只在台词行有没有进文本环。

### 根因

两个计数读的是**两个不同的区**，中间只隔着一道门：

| 显示 | 数据源 | 代码 |
|---|---|---|
| 下拉框 `· 5` | 线程**预览区** `observedLineCount` | `fushi/lib/src/sync/texthooker_service.dart:250`；native 侧无条件 `slot->line_count++` 于 `injector_main.cpp:799` |
| 实时台词列表 | 文本环**分道** | `texthooker_service.dart:413` ← `appendLine` ← `gal_hook_session_controller.dart:3716` ← `voice_hook_reader.cpp:941 PollText` |

两者用的是**同一个** `uint64 thread_id`（`injector_main.cpp:899` 一次算出，`:903` 写预览、`:917` 写文本道），
所以**不是身份对不上**——下拉框那个 `· 5` 能显示出来，本身就证明预览 id == 下拉行 id == 已下发的
`selected_text_thread_id`。

真正的门在 `injector_main.cpp:830`：

```
if (is_artifact) return false;   // LunaShouldWriteLine
```

而伪影判据 `include/luna_text_selector.h:77-103` 认「前后半相等 / 等长游程≥3 / 相邻重复字占比≥30%」为伪影。
**消重折叠 `LunaNormalizedTextLengthForHook` 只对 `EmbedKrkrZ` 生效**：

```
if (std::strcmp(hook_name, "EmbedKrkrZ") != 0) return len;   // luna_text_selector.h:71
```

KiriKiri 的逐字重绘引擎会把一句喂成「漆漆黑黑的的黑黑暗暗之之中中。。」（工作台线程选择器里
`#524d` 那条的预览就是这个原样），`hook_name == "KiriKiriZ"` 时一个字都不折叠，整串原样进伪影判定，
必被判伪影 → 只进预览、不进文本环。这正好解释了「`EmbedKrkrZ` 能进、`KiriKiriZ` 进不来」。

`texthooker_service.dart:53-56` 的注释里本来就写着 KiriKiriZ / 内部 TextRender 是逐字重绘引擎。

### 影响

- 选中 `KiriKiriZ` 线程等于选了一条**结构上永远不会产出台词**的死线程。
- 状态文案「等待信号」与「实时台词 0」是**同一个空列表的两个投影**（`gal_hook_session_controller.dart:3732`
  只在 `appendLine` 成功后才置 `receivedTextLine=true`），不是两条独立证据。
- 连锁：游戏内制卡因此拿不到 line id 而静默失败（见 BUG-1734）。
- 选择器里这条死线程和健康线程长得一模一样（见 BUG-1735）。

### 待确认

LunaHook 二进制是 vendored 的，仓库内没有 `KiriKiriZ` hook 的源码，**"它输出重复串"这一点尚未对本游戏实测**。
证伪/证实方法：游戏运行时跑
`fushi_voice_ring_probe.exe <game_pid> --dump-text-events`，找 `thread_id` 十六进制末 4 位 = `0a47` 的行——
只有 `event_kind=1`（线程发现）而无 `event_kind=0`（台词行）即假设成立；也可用 `FUSHI_LUNA_DIAG=1`
拉起 injector，它会把**过滤前**每一行连 `raw_len`/`normalized_len` 打到 stderr。
（**别**用 `ring_probe --select-text-thread`，它会覆写 `selected_text_thread_id` 改掉现场。）
