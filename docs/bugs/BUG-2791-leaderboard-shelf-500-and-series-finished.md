## BUG-2791 · 排行榜书架/分享本月 500；只看第 1 集整季被判读完
- **报告**：2026-09-29（用户：统计中心 › 排行 截图三张——榜单「共 0 人」、「分享本月」与个人主页「读完」列表报「服务器出错（500 internal）」、一整季动画只打开过前两集却被统计为读完）
- **真实性**：✅ 真 bug，两个独立根因；「榜单 0 人」不是 bug。
  1. **书架 500**：`services/leaderboard/src/views.js` `readerWalls` 为当页每部作品拼一段子查询再 `UNION ALL`（一页最多 50 段）。D1 的 compound SELECT 上限只有 **5 段**（2026-09-29 用 `wrangler d1 execute --remote` 实测：5 段通过、6 段 `too many terms in compound SELECT`），`wrangler tail` 抓到线上异常 `D1_ERROR: too many terms in compound SELECT at readerWalls → userShelf`。书架一页有 6 部以上作品就 500；「分享本月」`loadLeaderboardShareCardData` 读的是同一个 `userShelf`，所以一起 500。本地测试用 node:sqlite（默认上限 500），全绿上线才炸。
  2. **整季误判读完**：`packages/fushi_engine/lib/leaderboard/local_shelf.dart` `_videoEntries` 把「绑定到单个文件的刮削作品」（`workByBook`）一律当电影单元，这个文件看完 = 作品读完。刮削计划器（`video_source_work_planner.dart`）对不在多成员合集里、或文件名解析不出集号的剧集文件会逐个刮成 `book:<uid>` 的 `media_type='tv'` 作品；这些单元带着同一作品身份上报，服务端 `shelf.js` 合并同一作品时取「任一读完」，于是看完第 1 集 = 整季读完（线上该条只有 10.7 分钟 / 1204 字）。另一条同源误判：合集只下载了前两集且都看完，也会被判整季读完。
  3. 「共 0 人」：榜单读 30 分钟一刷的快照，截图时快照停在 22:00，而 shishamo 22:13 才首次同步；「周 / 书」按本周读完的书计，星尘本周没有读完书。数据与口径一致，不是 bug。
- **[x] ① 已修复** — `readerWalls` 改为每部作品一条带 `LIMIT` 的语句、`env.DB.batch()` 一次往返（仍沿 `idx_shelf_work` 有界读取）；视频剧集按作品身份（refs 首键，与服务端合并依据一致）分组，读完 = 季集骨架里每个正片集（季号 > 0）都绑着看完的本地文件，没骨架时只认合集单元全部成员看完，单个文件刮成的剧集作品看完不算整部；组内每条上报带同一个读完结论。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/harness.js` 按 D1 口径拒绝超过 5 段的 compound SELECT、batch 里的 SELECT 带回结果行（加上限后，既有「用户书架游标分页」用例在旧代码下即变红）；`services/leaderboard/test/views.test.js`「一页超过 5 部作品」；`fushi/test/leaderboard/local_shelf_test.dart`「剧集读完 = 看完整部」组 5 条。变异实测：换回旧 `views.js` / 旧 `local_shelf.dart`，新用例全部变红。
- **备注**：修复只影响之后的同步；已上报的误判「读完」在客户端下次同步时由新口径覆盖（同步按条目内容 hash 判变更，`finished` 变了即重传）。
