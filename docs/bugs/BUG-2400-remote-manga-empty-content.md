## BUG-2400 · 远端空漫画合集被标记为可下载内容
- **报告**：2026-09-10（用户截图：远端尚未下载的空漫画合集，点击报无法下载对端书籍）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/library/online_manga_library_service.dart:107` 为在线合集写入 `{"pages":[]}` 占位。`fushi/lib/src/sync/local_library_host_service/books.part.dart:80` 和 `fushi/lib/src/sync/manga_sync_package.dart:24` 原先仅凭 marker 存在声明可下载并打包，接收端导入器拒绝空页表。
- **[x] ① 已修复** — 清单与打包共用 `hasExportableMangaContent`，复用漫画导入器校验非空页表及全部页图；互联自动上传正常跳过无内容合集。提交见本文件所在修复提交。
- **[x] ② 已加自动化测试** — `fushi/test/sync/manga_sync_package_test.dart` 覆盖空页表、缺图、坏元数据、补齐内容；`fushi/test/sync/fushi_library_host_service_books_test.dart` 覆盖 host 清单；`fushi/test/sync/sync_orchestrator_live_book_test.dart` 覆盖空合集不上传且不报同步失败。
- **备注**：需更新提供清单的对端并刷新远端列表。未在用户原始手机/对端配对环境复测；不删除已有在线合集或章节缓存。
