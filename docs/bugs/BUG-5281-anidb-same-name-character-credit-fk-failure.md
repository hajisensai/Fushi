## BUG-5281 · 同一声优配两个同名角色时写角色外部 id 撞外键，整部作品刮削失败
- **报告**：2026-11-23（排查视频待确认时在刮削运行记录里发现：Cosmic Princess Kaguya!、薬屋のひとりごと 报 `SqliteException(787) FOREIGN KEY constraint failed`，INSERT `video_metadata_provider_identities` character:anidb:152583）
- **真实性**：✅ 真 bug。AniDB anime 19701 的 `<characters>` 里 Kaguya 有两个 id（152136 / 152583），同一位声优 56190。`packages/fushi_engine/lib/media/video/metadata/video_metadata_database_store.dart` `_replaceCredits`：第一轮按 (person, kind, roleName) 去重（与表上 UNIQUE(owner, person_key, credit_kind, role_name) 一致），第二条 credit 被丢，它的角色行也没写；但随后补外部 id 的循环遍历的是**未去重**的 `credits`，给不存在的角色 152583 写 identity → 外键失败 → 整部作品 `pending:error`。
- **[x] ① 已修复** — 去重时收集真正写入的 credit（`written`），补人物 / 角色外部 id 只遍历它，写库与补 id 同一份数据。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_database_store_test.dart`「同一声优配两个同名角色（不同 id）时刮削不撞外键」。
- **备注**：同名同声优的第二个角色在 UI 上本就与第一个合成一条 credit，不写它不丢可见信息。
