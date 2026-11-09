## BUG-4273 · collection-manage-count-mismatch
- **报告**：2026-11-10（用户：书架合集卡与「管理合集」页对不上——书架「七つの魔剣 5 卷」「無職転生 26 卷」「やはり俺の… 7 卷」，管理页却是 10 / 36 / 12 项，还多出书架上没有的「やはり俺の…。」「新系列」）
- **真实性**：✅ 真 bug。用户安装版库（`%APPDATA%\Fushi\Fushi\fushi.db` 副本）逐行核对：管理页 `fushi/lib/src/pages/implementations/collection_management_page.dart:85`（旧）直接数 `media_collection_items` 原始行，而书架合集卡数的是 `groupByCollections` 折进卡里的显示单元。原始行比显示单元多三类：① 有声书 SRT 与配对 EPUB 各一行（书架 EPUB 有配对 SRT 时只出 SRT 卡；魔剣 5+5=10）；② 已删条目的悬空行（無職転生 36 行里 2 条 EPUB、2 条 SRT 悬空，另 6 条 EPUB 配对 → 26）；③ 折叠归属被更小 id 合集抢走的成员（「やはり俺の…。」6 条成员实际折进了「やはり俺の…」那张卡，书架上没有它的卡）。「新系列」2 条成员都是悬空行。
- **[x] ① 已修复** — 管理页不再自己数原始行，改读库页发布的 `CollectionDisplayCounts`（书架 / 视频库 / 游戏库在 `groupByCollections` 之后 `publish`，值 = `collectionDisplayCountsOf` = 每张合集卡的成员数，与卡片「N 卷 / N 项」同一份折叠结果）；库页上没有卡的合集显示 0 项，仍可在管理页删除。值在 build 期算出、帧末写入（避免在库页 build 中途让另一条路由上的监听者 markNeedsBuild）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_management_page_test.dart`：原始 10 行（5 SRT + 5 EPUB）、库页发布 5 → 显示「共 5 项」不显示 10；库页不再有该卡 → 0；`collectionDisplayCountsOf` 散卡不计；`CollectionDisplayCounts` 帧末写入、同帧只落最后一次。
- **备注**：库页有搜索 / 标签 / 阅读状态筛选时，发布的是筛选后的折叠结果（与此刻卡片上的数字一致）。悬空成员行本身（已删书遗留的 `media_collection_items`）没有清理，那是另一个数据卫生问题。
