## BUG-5366 · 库管家补刮只认 collection 型合集、系列（playlist）各卷按卷名查而认不出
- **报告**：2026-11-24（用户：漫画书架横幅「43 部漫画还没认出来，资料和封面都没刮到」，AI 库管家没自动处理）
- **真实性**：✅ 真 bug。本机库实测（`fushi.db` 只读）：43 个待确认单元全是已归好系列的分卷（十歳の最強魔導師 第N話 前編、魔法少女にあこがれて (N)、不揃いの連理 0N、行進子犬に恋文を 0N、世界で一番おっぱいが好き！ N、バカに告白 1【電子限定特典付き】…），缺的都是作者。根因三处：
  1. `packages/fushi_engine/lib/media/library_curate/library_curator.dart` `DatabaseLibraryCurateFacts.bookScrapeUnits`（原 2498–2516 行）只把 `collection_type = 'collection'` 的合集当系列；而系列归组（`book_series_grouper.dart`）、库整理计划、AI 助手建的系列合集都是 `'playlist'` 型（本机 epub 相关合集 playlist 13 个、collection 2 个）。系列各卷于是全被拆成单本，按带卷号 / 话号 / 店铺标签的单卷名去查。
  2. 同文件 `_scrapeBooks` 规则认领只在「候选恰好一条且标题规范化后一致」时成立，AI 只在候选 ≥2 时才问。Bangumi 实测：`不揃いの連理 01` 唯一候选 `不揃いの連理`（卷号让标题不等 → ambiguous、AI 不问）；`魔法少女にあこがれて (11)` 返回 291 条、第一条就是 `魔法少女にあこがれて`。
  3. 自动路径跳过 `seen` 里的单元（`_openBookUnits`），且水位已过，旧判据下没认出的再也不会重看。
- **[x] ① 已修复** — 系列身份改用与归组同一判据（包内声明系列优先，否则 `parseBookSeriesKey` 按改名覆盖优先的书名解析），与合集类型无关，单元 id `series:<书架>|<系列键>`；单本也按去掉卷号 / 标签后的系列名（`LibraryCurateBookUnit.query`）查；规则认领改为「候选里恰好一条与书名或系列名一致」；规则认不了而有候选（含唯一不一致候选）就交 AI（游戏同步）；单卷按系列名认到系列条目时只补作者，不拿系列封面 / 书名写这一卷；`LibraryCurateState` 升 v2，读 v1 时清掉书补刮的水位 / 进度 / `seen` / `book_scrape_pending` 待确认项（保留 `scrape.books.done:` 与撤销抑制），下一趟自动路径按新判据全量重看。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/library_curate/library_curate_facts_test.dart`（playlist 系列按系列名成单元、混合合集不当系列、单本 query 去卷号与店铺标签）、`packages/fushi_engine/test/media/library_curate/library_curator_test.dart`（多候选唯一同名直接认、唯一不同名交 AI、单卷认到系列条目只补作者、状态 v1→v2 迁移）。
- **备注**：零候选时 AI 不改写搜索词（没有候选可选）；去掉卷号后的系列名在本机这批上 Bangumi 都能搜到。
