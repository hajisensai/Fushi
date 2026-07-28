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

- **[ ] ① 未修复** —— 方案需按上述四条重做；在真机量出「放开门控后单句产行数」与 `HIBIKI_LUNA_DIAG` 语言/hook_code 对应关系之前，不要动 `ShouldWrite`。
- **[ ] ② 未加自动化测试** —— 至少需要：`tests/fixtures/luna_thread_selection.tsv` 的 winner 行为用例改写、「文本环被逐字重绘 hook 挤满时候选不得丢失」的负向用例、跨引擎负向测试。
- **备注**：
  - 修复须改 native 并**重新构建双架构 helper + 重发 release**，用户机上的 `voice_hook/x86` 才会拿到；开工前须按根 `CLAUDE.md` 读 `docs/agent/galgame-hooking.md` 并走证据门。
  - 本条从 PR#516 撤出单列（原 PR 只做超分改动 + Steam 定位），理由即上述四条。
