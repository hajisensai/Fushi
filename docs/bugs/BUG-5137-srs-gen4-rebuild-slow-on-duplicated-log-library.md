## BUG-5137 · gen4 迁移第 7/10 步重建在 683 万条操作的库上要 1537 秒
- **报告**：2026-11-22（从 BUG-5063 拆出；来源：应用内反馈 9G1OHF2dQe 的 `srs4-migration-report.json`，i5-4460，srs.db 4.7 GB）
- **真实性**：✅ 真问题（性能，结果正确）。界面上第 7/10 步「Rebuilding the review index」卡了 30 分钟以上。报告数字：
  - 第一个资料库：`applied` 6837637 条，`rebuildS` 1537.5，约 225 µs/条；`importS` 503.5，`compareS` 265.8，整次 `elapsedS` 2573。
  - 同一台机器上的第二个资料库：332877 条，`rebuildS` 38.8，约 117 µs/条。
  - 本机库（509041 条操作）`rebuildS` 是 25.9。
  - 每条操作的耗时随库大小翻倍，说明不是纯线性。第一个资料库的 `settled.logs` 是 683385（`derive.rs` `rebuild_all` 里 `multi_ids("log_ix")`：几乎每个日志 ID 都有不止一份操作），`voids` 1855709，`aliases` 770155。另两个库的 `logs` 都是 0。这一形态是资料库并入留下的副本，本机复现不了。
  - 推测（未验证）：一是多份日志的 `pick_log` 逐 ID 点查 + 逐行 UPDATE；二是库超出页缓存后的随机读（迁移连接 `cache_size` 只有 16 MiB）。
- **本机分段实测（2026-11-22，本机库 50.9 万条操作，quick profile，`rebuild_all` 各段临时打点，没提交）**：总共 42 秒，其中缓存物化 `materialize_caches` 占 29 秒，扫描 5.2 秒，别名 1.3 秒，`weigh_rest` 1.8 秒，判定 2.1 秒，摘要 1.7 秒。缓存物化里，笔记行 `note_row` 占 10.4 秒，几乎全在 `expected_cards` 的模板判空：`card_front_is_empty` 对每条笔记的每个模板重新换名、分词、严格解析一遍同一份模板正面。另有笔记 `class_lines` 7.5 秒，卡的 `card_logs` 2.9 秒、`live_lines` 1.7 秒。页缓存 16 MiB 与 256 MiB 的 A/B 在本机没有差别（新库 235 MB，整份都在系统文件缓存里），IO 假设在本机验证不了。
- **[ ] ① 部分修复** — 模板判空：正面改成按笔记类型解析一次（`card_cache::CardFront`，`caches.rs` `TypeInfo.templates` 存解析结果），每条笔记只求值。机器满载下同一轮里 `note_row` 从约 27 秒（按负载折算）降到 1.4 秒，干跑 verdict 仍是 `pass`、parity 无差异。还没做的：笔记 `class_lines`；以及用户那份库特有的部分，即 IO 与每个日志 ID 都有多份操作，仍需按下面的合成库复现。 先要复现：用合成库造出「每个日志 ID 都有两份操作、500 万条以上」的形态，跑 `gen4_dryrun` 按 `rebuild_all` 的阶段打点（扫描 `touch` / 闭包 / 别名 `rebuild_aliases` / `multi_regs` 判定 / `pick_log` / 摘要 / 缓存物化），定位到真热点再改结构。不要盲调 PRAGMA。
- **对拍阶段分段（同一天，本机库，机器有负载，合计约 42 秒，临时打点没提交）**：`edits` 14.4 秒（`live_edit_ids` 对每个活着的寄存器写入调 `entry_by_key` 整条解码，只为拿实体、键和旧戳；加上协议 3 一侧的 `protocol_3_live_edits`），`cache_pairs` 10.9 秒（其中冻结的协议 3 缓存重建 8.7 秒），`class_differences` 8.0 秒，`collisions` 4.6 秒（同样对 `reg_ix` 每行整条解码）。共同的结构问题是派生层只要操作头部（实体 / 键 / 旧戳 / HLC），却每次都把整个操作体（含笔记字段正文）读出来解码。方向：在 `truth.rs` 给修改操作加一个只读头部和旧戳的读法，`dot_of` / `live_edit_ids` / `collisions` / `edit_write` 改用它。
- **派生层只解头部（反馈 90LCGy7XWn，2026-11-22，分支 `claude/fix-srs-gen4-derive-header`）**：`truth.rs` 加 `Truth::edit_read(k, with_value)`，直接从 `ops` 一行解修改操作的信封（操作号、HLC、依赖）与头部（`op.rs` `decode_edit_parts`：实体、键、标志、旧戳；字段值借原字节、不复制，旧戳内部化的行从 `aux` 直接解），原样件 / 剪了快照的行仍走整条读法。`class.rs` `dot_of`、`compare.rs` `live_edit_ids` / `collisions`、`derive.rs` `write_sees`、`dryrun.rs` `registerWinners`、`cmd/reads.rs` 两处读命令改用它；`derive.rs` `edit_lines_as` 只给 `emit` 要的写入读字段值。省掉的是旧路上的「旧戳拼回规范字节 → 整份载荷克隆 → 整条再解一遍」。合成库实测（25.6 万条带旧戳、字段正文约 560 字节的修改，按 `reg_ix` 逐行读）：整条读法 1.87 秒，只读头部 1.45 秒（每条 7.3 → 5.7 µs，约快 22%）。剩下的大头是 SQLite 按主键的点查（单独量 0.95 秒），解压与解码合计只有约 0.29 秒。所以分诊里「对拍阶段 edits 14.4 秒的大头是解码」不成立：解码只占两成左右，真正的成本在逐行点查。
- **超线性定位（反馈 VCUZIWB0Z2，同一天）**：`rebuild_all` 加了常驻的分段计时（`Index::rebuild_stages`，迁移报告新增 `rebuildStages`：clear / scan / closures / purged / aliases / weighRest / registers / entities / logs / digests / caches 各段秒数）。基准 `rebuild_scale_tests.rs` 用合成文件库测：连接配置与迁移相同，页缓存 16 MiB；每条笔记一条定义、一条带旧戳的字段修改，每张卡 5 个日志 ID，每个 ID 在两台旧设备上各一份，即资料库并入的副本形态。quick profile，本机结果：

  | 操作条数 | 重建 | µs/条 | scan | aliases | logs（`pick_log`） | digests | caches |
  |---|---|---|---|---|---|---|---|
  | 19.2 万 | 9.2 s | 47.8 | 2.1 | 0.9 | 0.4 | 0.7 | 4.7 |
  | 76.8 万 | 43.7 s | 56.9 | 10.0 | 4.5 | 2.4 | 3.0 | 22.2 |
  | 307 万 | 209 s | 68.1 | 56.5 | 18.1 | 10.6 | 14.0 | 105.6 |
  | 307 万，页缓存 2 GiB（A/B） | 183 s | 59.6 | 31.3 | 12.5 | 6.2 | 10.9 | 116.6 |

  结论有三条：
  1. **没有 O(n²) 的阶段**。规模放大 16 倍，每个阶段的耗时都只放大 16～27 倍，呈 n·log n 形。缓存物化内部分段量过（临时打点没提交，3.2 万 → 12.8 万笔记）：笔记循环 2.06 → 8.08 秒（线性）、按批重放 6.57 → 32.85 秒、`anki_duplicate_log_ids` 约 0 秒。
  2. **每条变慢主要来自页缓存未命中**。扫描阶段往 `log_ix`（主键按卡）、`log_id`（按日志 ID）、`reg_ix`（按实体）按日志序写，对这几棵 B 树来说是随机序；`pick_log` 按 ID 逐个点查再 UPDATE；缓存层按卡逐条点查日志操作（`log_at`）。表一超过 16 MiB 页缓存，每次都要换页。把页缓存加到 2 GiB 后，307 万条时扫描从 56.5 秒降到 31.3 秒，`pick_log` 从 10.6 秒降到 6.2 秒，每条从 68.1 µs 降到 59.6 µs，增长基本只剩缓存层（缓存层是重放 JSON 的 CPU 活，对页缓存不敏感）。
  3. 用户机器上 20 倍规模、每条耗时翻倍（117 → 225 µs），和「库 4.7 GB、旧机器的系统文件缓存装不下、随机读落到磁盘」吻合。本机系统文件缓存是热的，换一页只是一次 pread，所以同一个原因在本机只表现为 +40%。
