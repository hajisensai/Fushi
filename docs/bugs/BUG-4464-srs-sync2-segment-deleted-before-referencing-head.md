## BUG-4464 · SRS 同步 v2：旧小段可能先于引用它的旧 head 被删（保留代数写在 Dart，内核看不到）
- **报告**：2026-11-11（代码审计：把「位置上哪些旧 head 可以删」收进内核时逐项对照 Dart 与内核两边的规则发现；没有现场报告）
- **真实性**：✅ 真 bug。根因（修复前，基底 `8890d01a33d`）：
  - `packages/fushi_engine/lib/srs/sync2/srs_sync2_round.dart:409-431`：写完 head 的一轮里先 `srsDeleteAndAck(head.map['delete'])` 删内核给的旧小段并回执，**之后**才列本机目录按 `g < gen - 2` 删旧 head；旧 head 的删除不回执，`location.delete` 抛错后这一轮失败，而 head 没变的一轮（同文件 `368-384`）只删内核清单、根本不碰旧 head——没删成的旧 head 要等下一次**写** head 才重试。
  - `native/fushi_fsrs/src/store/sync2/transport.rs:258-316`（`OBSOLETE_KEEP_GENS` / `pending_deletes`）：内核按「代号到 `since_gen + 2` 时引用旧小段的 head 已经全部被 Dart 删掉」交出旧小段，但交出清单的那一刻这些 head 还在位置上，之后删没删成内核无从知道；这条 Dart 规则在内核里只是一句注释，没有任何测试把两边钉在一起。
- **[x] ① 已修复** — 保留策略收进内核（分支 `pr/srs-sync2-head-retention-kernel`）：`transport.rs` `HEAD_KEEP_GENS` / `head_retire_below` 是唯一的一处，新命令 `obsolete`（`SrsCore::sync2_obsolete`）按 Dart 列到的本机目录给出该删的旧 head（登记进 `sync2_obsolete`，`last = 0` 的 head 行）与旧小段，同一份清单、同样 `obsolete_ack` 两段式；旧小段要等代号低于它 `since_gen` 的旧 head 都确认删掉才给（`pending_deletes`）。Dart（`srs_sync2_round.dart` `srsSweepObsolete`）只列目录、删、回执，head 没变的一轮同样收尾。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_retention.rs`（`a_segment_is_never_deleted_before_the_last_head_referencing_it`：每轮隔两天、旧 head 删除成批失败，交出一个段的那一刻位置上没有 head 引用它；去掉「等旧 head 确认」的条件即红。`segment_delay_is_derived_from_the_head_retention_rule` / `old_heads_are_listed_by_the_kernel_until_their_deletion_is_acked` 钉住与旧版本同一条数值规则、清单与回执）；`packages/fushi_engine/test/srs/sync2/srs_sync2_head_retention_test.dart`（脚本宿主：只删内核清单里的、失败不回执、下一轮重给、`again` 时全部删成才再问一次；真实内核：留下的 head 与改之前相同、旧 head 删失败后没变的一轮照样重删）。
- **备注**：影响面小、不丢数据：读者只取每台设备代号最大的 head（`srsSync2Pull`），被多留下的旧 head 不是最大代号；只有列目录最终一致（读者列到的还是旧目录）时才会按旧 head 去拉已删的段，那一轮跳过该设备、下一轮补齐（设计 §6.1）。修复后删除全部成功的一轮里被删的文件与时机同以前（旧小段仍在同一轮删，只是排在引用它的旧 head 确认删掉之后：内核回 `again`，Dart 同一轮再问一次）。行为差异只在出问题的路径上，都是晚删：① 旧 head 没删成时，代号晚于它的旧小段留着（以前照删），head 没变的轮次也重试旧 head（以前要等下一次写 head）；② 刚写的 head 还列不到时按位置上列得到的最新一份算。

### 根因

读者只认 head 列出的段（设计 §6.1 读取纪律），所以合并换下来的旧小段只有在位置上再没有 head 引用它之后才能删。这条前提
被拆在两边：

- 留几代旧 head 写在 Dart（`gen < 当前 - 2`），删了不回执；
- 内核回收旧小段时假设 Dart 已经按那条规则删干净了（注释原文：「它们在当前代号到 `since_gen + 2` 时全部被删」）。

两边实际对不上的地方：

1. **同一轮里的先后**：代号刚到 `since_gen + 2`、宽限期（24 小时）也已经过了的那一轮，内核在 `head` 的回复里交出旧小段，
   Dart 先删它们，再去列目录删代号 `< since_gen` 的旧 head——中间这一段，位置上的旧 head 引用着已经不在的段。
2. **旧 head 删失败**：`location.delete` 抛错后这一轮失败；之后 head 没变的轮次照样从内核拿旧小段清单并删掉，却不重试
   旧 head，要等下一次写 head（本机有新操作，或 6 小时心跳）。
3. 内核没法防：它看不到位置上还有哪些 head，也收不到旧 head 删没删成的回执。

### 修复

内核持有整条策略，Dart 只执行：

- `HEAD_KEEP_GENS = 2` 与 `head_retire_below` 是唯一的保留规则；待删表里两种行的 `since_gen` 同义（引用这个文件的本机
  head 代号都 `< since_gen`；旧 head 行是它自己的代号 + 1），「该删」对两种行是同一个条件
  `since_gen <= head_retire_below(最新代号)`——旧小段多留的代数是从 head 的保留规则推出来的，不另立常量。
- 一轮收尾（head 已经在位置上之后）Dart 把本机目录的列表交给 `obsolete`；内核把列到的、该删的旧 head 登记成 head 行，
  与旧小段、旧转发件放进同一份清单；删成功的 `obsolete_ack` 才移除，没确认的每一轮照样再给。
- 旧小段只在「没有代号 `< since_gen` 的旧 head 还等着确认」时才给。被这份清单里的旧 head 拦住的旧小段，内核在回复里
  用 `again` 说明：Dart 把清单全部删成、回执之后同一轮再问一次就拿到——正常情况下旧小段与以前在同一轮删掉。
- 以列得到的最新本机 head 为准（不超过本机记的这个位置写到的代号），任何时候都不会把位置上最新的 head 删掉。

与旧版本混用同一个位置：每台设备只清自己的目录；旧版本 Dart 的 `g < gen - 2` 与内核的规则是同一条数值规则（测试里
冻结了旧公式逐项比对），所以新旧版本留下的 head 集合相同，新内核也不依赖别的设备按哪个版本删。
