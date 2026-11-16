## BUG-4710 · 漫画「第N話 前編 [hash]」按话发布的各话没并成系列合集
- **报告**：2026-11-16（用户：维护者，应用内反馈 rT5chqFYOK）
- **真实性**：✅ 真 bug。Windows 漫画库里「十歳の最強魔導師 第1話 前編 [c36675f0]」「第2話 前編 [0af1bc64]」…「第12話 前編 [64b6baac]」每话各占一张卡。根因 `packages/fushi_engine/lib/media/collections/book_series_key.dart` 的 `parseBookSeriesKey`：剥掉 CRC 后缀后只认结尾卷号（`_volumeSuffix` 要求数字后只能跟 巻/卷/册/冊），「第1話 前編」整串留在系列名里，每话的系列键各不相同，`BookSeriesGrouper` 要求同键 ≥2 卷，一组都凑不成。
- **[x] ① 已修复**（053761f956）— `BookSeriesKey` 新增 `episode`（话号 + 前/中/後編分段），`parseBookSeriesKey` 先认结尾「第N話/话（前編/中編/後編）」，系列名取话号前一段（其前若有卷号照常读卷号）；话号不写进 `volume`（追踪按卷推进度、有声书按卷配对都读 `volume`，第 12 话不是第 12 卷）。合集内排序与规则卷序判定改用 `compareBookSeriesPosition` / `bookSeriesPosition`（卷号 → 话号 → 分段）。目录语境的 `parseBookVolumeFolderName` 不变（「第1話」子目录仍是章节、不是分卷）。存量书在下次 `groupAll`（打开书架 / 导入后）自动归组。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/book_series_grouper_test.dart`：「漫画按话：第N話…」解析用例 + 「漫画按话「第N話 前編 [hash]」并成一个合集…」归组 / 排序 / `BookSeriesOrder.orderOf` 用例。
- **备注**：未在真机 / 桌面应用里复测书架卡片。
