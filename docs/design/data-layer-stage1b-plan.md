# P3 Stage 1b 实现计划(工作文档,2026-08-10)

> 基线:develop@879b2a0f46(v81,epub_books.uid 已随行积累)。目标 schema v82。
> 两份侦察地图的关键结论已收敛于此;实现时以本文件为清单,file:line 若漂移以真码为准。

## 设计决策(已拍板)

1. **键形**:四张子表(reader_positions/bookmarks/book_custom_css/revealed_images)
   的书键列从 `bookKey`(=sanitize(title))切到 `uid`。列名统一 `bookUid`?——**不**,
   沿用列名 `book_key` 改语义会造成灾难性误读;新列名 `book_uid`,旧列删除
   (create-copy-drop-rename,v24 先例:database_tags_sync.part.dart:904-947)。
2. **FK(修正版)**:SQLite FK 要求父列有**完整** UNIQUE 约束;epub_books.uid 的
   唯一性只有 partial 索引(WHERE uid != ''),FK → uid 直接 "foreign key mismatch"。
   重建 epub_books 换真 UNIQUE 牵动 PK/全表 FK,超出本阶段。**决策:四表全部去
   SQL FK**,统一靠 deleteEpubBook 显式级联(该函数本就自称「不依赖 pragma」,
   bookmarks/reader_positions 已显式删):
   - deleteEpubBook 补 book_custom_css + revealed_images 两处显式清理(修掉
     「删书留孤儿」缺口);迁移前先清 css 存量孤儿(revealed 旧 FK 保证无孤儿)。
   - 新增守卫测试:deleteEpubBook 后四表零残留(PRAGMA foreign_keys 无关)。
   - reader_positions 维持无 FK 的额外理由不变(SRT 书行)。JOIN 不上 epub_books
     的行照抄原键值:book_uid 列语义 = 「epub 书为 uid;非 epub 域沿用其现有稳定键」。
3. **换算职责**:调用方手里是 bookKey(全 app 现状)。DAO 层不做隐式换算;新增
   换算入口 `resolveEpubBookUid(bookKey) → String?`(内部 getEpubBook 取 uid),
   sync/互联/备份落地点(wire 冻结 bookKey)先换算再写,换算失败沿用 host service
   的 no-op 语义。**页面侧**(阅读器/书架)改为从手头的 EpubBookRow 直接取 `.uid`,
   不再传 bookKey 字符串。
4. **备份合并引擎**(backup_merge_engine.dart):
   - `_mergeReaderPositions`(549-572)+ preview `_countReaderPositionChanges`
     (277-288):双侧 JOIN 换键(src.book_uid → mergesrc.epub_books.uid→book_key
     → 本库 epub_books.book_key→uid);JOIN 不上的行(SRT 域)按键值直等合并
     (两库 SRT 键同为派生串,仍可比)。
   - `_mergeBookmarks`(988-1001):同 JOIN;FK guard 换 uid 存在性。
   - **补齐缺口**:book_custom_css / revealed_images 今天不进 merge(静默丢弃)。
     本阶段补两个 LWW 合并方法(css by updatedAt per {uid,relativePath};revealed
     by revealedAt per {uid,imageKey}),同 JOIN 形。
   - **uid 撞库防线**:`_insertMissing('epub_books','book_key')`(135)直搬含 uid,
     两库 `book_<rowid>_<epoch秒>` 可撞 → merge 对 epub_books 插入行的 uid 列改为
     本机重生成(或冲突时重生成),否则 partial 唯一索引炸整个事务。
5. **wire/assetKey 全部不动**:云文件夹名 sanitizeTtuFilename(title)(sync_manager:308)、
   互联 REST `/books/<bookKey>/progress`(fushi_sync_server:1365)、css sidecar、
   SyncDeletionTombstones.itemKey、`audiobook_pos_<bookKey>` 偏好键——全冻结。
   变更点仅本地落库前后的换算:sync_manager:318/576、sync_orchestrator:1613/2816、
   host service:381(uid→bookKey 反查出 wire)/496/540、reader_history/remote.part.dart:526。
