## BUG-5075 · SRS 牌组列表冲突角标的 `conflict_edits` 在迁移库上跑几分钟
- **报告**：2026-11-21（用户转来的排查报告：`3.4.0-debug.30040` Windows，656 MB `srs4.db` 上单次 `core:read:conflict_edits` 356,645 ms、返回 44,245 行 / 19.8 MB，Dart 过滤后 0 条）
- **真实性**：✅ 真 bug（本机真库副本形态不同，复现为 9.3–17.0 s / 42 行）：
  - `native/fushi_fsrs/src/store/gen4/cmd/reads.rs` `conflict_edits` 对每个候选实体调 `class_rows` 拼出全部键（含笔记正文 `f/*` 与合成 tags 行）后才 `rules.tracks` 过滤——协议 3 `store/reads.rs:390-398` 在 SQL 阶段下推，BUG-3947 的同一教训。
  - `store/gen4/class.rs` `class_lines` 单源捷径条件 `single && raw.len() == 1`，`single = members.len() == 1`；迁移库每个实体在 `alias_ix` 有一条旧 ID 映射，`members` 恒为 2，捷径 100% 失效，全部掉进按类重判 + 第二遍 `edit_lines_as`。`class_tags` 同样按成员数误判。
  - `conflict_candidates` 用「类里有别名」选候选（`alias_ix CROSS JOIN reg_ix`），迁移库等于整库实体。
  - 只交回 `state = R_LIVE` 的多写寄存器，同值并发写入全部过 FFI 再在 Dart 丢弃。
- **[x] ① 修复** — 键先按规则粗筛再按规范键定夺，过了才读操作体，不再拼 tags 行；捷径改为 `raw.len() == 1 && !touches_renamed`（与成员数无关，等价性论证见提交 29e675749d2 与 `class.rs`）；`class_tags` 改为有标签行的成员数 > 1 才重判；候选改为一条汇总 SQL（有 `R_CONFLICT` 的实体、有行成员 ≥ 2 的类、有改名写入者时含非胜者行的实体）并补「嵌 ID 键归一撞键」候选（旧代码对这类实体漏报）；单源寄存器只交回 `R_CONFLICT`（超集，Dart 裁决结果不变）。真库副本 9.3–17.0 s → 约 0.5 s，裁决后冲突集合逐个一致（对拍覆盖全部 23,794 个旧候选）。
- **[x] ② 自动化测试** — `native/fushi_fsrs/src/store/gen4/cmd/tests_class.rs`：`the_class_lines_shortcut_is_the_class_judgement`（仅旧成员 / 仅规范 / 两者都有 / 跨原值键归并四种形态，捷径输出与按类重判逐字节一致）、`conflicts_from_two_raw_keys_of_one_entity_are_found_and_same_value_writes_are_not` 等；真库基准 `real_db_conflict_edits_bench`（`FUSHI_G4_BENCH_DB`，含修前对拍）。
- **备注**：报告的 P1-5（角标直出计数）未做：修后回包只剩可能冲突的寄存器（真库 2 行），二次往返代价可忽略；部分索引 `reg_conflict` 未加（候选扫描本来就要一趟按实体汇总，省不掉，且要升 schema）。报告第四节 TTS/ASR 取消后显存不释放与本 bug 无关，未处理。
