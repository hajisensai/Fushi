## BUG-1193 · primed 后非赢家 hook 线程被 native 丢弃，无法像 LunaTranslator 那样切换
- **报告**：2026-07-28（用户：「luna 有正确分开，我们没有，两个语言混一块了」，附我方线程下拉截图与 LunaHook「选择文本」窗口截图。）
- **真实性**：✅ 症状真，⚠️ **根因叙事本轮已被推翻一半，方案不可直接实施**。原始观察成立：`native/galgame_hook/include/luna_text_selector.h:227` 的 `return !primed_ || hook_code == selected_hook_;` —— `total_clean >= 3` 后 `primed_` 置真，此后只有自动选中的那个 `hook_code` 的行会被写入文本环，其余 hook 的行在采集端就被丢弃。用户截图里 `EmbedKrkrZ · 0xf62188` 有 4 行、其余 `KiriKiriZ` 各只有 1~2 行，正是 primed 之前漏进来的残留：那些线程在下拉里看得见但已经死了。
- **不是什么**：不是线程分组维度不够。`thread_id = FNV1a(processId, addr, ctx, ctx2, hookcode, hookname)`（`luna_text_selector.h:164`）已含 ctx/ctx2；Dart 侧 `GalHookedLine.textThreadKey` 只用 `threadId`，但该 id 本身已含全部维度。

### 🔴 本轮审查推翻的四条（PR#516 评审，2026-07-28）

原稿把 winner 门控写成「采集端替消费端做的不可逆丢弃」并暗示是疏漏。查 git 历史后不成立，且原方案有死结。下一个接手的人**先读完这四条再动手**。

1. **winner 门控是有意设计，不是疏漏。** 它是两轮真机取证之后加上去的：
   - `0d8fb78e1`（2026-07-19，双写者污染根修）—— 提交原文写明「线程选择只作次级去重」，门控是为了挡住同一句被多个 hook 各写一份；
   - `80be21c36`（pristine 优先）—— 真机 `HIBIKI_LUNA_DIAG` 证据显示文本环 13 行**全部**来自菜单 hook，正是靠这道门才没把菜单文本当台词。

   原稿「winner 门控的原意（防碎片 hook 刷屏）已由 artifact 判据单独承担」**因果倒置**：artifact 闸是在 winner 门控已存在、且被证明不够用之后补的第二道闸。artifact 是**单行字符级**判据，结构上看不见「N 个 hook 各写同一句」的跨 hook 重复，也挡不住逐字重绘 hook 产生的一串合法递增前缀。它替代不了 winner 门控。

2. **🔴 放开门控会以另一条路径复现 BUG-1159 修好的症状（本轮最重要的一条）。** 代码层面不会直接退回 PR#470 —— PR#470 改的是 `manually_selected` 分支，winner 门控在与之互斥的另一条分支上。但文本环只有 **256 槽**：放开全部 hook 后，逐字重绘型 hook 一句话能产出几十条各自「干净」的前缀行，把真正的候选挤出环 → 配对时取不到 → `kExpired` → 降级 `system_loopback`。**那正是 BUG-1159 / PR#470 的失败链**。原稿只把它写成「环轮转变快、旧行更早被挤掉」的展示层问题，严重低估。同一个坑换条路走回去，比直接 revert 更难发现——这条必须在改之前用真机 DIAG 量出「放开后单句产行数」再决定。

3. **🔴 原方案有死结。** 原方案 step 1 说「`manually_selected` 仍按选定线程 / face 过滤（现有行为不动）」，step 2 说「Dart 侧新增首次自动选线程」。但 Dart 的 `selectTextThread` 会把 id **回写** native 的 `selected_text_thread_id`，一旦非 0 就进 `manually_selected` 分支 —— 于是 step 2 自己把 step 1 保留的过滤重新激活了，**等于什么都没改，原症状原样复现**。若改成纯本地不回写，`ResolveFollowingSelectedText` 又永远配不上标，语音配对退回 200ms 兜底窗 —— 还是 BUG-1159 的失败链。两条路都通向同一个坑，方案需要重做。

4. **🔴 与 BUG-1129 重复，且方案更弱。** BUG-1129（2026-07-26）已记录同一根因，并给了一份更完整的方案：给事件加 `publish_all` 标志、把 artifact 从「硬丢弃」改成「置 `event_flags` 位」让消费端自己决定，且已标 `implemented_unverified`。本条既没交叉引用它，方案还退了一步（保留 artifact 的硬丢弃）。**接手前先确认这条是否应当直接并入 BUG-1129。**

### 其余待补证据

- **「日文/中文来自不同 hook」是推断，未验证。** 门控的 key 是 **hook_code**，不是 thread_id。若汉化补丁的两种语言来自**同一 hook_code 的不同 ctx2**（split H 码，汉化版很常见），winner 门控根本不是「两个语言混一块」的原因，那就是另一个 bug。缺 `HIBIKI_LUNA_DIAG` 佐证，取证前不要按此叙事动手。
- **漏了 `preferred_hook_codes` 快路**：命中 profile 的游戏整段不进选择器，原方案对那类游戏一行都不生效。
- **测试影响面指错**：原稿说要改 `luna_text_replay_test.cpp:170-215`，那段是 BUG-1159 的 face 用例、走不到 winner 门控；真正依赖 winner 行为的是 `tests/fixtures/luna_thread_selection.tsv`。
- **🔴 一引擎一任务**：`LunaTextSelector` 是**引擎无关**的公共层，删 winner 门控是**全引擎行为变更**，不是「修一个 KiriKiriZ 症状」。按根 `CLAUDE.md` 与 `docs/agent/galgame-hooking.md`，动它必须有跨引擎负向测试，且每个受影响引擎的支持状态都要重新按证据门评估。

