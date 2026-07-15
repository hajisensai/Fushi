## BUG-830 · 书架合集行头「N项」漏算折进合集的远端占位成员(只数本地)
- **报告**：2026-07-14（用户：书架合集数量还是不对）
- **真实性**：✅ 真 bug。根因：`reader_hibiki_history_page.dart` `_buildShelfCollectionRow` 行头 `countLabel: t.series_item_count(n: localCount)`,`localCount` 过滤掉 `payload.remote`/`payload.remoteSrt`(只数本地成员),而行体 `itemCount: group.items.length`(渲染全部含远端)。旧注释「远端占位卡不进合集」是 BUG-812 之前的假设;BUG-812 后远端有声书/书会经内联 `collection` 字段折进合集,行头计数却没跟上 → 「N项」少于实际渲染卡数。与联合视图总数 BUG-815、视频 BUG-790 同类。
- **[x] ① 已修复** — 行头 `countLabel` 改用 `group.items.length`(与 itemCount 同源),计入折进合集的远端占位成员。删掉只数本地的 `localCount` 过滤。
- **[x] ② 已加自动化测试** — `test/pages/reader_remote_collection_membership_test.dart`:本地建合集、2 本远端书带 `collection` 归属折进它 → 断言行头 `series_item_count(n:2)`(旧实现只数本地=0)。
- **备注**：取 817 避让 origin/develop 已用的 808-810。合集**详情页**(查看全部)是否也需含远端成员是另一 feature（BUG-790 备注同款,详情页联合另计）。
