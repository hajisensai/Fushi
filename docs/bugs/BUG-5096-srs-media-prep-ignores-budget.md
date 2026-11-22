## BUG-5096 · SRS 媒体准备阶段不守发段前预算，复习记录段被挡
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-011，来源 PR #3989）
- **真实性**：✅ 真 bug。发段前那一步（`srsSyncMedia(uploadOnly: true)`，预算 `kSrsMediaBeforeUploadBudget` = 15 秒）的
  `deferRemaining` 只在 `_reconcile` 的上传池里每组开始前问（`packages/fushi_engine/lib/srs/srs_media_sync.dart` 修前
  第 600 行 `srsRunPooled` 回调）；在它之前的准备阶段完全不看预算：
  - 修前第 352 行：一次 `media_hash` 把整个媒体库的名字交给内核，首次对账要把每个文件读一遍算 sha256；
  - 修前第 376–390 行：本机还没列举过的位置（新设备 / 新位置 / 不记日志的文件夹位置每轮）列 `media/` 下最多 256 个
    前缀目录，慢云盘上每个一次往返。
  两段都在 `srsSync2Round` 的 `beforeUpload`（`srs_sync2_round.dart` 第 334 行）里、复习记录段发出之前跑完，大库 /
  慢云盘上段能被挡几分钟（BUG-5061 只给传输阶段加了预算）。
  复现（虚拟时钟，媒体目录每列一次记 1 秒，200 个前缀目录）：修前第一个段在 203000 ms 才写上位置，修后 ≤ 15000 ms。
- **[x] ① 已修复** — 准备阶段也守 `deferRemaining`：
  - 本机哈希按 `kSrsMediaPrepareBatch`（64）个名字一批，每批之前问一次；只把哈希过的名字交给 `media_scan`（没哈希的
    交给 scan 会被当成「本机没有」去下载），没哈希的记进 `deferred`（> 0 时不清理、调度器不记已对账）。scan 把哈希
    结果写进 `media_local`，下一轮这些只 stat，准备阶段逐轮推进。
  - `uploadOnly` 时列位置目录每个前缀目录之前问一次；列到一半停下时已列到的「在」照样写回日志，`listed` 置回
    false（不写「已列举」，其余按不知道逐个查）。完整对账不在列举中途停，否则慢位置每轮列一半、永远记不上「已列举」。
  实测（1.2 GB / 300 个未哈希本机文件，本地文件夹位置，预算 1 秒，热页缓存 SSD）：发段前那一步修前 1740 ms（= 整库哈希
  耗时，随库大小线性增长），修后 1171 ms（预算 + 至多一批在途）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_media_sync_test.dart`：
  「HBK-AUDIT-011：慢清单 + 大媒体库，发段前那一步列目录也守预算，复习记录段按时发出」（真 `srsSync2Round` + 慢清单
  位置，量第一个段写上去的虚拟时刻；完整对账仍把列举做完并记「已列举」）、
  「HBK-AUDIT-011：本机哈希分批，每批之前问 deferRemaining；没哈希的名字记 deferred、不当成本机没有」。
  变异实测：撤掉两处 `stop()` 检查后两条都红（203000 > 16000；进度总数 197 ≠ 64）。
- **备注**：`srsSync2Round` 第 2c 步收别的设备的媒体清单（`srsSync4MediaManifestsIn`）同样在发段之前、不受这个预算
  约束；它只拉水位之后的新清单（小文件、6 并发），本条没有改动它的位置，未实测首轮大量清单的耗时。真机 / 真云盘
  未复测。
