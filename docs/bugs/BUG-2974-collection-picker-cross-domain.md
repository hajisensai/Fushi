## BUG-2974 · 书的加入合集列表里出现视频合集（合集未按媒体库隔离）
- **报告**：2026-10-05（用户：书移出合集后想加回去，「加入合集」列表里出现了视频的合集）
- **真实性**：✅ 真 bug。`media_collections` 表不带种类列（一张表承载书架 / 漫画库 / 视频库 / 游戏库），而共享的「加入合集」弹窗 `fushi/lib/src/media/collections/add_to_collection_dialog.dart:24`（旧 `database.getAllMediaCollections()`）直接列出全部合集——书、漫画、视频、游戏五个入口（书架书卡 / SRT 卡、视频库、游戏库、游戏详情）都吃这一份。另一条暗道：弹窗「新建合集」走 `createMediaCollection` 按 (名称, 类型) 自然键复用已有行，同名的视频合集会被直接复用，书就进了视频合集。
- **[x] ① 已修复（c2c8e6fe46c）** — 数据层新增 `FushiDatabase.getMediaCollectionsForEntryDomain(kind, entryKey)`（`packages/fushi_core/lib/src/database/database_library.part.dart`）：合集的库页域由成员推导，种类换算收口在 `media_kind_mappings.dart` 的 `CollectionShelfDomain` / `collectionShelfDomainOf`（epub 按 `epub_books.format` 再分书 / 漫画，uid 与旧 bookKey 成员键都认）；弹窗只走这一个来源。新建合集时若同名合集属于别的库页，提示换名（`collection_name_taken_other_library`），不再复用到别的域。
- **[x] ② 已加自动化测试（c2c8e6fe46c）** — `fushi/test/media/collection_picker_domain_test.dart`（书 / 字幕书 / 漫画 / 视频 / 游戏五域过滤、旧 bookKey 成员行、新建合集随首成员落域、弹窗不出现视频合集、源码守卫）。
- **备注**：空合集（没有成员、无从归属）不列出；成员横跨多域的混合合集在各自涉及的域都会出现（与库页折叠行为一致）。
