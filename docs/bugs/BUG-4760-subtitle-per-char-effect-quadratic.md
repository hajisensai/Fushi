## BUG-4760 · 逐字拆开歌词的特效标记是两两比较，单字事件多又长时间同屏时解析 ASS 退化成 O(N²)
- **报告**：2026-11-17（提交安全审查，针对 #3545 / 拍板台 H7r4mf_z2n 的 `mark_per_char_split_effects`）
- **真实性**：✅ 真 bug。`native/fushi_compute/src/parse/subtitle/formats.rs:653`（修前）对每条「单字 + `\pos`」候选向后扫所有起点早于它终点的候选；逐字特效密集的 OP / ED（或故意构造的字幕：几万条单字事件、终点都很晚）下内层循环不会提前 break，6 万条就是 18 亿次比较。字幕文件是外部输入（下载的字幕、内嵌轨、在线源），解析在打开视频时跑。
- **[x] ① 已修复** — 同一函数改成按 start 升序的一次扫描：只维护「此刻还在屏」的候选，`live` 按 (Layer, 行 y) 计数、`pending` 记其中还没标记的、`by_end` 小顶堆按终点让候选退出；每条候选进出各一次，整体 O(N log N)。判据不变（单字、带 `\pos`、同 Layer、y 在 ±`PER_CHAR_SAME_ROW_EPS` 内、同时在屏）；非有限的 y 不参与（修前与任何 y 比较也恒为假）。
- **[x] ② 已加自动化测试** — `formats.rs` 的 `per_char_split_effects_match_pairwise_definition_and_scale`：600 条确定性伪随机事件（两个 Layer、12 个行格点、长短不一的在屏区间、夹杂双字事件）与测试内的两两比较定义逐条相等；6 万条全部同屏的单字事件 + 一条孤立行在 5 秒内结束且标记正确（修前的实现在这里要跑 18 亿次比较）。原 `ass_effect_flag` 照旧通过。
- **备注**：`cargo test --profile quick --lib parse::subtitle::formats` 5 个通过。Dart 列表侧的 `mergePerCharacterCueGroups` 未动。