- **[ ] ① 部分修复** — 已修：模板判空（见上）；派生层只解头部（`4b8f9ddc7b`）；重建分段计时进迁移报告。没修的是根因本身：派生表在重建扫描时按随机序写入、缓存层按卡随机点查日志操作。候选修法（未实施，要先拿用户库的 `rebuildStages` 确认慢在哪一段，本机验证不了 IO 那部分）：
  - 重建时派生表先清空，扫描阶段把 `log_ix` / `log_seq` / `reg_ix` / `ent_ix` 的行先按扫描序写进暂存表，扫完一次性 `INSERT … SELECT … ORDER BY 主键` 落进去，二级索引（`log_id`、`log_seq_k`、`ent_kind`、`ent_id` 等）先删、扫完再建。`log_seq` 的序号必须保持扫描序。
  - `pick_log` 改成一次按 `(col, id, k)` 顺序扫 `log_id`，在内存里逐组选代表，再批量 UPDATE。
  - 缓存层按批先收齐这一批要的日志操作主键，按主键排序后批量读，替代逐卡 `log_at`。
  不要盲调 PRAGMA：A/B 只用来定位。
- **[ ] ② 部分测试** — 已加：`truth.rs` `edit_read_matches_the_full_decode`（proptest：带旧戳 / 不带、压缩 / 不压缩、协议 3 原样件、别的种类、本机清成的空洞，头部读法与 `entry_by_key` + `body_of` 逐字段相同）、`edit_read_covers_every_stored_form`（四种存储形态都走到、原样件、空主键报错）、`dryrun.rs` `a_ready_library_passes_and_the_legacy_file_is_untouched` 断言报告带 `rebuildStages`；基准 `rebuild_scale_tests.rs` `rebuild_scale_duplicated_logs`（`#[ignore]`，`FUSHI_REBUILD_SCALE=…` 指定规模、`FUSHI_REBUILD_CACHE_KIB` 做页缓存 A/B）。没加的：断言「随规模近线性」的 CI 规模测试——本机满载时耗时抖动远大于要分辨的差别，接进 `native-fsrs-gate` 只会是伪红源；等上面的结构修法落地后，改用不受负载影响的计数（如重建期间的页缓存未命中数 `sqlite3_db_status(CACHE_MISS)`）来断言。
- **备注**：BUG-5063（同一份报告里的对拍误判）已单独修复。