6. **迁移 v82**(照 v76 形,可重入):
   a. 清 book_custom_css 孤儿(无 epub 宿主行);
   b. 四表 create-copy-drop-rename,book_uid 经 `LEFT JOIN epub_books ON book_key`
      回填(epub 命中→uid;未命中→原键值照抄,reader_positions 专属;其余三表
      epub 域,未命中行=孤儿,bookmarks/revealed 由旧 FK 保证不存在,css 已清);
   c. 重建索引:idx_bookmarks_book_uid_created(database_infra.part.dart:59-61 跟改)、
      各表唯一约束换 book_uid;
   d. onCreate 侧与迁移成对。
7. **DAO 面**(全列于侦察报告,凭符号 grep 复核):
   - reader_positions:get/getAll/upsert/delete(database_library.part.dart:1045-1064)
     + deleteEpubBook 内联(database_content_misc.part.dart:504);参数改 bookUid。
   - bookmarks:BookmarkRepository(packages/fushi_audio/.../bookmark_repository.dart)
     全套 + deleteEpubBook 内联(:511)+ migrateLegacyBookmarkPreferences(raw SQL)。
   - css:upsertBookCss/markBookCssReset/getBookCssRows/mergeRemoteBookCss
     (database_tags_sync.part.dart:511-663)。
   - revealed:markImageRevealed(s)/getRevealedImageKeys/watchRevealedImageKeys
     (database_tags_sync.part.dart:542-578)。
8. **页面消费点**(改传 uid):reader_fushi navigation.part.dart:1191-1206、
   reader_fushi_page.dart:1948-1972/2053、webview.part.dart:2280、
   illustrations_viewer_page.dart:86/109、manga_fushi_page.dart:983/1225/2840、
   reader_pdf_page.dart:151/196/444/467/492、mihon_library.dart:257、
   book_css_editor_page.dart:26/53/66/68/183、
   reader_fushi_source.dart:67/484-512(bookLastReadAtProvider 键语义:epub 行
   变 uid → 消费方 join 书列表时用 book.uid 查,SRT 行沿用)、
   media_tracking_repository.dart:365/706/833、collections_page.dart(仅内存对象,不动)。
9. **测试**:
   - 跟改:backup_merge_import_test(732/834/1036)、reader_positions_test、
     book_css_sync_test、reader_position_repository_test、bookmark_repository_test。
   - 新增:①「两库随机 uid 互异、同 book_key JOIN 换键仍命中」四表各一;
     ②「src/target uid 相撞,epub_books 插入不炸」;③ css/revealed 新合并 LWW;
     ④ v82 迁移定向测试(旧库造数→升级→键形/不丢行,顺带补 v81 uid 回填断言缺口);
     ⑤ cascade 用例必须 PRAGMA foreign_keys=ON(memory DB 默认关)。
   - 勿动:reader_positions_migration_v24_test(历史快照)、host 进度 wire 断言
     (bookKey 面貌不许变)。
10. **明确不做**(Stage 2/3 边界):shelf_entries/media_collection_items/
    tag_assignments/book_profiles/media_open_history(`hoshi://book/<bookKey>`)、
    sync 协议 per-uid。sync_baselines.assetKey 别误伤(title 派生,非子表键)。

## 疑似活 bug 线索(正交,另行验伪,勿混入本 PR)

- app_model_library_host_service.dart:371 进度正则 `^fushi://book/` vs canonical
  `hoshi://book/`(override_thumbnail_migration.dart:35 迁移方向)——互联书进度
  百分比可能对 hoshi:// 行全 miss;audiobook_session_launcher.dart:66 仍在写 fushi://。

## 执行顺序

1) fushi_core:tables.dart 四表定义 + v82 迁移 + onCreate + DAO 换签名
2) fushi_audio:两个 repository
3) fushi 页面/斜杠消费点 + resolveEpubBookUid
4) backup_merge_engine 四表 JOIN + uid 撞库防线 + 补两张表合并
5) sync/互联落地点换算
6) 测试跟改 + 新增;analyze;全量门
