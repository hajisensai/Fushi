## BUG-2088 · HUNEX 延迟选中文本读的空窗口覆盖掉第一次读的真实失败码，且候选计数被丢弃无法分型
- **报告**：2026-09-03（BUG-2086 修好文本链后，首次在真机 WoH 上读出 HUNEX 投影诊断，发现读数本身不可信）
- **真实性**：✅ 真 bug（诊断可信度类，非症状掩盖）。真机 WoH（pid 10060）上 `lookup_worker={state:4,selected_failure:6}` **稳定恒为 6**（`SelectedTextRejected` + `kNoExactRawLine`），从不出现别的码。查代码发现两个独立缺陷叠加，导致这个读数既可能是噪声、又无法分型：
  1. **延迟读的空窗口整体覆盖第一次读的结果。** `native/galgame_hook/hook/adapters/hunex_gge_adapter.inc` 的 `MatchHunexGgeSnapshotToSelectedText` 先用 `(last_seq, seal_seq]` 读一次，未命中则再用 `(seal_seq, now]` 读一次，且第二次是 `selected = read_selected_text(...)` **整体赋值**、随后 `outcome.failure = selected.failure`。而 `now` 由**任意车道**的任意文本事件推进（含 `kTextEventThreadDiscovered`），选定车道在那一小段里通常一条新行都没有 → 第二次读必然产出「窗口内空无一物」的 `kNoExactRawLine`，把第一次读真正有意义的失败码（例如 `kInvalidSelectedEvent` 指向 `thread_address` 不等）整体盖掉。这解释了「永远是 6、从来不是 8」的稳定性。
  2. **能分型的三个计数在 adapter 里被丢弃。** `HunexGgeSelectedTextResult` 有 `stable_selected_events` / `invalid_selected_events` / `latest_strict_selected_line_seq`，但 `HunexGgeSnapshotSelection` 只留 `failure` 与 `matched_seq`，导出面 `SetHunexGgeLookupWorkerTraceState` 也只带两个值。于是同一个 `kNoExactRawLine` 无法区分**三种处置完全相反**的根因：① 选定车道在窗口内一条候选都没有（查车道选择 / fence）；② 有候选但字节不等（查文本同源性）；③ 候选形状不合格（查 `thread_address` / hook_name）。真机上只剩两 bit 信息，分型无从谈起。
- **为什么这不是「症状掩盖」而是真根因**：投影链有 24 个显式失败点，选中文本绑定又有 12 个码；在读数不可信的前提下改任何一环都是盲猜。本条修的是**量具**，不放宽任何 fail-closed 不变式、不改任何匹配语义。
- **[x] ① 已修复** — 三处，全部只动信息流不动判据：
  - **保留第一次读**：新增 `first_read` 快照；只有当延迟读**真的看到了候选**（`stable_selected_events` 或 `invalid_selected_events` 非零）时才采用它的失败码，否则保留第一次读的失败码。空窗口再也盖不掉真相。
  - **候选计数带出来**：`HunexGgeSnapshotSelection` 增 `selected_stable_events` / `selected_invalid_events`，在候选循环里与 `newest_failure` 同源保留，经 `SetHunexGgeLookupWorkerTraceState` 的新增两参发布。
  - **借空槽进 trace，不改导出 ABI**：body-submit 事件的 `draw_arg12_bits` 恒为 0（真机 trace 可证），低 32 位放稳定事件数、高 32 位放非法事件数；`tools/ring_probe.cpp` 打印为 `lookup_worker={state,selected_failure,stable_events,invalid_events}`。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/hunex_gge_selected_text_test.cpp` 新增 `TestNoExactRawLineIsClassifiableByCandidateCounts`，三例**同为 failure=6、计数不同**，正是本条要钉死的分型：
  - 字节不等 → `stable_selected_events == 1 && invalid_selected_events == 0`；
  - fence 空窗口（用另一条车道的事件把全局 `text_write_count` 推上去，保证上界仍可见，否则报的是 `kRequestShape` 而非 6）→ 两个计数全 0；
  - **真机形态**：lane 写带 ruby 的 `「あれ、鍵<rし>閉</r>まったまま？`，request 给去标记的 `「あれ、鍵閉まったまま？` → `failure==6 && stable_selected_events==1`，证明「带标记 vs 去标记」属于字节不等而非空车道。
  x64/x86 双架构 `ctest` 各 56/56 通过；五个 Python 守卫与两个生成器 `--check` 全绿。
- **真机测得的相邻事实（供下一轮定位，尚未下结论）**：同一会话用 `--dump-text-events` 读到选定车道（`thread_id=2449798931068139632`，`hook_name=typemoon`，`hook_code=ENHQ-4C@130020:WoH.exe`）确实在出行，且**带 ruby 标记与行首全角空格**：`「あれ、鍵<rし>閉</r>まったまま？`（20 units）、`　……<rありす>有珠</r>、まだ帰ってきてないんだ」`、`　青子はやれやれと肩をすくめて、古びた鉄柵に手をかける。`。而同一时段 trace 里 renderer 只封存了**一条** 12 units 的行（`line_hash=b51e1bf916917b79`），经 FNV-1a64 比对**既不是**去标记版 `「あれ、鍵閉まったまま？`（`5c85e32b58573bc8`）**也不是**带标记版（`906dcd51112ae090`），也不是任何一条工具栏提示串——即那次封存的根本不是正文行。因此「两侧是否同源」这一问必须等本条修复后重跑真机、读 `stable_events` 才能回答，**本轮不预设结论**。
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不因本条提升，仍 `implemented_unverified`。下一轮真机动作：装本轮 helper → 打开 lookup 并确认风险 → 推进几句剧情 → `fushi_voice_ring_probe.exe <pid> --dump-hunex-gge-trace`，按 `stable_events`/`invalid_events` 三向分型后再决定动哪一环。**在拿到分型之前不得放宽 `SameRawLine` 的比较语义**——去标记/子串匹配都是掩盖症状。
