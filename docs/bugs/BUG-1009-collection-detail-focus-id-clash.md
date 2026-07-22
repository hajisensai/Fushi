## BUG-1009 · 合集详情页返回后书架同名卡手柄焦点不可达
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：⏳ 待真机复现（代码路径推理成立，未跑通完整证据链）。推理链：合集详情页成员卡直接复用书架卡渲染与**同一 focusId**（`reader_hibiki_history_page.dart:1609-1635` → `:1768` `HibikiFocusId('reader-shelf-book-…')`；SRT 同 `reader_history/books.part.dart:58`）；全 app 只有一个 `HibikiFocusRoot`（`hibiki/lib/main.dart:1535`）；焦点注册表按 id 覆盖（`hibiki/lib/src/focus/hibiki_focus_controller.dart:168` `_entries[entry.id] = entry`），详情页 pop 时按 owner unregister（:189-203）把该 id 整个移除——被覆盖的书架卡条目不会自动补注册。预期表现：打开书籍合集详情再返回，底层书架这批卡直到重建前 D-pad 落不上去。
- **[ ] ① 未修复** — 候选修法：详情页成员卡 focusId 加 route 前缀；或 unregister 时仅移除 owner 自己注册的 entry（注册表持栈而非覆盖）。
- **[ ] ② 未加自动化测试** — 建议焦点驱动集成测试：书架 Tab 到某卡 → 打开其所在合集详情 → 返回 → 断言同卡仍可 Tab/D-pad 到达。
- **备注**：先真机复现再定修法；巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 书籍模块。
