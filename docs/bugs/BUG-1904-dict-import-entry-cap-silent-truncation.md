## BUG-1904 · 词条数撞 100 万每 bank 上限被静默截断，仍报导入成功
- **报告**：2026-08-28（用户给了一个词典 zip：「那三本词典好像不支持」；查 [BUG-1903](BUG-1903-dict-zip-multi-mdx-only-first-imported.md) 时顺带量出来的第二条根因）
- **真实性**：✅ 真 bug。单本导入大辞林时 `termCount` **正好是 1000000** ——整数得可疑。直接读 MDX 头里的 `num_entries` 对账，确证是截断：

  | 词典 | MDX 头声明 | 修前导入 | 差 |
  |---|---|---|---|
  | 岩波国語辞典 | 189782 | 189782 | 0 |
  | 旺文社国語辞典 | 220573 | 219343 | −1230（重复 key 去重，正常） |
  | **三省堂大辞林 第四版** | **1086308** | **1000000** | **−86308（正好卡在上限）** |

  根因在 `native/fushidicts/fushidicts_src/importer.cpp:1063`（修前）：`process_simple_entries()` 是 **MDX / DSL 的整本词典条目流**，却用了 `kMaxEntriesPerBank = 1'000'000`（`:44`）当上限，到点 `break` 且只打一条 `FUSHI_LOGW`，`success` 照样是 true。
  **这不是「上限设小了」，是同一个常量在两种布局下语义完全不同**：Yomitan 一本词典摊成几十上百个 `term_bank_N.json`、每个几千条，100 万/bank 绰绰有余；而 MDX 整本词典就是这一个流，于是「每 bank 上限」被当成了「整本词典上限」。真实存在的大型国语辞典（大辞林 108 万条）正好落在这个错位区间里，导入报成功、实际少了 8 万条——用户查不到词，只会觉得「这本不支持」。
- **[x] ① 已修复** — `process_simple_entries` 改用 `kMaxTotalEntries`（`10'000'000`），那才是「整本词典」级别的 OOM 保护。这是修语义错位，不是把闸门拆掉：另外两道保护原样保留（`kMaxDataBufferBytes` 1 GB 数据缓冲、`kMaxGlossarySizeBytes` 单条 10 MB），`kMaxTotalEntries` 本身仍是有限值；Yomitan 的 term / meta / kanji 三条 bank 路径**继续**用 `kMaxEntriesPerBank`——那三处语义是对的，本次一处没动。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_multi_archive_import_test.dart` 第三组 3 条源码守卫：整词典流用 `kMaxTotalEntries` 且不再出现 per-bank 上限、另外两道 OOM 保护仍在且 `kMaxTotalEntries` 仍是有限值、per-bank 上限在 Yomitan 三条 bank 路径上出现次数恰为 3（防止「顺手全改了」）。
  变异实测：把整词典流改回 `kMaxEntriesPerBank` → 精确红 2 条（上限断言 + per-bank 出现次数 3→4）；还原后 sha256 与变异前一致（`d303d46014f25046…`）。
- **端到端复核（真引擎，用户原包）**：重建 `fushidicts_ffi.dll` 后重跑同一组导入 ——
  ```
  [PROBE] iwanami  term=189782   declared=189782   delta=0
  [PROBE] obunsha  term=219343   declared=220573   delta=-1230
  [PROBE] daijirin term=1086308  declared=1086308  delta=0  cappedAt1M=false
  ```
  大辞林从 1000000 恢复到完整的 1086308，找回被砍掉的 86308 条；另外两本逐条不变（无回归）。
- **备注**：**截断的可见性缺口仍在**——达到 `kMaxTotalEntries` 时依旧只有 `FUSHI_LOGW`，`FushiImportResult` 没有 `truncated` 字段，上层无从得知。本轮没做这件事，因为它要改 FFI struct 的 C ABI（native + Dart 两侧同步），影响面远超本条；而修完之后触发门槛已从「真实存在的大词典就会撞」变成「1000 万条，实际不可达」。如果将来要补，正确做法是给结果结构加显式的 truncated 标志并在导入完成提示里 surface，而不是继续靠日志。真机验证未做（用户已取消该环节）。