### 🔵 读 LunaTranslator 源码后的定案（2026-07-29）

上面「其余待补证据」里那条『日文/中文来自不同 hook 是推断，未验证』**已经有确定答案**，来自上游源码
（`HIllya51/LunaTranslator@v10.16.1.2`，与本仓 vendored DLL 同版本，`KiriKiri.cpp` 字节数一致）：

1. **`EmbedKrkrZ` 带 `NO_CONTEXT`**（`engine32/KiriKiri.cpp:1544`），而 `texthook.cc:364` 有
   `if (hp.type & (NO_CONTEXT | FIXING_SPLIT)) lpRetn = 0;` —— ctx 被强制清零后才组装
   `ThreadParam tp{pid, address, lpRetn, lpSplit}`。**该 hook 的全部输出永远落在同一个 tp 上**，
   中文与日文的 ThreadParam 逐字节相同。→ 猜测 (b)「同 hook 不同 ctx2」**排除**；
   → 也意味着**在这条线程内部分不开中日**，任何"分线程"的做法都治不了它。
2. **译文会经同一 hook 回流并被上报**：`texthook.cc:393` 的顺序是 `TextOutput(...)` 在前、内嵌替换
   （`EMBED_AFTER_NEW` 改 `*plpdatain` 指针）在后；被替换的串会被游戏再走一遍流程再次撞上该 hook，
   `checktranslatedok`（`embed_util.cc:267`）靠 `translatecache` 认出"这是我自己产的译文"后**只清
   `EMBED_ABLE` 位、不 `__leave`**，因此译文照样被上报。原文/译文同线程交替是 Luna 架构下的已知现象。
3. **Luna 采集层零淘汰**：`LunaHost/host.cpp:222-243` 每个 `ThreadParam` 一个 `TextThread`，全路径无
   winner 分支；去重复（`textthread.cpp:5-12` `RemoveRepetition`）是**线程内部**的。Luna 能"正确分开"
   靠的是**不丢弃**——用户切到 `TextRender` 那条纯日文线程即可，不是靠什么分离算法。

**结论**：原始诉求（不丢非赢家线程）方向正确，但必须解掉 256 槽挤压与死结，且不能指望它能分开
EmbedKrkrZ 内部的中日文。

- **[x] ① 已修复** —— IPC v12（`native/galgame_hook/include/voice_hook_ipc.h`）新增**线程预览区**，并
  取消 injector 自动选线程：
  - **数据结构层解掉 256 槽挤压**：旧结构里文本环是唯一文本出口，同时伺候两个诉求相反的消费者——
    语音配对要高信噪的单条线程，选择器要每条线程都有样本。v12 把二者拆开：文本环语义不变（仍只装
    当前生效线程，配对/loopback 路径逐字节不受影响），新增的 `ThreadPreviewSlot` **按 thread_id 认领
    固定槽**、每线程一条。按线程分槽而非全局取模，逐字重绘型 hook 只能覆盖自己的槽，**挤压跨线程
    发生在结构上不可能**——不是加护栏，是让那种情况不存在。
  - **死结随自动选线程一起消失**：原方案的死结来自「Dart 自动选线程 → 回写 `selected_text_thread_id`
    → 重新激活过滤」。v12 不再有任何自动选择（`luna_text_selector.h` 的 winner 统计整体删除，
    `ShouldWrite` → `AcceptsLine`），选择只来自用户显式操作或 profile `prefer=`，回环不存在。
  - **`preferred_hook_codes` 快路已覆盖**：预览写入点在所有门控之前（`injector_main.cpp` 的
    `WriteThreadPreview`，与 `NoteFace` 同一位置），profile 命中的游戏同样有预览。
  - **跨会话记忆不被锁死**：`_maybeRestoreTextThread` 的消歧判据从已发布行数改为
    `TexthookerTextThread.observedLineCount`（预览槽的 `line_count`，含被过滤/门控丢弃的行）。取消
    自动选线程后已发布行数在用户选定前恒为 0，不换判据会让记忆永远无法恢复、每局都要重选。
  - 消费端：`windows/runner` 新增 `PollThreadPreviews` + `pollThreadPreviews` MethodChannel；Dart 侧
    `TexthookerService.applyTextThreadPreviews`，线程下拉的行数/预览改读观测值，空选项文案改为
    `game_text_thread_unset`（不选 = 不发布，旧文案「全部线程」会误导）。
- **[x] ② 已加自动化测试** ——
  - `native/galgame_hook/tests/luna_text_replay_test.cpp`：新增「反复喂 16 行干净行也不得自动放行」
    的守卫（防自动选线程以任何形式回归）+ face 登记必须在未选择阶段就发生；原 face/跨引擎/split H 码
    负向用例改用 `AcceptsLine`。
  - `native/galgame_hook/tests/fixtures/luna_thread_selection.tsv`：按 v12 契约重写（`hook_code` 列
    随判定一并移除），`manual_thread==0` 全部期望不发布。
  - `hibiki/test/sync/texthooker_service_test.dart`：新增 `v12 线程预览区` 6 例（未发布线程也有内容/
    发现事件不抹预览/脏线程排序/替换非合并/无变化不通知/clear 清预览）。
  - `hibiki/test/tools/voice_hook_ipc_contract_test.dart`：版本锁 11→12，新增预览区常量与结构体的
    两侧同步守卫。
- **备注**：
  - 修复须改 native 并**重新构建双架构 helper + 重发 release**，用户机上的 `voice_hook/x86` 才会拿到；开工前须按根 `CLAUDE.md` 读 `docs/agent/galgame-hooking.md` 并走证据门。
  - 本条从 PR#516 撤出单列（原 PR 只做超分改动 + Steam 定位），理由即上述四条。
