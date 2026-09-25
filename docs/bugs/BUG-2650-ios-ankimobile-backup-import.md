## BUG-2650 · iOS 查词查不出 Anki 里已有的卡：AnkiMobile 无回读通道，补「导入 Anki 备份」
- **报告**：2026-09-25（用户：「ios 查词不会检查是否重复」；追问后确认按 Hoshi Reader 的做法导入备份）
- **真实性**：✅ 真缺口（平台边界 + 缺补救入口），弹窗链路本身无缺陷。
  - 先排除弹窗侧：iOS 26.5 模拟器上把生产 `DictionaryPopupLayer` 挂进真 WKWebView，`onDuplicateCheck`
    恒答 true，「直接显示」与「热槽隐藏后再显示」两种形态都按时发出 1 次查重并画出 ✓
    （`fushi/integration_test/ios_popup_duplicate_check_probe_itest.dart`，2/2 通过）。
  - 真正的缺口：AnkiMobile 后端的 `isDuplicate` 只问本机账本
    （`fushi/lib/src/anki/ankimobile_repository.dart` 的 `isDuplicate` → `AnkiMobileMinedLedger.contains`），
    账本只由 `x-success` 回跳落账（`fushi/lib/main.dart` 的 `_recordAnkiMobileMinedNote`，BUG-2532）。
    AnkiMobile 的 URL scheme 只有 addnote / infoForAdding / search / sync，没有任何回读 collection 的
    入口，于是**电脑 / 安卓上制的、直接在 AnkiMobile 里加的、账本上线前制的**卡，iOS 查词一律画「+」。
  - 对照 Hoshi Reader iOS（`Manhhao/Hoshi-Reader` develop `16a2f00`）：同样只有本地词表
    （`Core/AnkiManager.swift` `checkDuplicates` → `savedWords`），但多一个「Import Anki Backup」：
    解包 `.colpkg/.apkg` → zstd 解 `collection.anki21b` → `SELECT flds FROM notes` 取第一字段 → 整体
    覆盖词表（`AnkiManager.swift:762-880`）。它只认 anki21b（旧备份直接失败）、不去 HTML、导入会
    冲掉回跳记下的词。
- **[x] ① 已修复** — 照 Hoshi 的做法补「导入 Anki 备份用于查重」，并修掉它的三处短板：
  - `native/fushidicts/fushidicts_ffi.cpp`：新导出 `fushidicts_zstd_decompress_file`（流式文件 → 文件，
    走 ffi_guard 闸门），复用本库已静态链接的 libzstd，不新增原生依赖；`CMakeLists.txt` 给
    `fushidicts_ffi` 显式链 `libzstd_static`（原先是 `fushidicts` 的 PRIVATE 依赖，头文件路径传不过来）。
  - `packages/fushi_dictionary`：`lookupZstdDecompressFile()` **按需**解析该符号（不进急切查找的
    构造函数，旧原生库缺符号只影响本功能）+ `FushiDicts.zstdDecompressFile` / `FushiZstdException`。
  - `fushi/lib/src/anki/anki_backup_word_reader.dart`（新）：后台 isolate 里解包，三代 collection 都认
    （anki21b 优先，其次 anki21 / anki2——新版导出同时带一个占位 anki2，顺序不能反），第一字段去
    HTML / 解实体 / trim（与 Anki 自己判重同口径）。
  - `fushi/lib/src/anki/ankimobile_mined_ledger.dart`：新增「导入快照」，与回跳落账**分两份存**：快照是
    某一时刻整个 collection，重新导入整份替换（备份后删掉的卡借此消失）；回跳落账不被冲掉。快照动辄
    数万条，落应用支持目录下的 JSON 文件（原子改名写入），不进 SharedPreferences、不受 5000 条上限。
    `contains` 取并集，`forget` 两份一起划，导入后 `MinedStateSignal.notifyAll()` 刷新已渲染的 ✓。
  - 设置 › 制卡：iOS 且账本确实是查重来源（未改用 AnkiConnect、未制卡到服务器，判据
    `ankiMobileLedgerIsDuplicateSource`）时显示「导入 Anki 备份用于查重（已导入 N 个词）」，并登记设置搜索。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/anki_backup_word_reader_test.dart`：三代 collection 的选取顺序、只有 anki21b 经解压、
    去 HTML / 实体、缺 collection / 非 SQLite / 非 zip 报格式错、中间文件成功失败都删。
  - `fushi/test/anki/ankimobile_mined_ledger_test.dart` 新组「导入快照」：并集、替换语义且保留回跳落账、
    落文件不进 prefs、不受上限、`forget` 两份一起划并落盘、广播 notifyAll、坏文件 fail-soft、写失败必须报错、
    门控判据。
  - `fushi/integration_test/ios_anki_backup_import_itest.dart`（iOS 26.5 模拟器 3/3 通过）：真原生 zstd 解
    `pzstd -19` 样本（含 skippable 帧）、anki21b + 占位 anki2 备份经后台 isolate → 快照 → `AnkiMobileRepository.isDuplicate`
    为真、生产默认快照路径在 iOS 应用支持目录可写。
- **备注**：
  - 未在真机上用 AnkiMobile 真导出的备份走一遍设置页（模拟器装不了付费的 AnkiMobile，也无法自动化系统文件选择器）；
    格式按 Anki 源码与 Hoshi 实现对齐，anki21b 解压与读库已在模拟器真原生路径验证。
  - 能力边界不变：快照只反映导出那一刻；之后在别处加的卡要重新导入才认得（设置行文案已提示定期重新导入）。
