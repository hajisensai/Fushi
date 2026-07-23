## BUG-1009 · 合集详情页返回后书架同名卡手柄焦点不可达
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：⏳ 待真机复现（代码路径推理成立，未跑通完整证据链）。推理链：合集详情页成员卡直接复用书架卡渲染与**同一 focusId**（`reader_hibiki_history_page.dart:1609-1635` → `:1768` `HibikiFocusId('reader-shelf-book-…')`；SRT 同 `reader_history/books.part.dart:58`）；全 app 只有一个 `HibikiFocusRoot`（`hibiki/lib/main.dart:1535`）；焦点注册表按 id 覆盖（`hibiki/lib/src/focus/hibiki_focus_controller.dart:168` `_entries[entry.id] = entry`），详情页 pop 时按 owner unregister（:189-203）把该 id 整个移除——被覆盖的书架卡条目不会自动补注册。预期表现：打开书籍合集详情再返回，底层书架这批卡直到重建前 D-pad 落不上去。
- **[x] ① 已修复**（PR#334，预防性）——`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1574-1749`：详情页渲染路径 `_buildCollectionMemberCard` 给成员卡 focusId 统一加 `collection-detail-` route 前缀（新增 `_buildEpubBookCard` / `_buildSrtCard` 的 `focusIdPrefix` 参数，书架路径恒空串、id 与快捷键锚点语义零变化），隔离命名空间，避免与书架同名卡撞 focus 注册表。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/collection_detail_focus_id_test.dart`：真焦点注册表断言详情页成员卡 focusId 带 `collection-detail-` 前缀、与书架同书卡 id 不相等（撞号消除）。
- **备注**：根因/修法为代码路径推理成立，focusId 撞号已由上述测试守住；真机 D-pad 往返复现仍待补（不阻塞落地）。巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 书籍模块。
