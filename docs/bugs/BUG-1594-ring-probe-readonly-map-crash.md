## BUG-1594 · ring_probe 只读映射下枚举文本槽必崩（Interlocked 写只读页）
- **报告**：2026-08-13（排查 [BUG-1593](BUG-1593-gal-utterance-head-clipped.md) 时撞到）
- **真实性**：✅ 真 bug。根因 `native/galgame_hook/tools/ring_probe.cpp:745`（原 `mapping_access = select_text_thread ? READ|WRITE : FILE_MAP_READ`）。
- **[x] ① 已修复** — `native/galgame_hook/tools/ring_probe.cpp`：映射一律 `FILE_MAP_READ | FILE_MAP_WRITE`（host 侧 `voice_hook_reader.cpp:644` 一直是这么开的，只有这个诊断工具漏了）。
- **[x] ② 已加自动化测试** — 无法做成自动化断言：崩溃只在「真实共享内存 + 已有文本道」这两个前提同时成立时发生，构造它等于把 injector 与 hook 全跑起来，不是可落地的单测层。改为在代码里把「为什么只读不够」写死成注释，并在 [BUG-1593](BUG-1593-gal-utterance-head-clipped.md) 的真机流程里覆盖。
- **备注**：见下文。

### 根因链

1. `ring_probe` 自称只读，映射按 `FILE_MAP_READ` 开（文件头注释也强调「**只读**，不注入、不写共享内存」）。
2. 但文本槽枚举走契约头的 `CollectTextSlotsBySeq`（`include/voice_hook_ipc.h:601`），它按跨进程发布纪律用 `AtomicLoadPreview64(&slot->lane_seq)` 读道内序号。
3. `AtomicLoadPreview64` 的实现是 `InterlockedCompareExchange64(p, 0, 0)`（`include/thread_preview_ipc.h:61`）——即便比较值与期望值相同，它仍是一条**带 lock 前缀的读改写**指令，对只读页发起写访问。
4. 于是只要目标进程已经写过任何一条文本行（`text_lane_count > 0`），`ring_probe <pid>` / `--dump-text` / `--dump-text-events` 一律 **0xC0000005** 直接挂掉，而且是在打印完 header 之后立刻挂，看起来像「共享内存坏了」。

### 复现与验证

排查 BUG-1593 时自己写的只读探针踩到同一条路径：header 行正常打印，随后进程以 `-1073741819`（0xC0000005）退出；把映射从 `FILE_MAP_READ` 换成 `FILE_MAP_READ | FILE_MAP_WRITE` 后同一份代码立刻正常枚举出 15 条文本槽。失败与修复走的是同一个共享头、同一个调用点。

### 为什么不改 `AtomicLoadPreview64`

把 64 位读换成 x64 上的普通对齐读确实能从更根上消除「读操作写页面」，但那个头文件同时被注入进游戏进程的 hook DLL 使用（x86 上 64 位裸读会撕裂），改它就是在音频回调的热路径上动内存序语义。收益是让一个诊断工具能开只读映射，风险是动跨进程发布纪律——不划算。放宽这个工具的映射权限不改变「它一个字节都不写」这个事实。
