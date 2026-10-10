## BUG-3245 · 打开已从本机移除的远端书设置页会在云盘建同步根目录
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2024）。根因 `fushi/lib/src/sync/hidden_remote_books.dart` `resolveShelfRemoteBookClient`（原 :230）走云盘来源时无条件 `backend.findOrCreateRootFolder()`；`HiddenRemoteBooksPage._probeRemote`（`hidden_remote_books_page.dart`:68）为核对「书还在不在」也调它——仅打开设置页，就可能在用户云盘上建出同步根目录、甚至跑旧根改名迁移（书架关掉「显示远端条目」时书架本身不会触发，这条路径是新增的远端写）。
- **[x] ① 已修复** — `ee891e2312`：`resolveShelfRemoteBookClient` 加 `createRootFolder`（默认 true，书架行为不变）；设置页传 false，只用本会话已解析过的 `cachedRootFolderId` 或上次同步落盘的根（`SyncRepository.getRootFolderId`，嵌旧根名的陈旧路径不算），都没有就返回 null（不下「已不在远端」的结论，安全方向）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/hidden_remote_books_probe_no_create_test.dart`（WebDAV 指向不可达端口：无已知根返回 null 不抛、落盘根 / 会话缓存根直接用、对照书架默认路径会去远端）。
- **备注**：
