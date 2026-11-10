## BUG-4335 · 在线（扩展源）漫画同步恒失败：按字符表解析在线漫画的章节清单抛 TypeError，且对比弹窗失败原因不可见
- **报告**：2026-11-08（应用内反馈 tHFnpAFrX9，Windows 3.3.0：Keiyoushi 扩展 Rawkuma 源的 Mieruko-chan 不同步；对比弹窗本地 Page 2、远端 No data，「Sync now (1)」点了没有任何效果和错误）
- **真实性**：✅ 真 bug（沿代码路径定位；反馈日志里没有同步错误，与「失败只进 developer.log」一致）。
  - 根因①：`fushi/lib/src/sync/sync_manager.dart` `_syncBookProgress`（原 :600）不分格式 `parseChaptersJson(book.chaptersJson)`。在线扩展源漫画（`OnlineMangaLibraryService.add`，`online_manga_library_service.dart:166` 写 `_chaptersJson(entry.chapters)`）的 `chaptersJson` 是**章节清单**（`OnlineMangaChapter.toJson`：key / name / raw，无 `characters`），`position_converter.dart:21` 的 `m['characters'] as int` 抛 TypeError → 每本在线漫画在云通道（自动 sweep 与对比弹窗「立即同步」）恒失败。页式书的位置换算本就只走页码，用不到字符表。
  - 根因②（不可见）：`syncBook` 把异常收进 `SyncBookResult.error` 不留日志；对比弹窗 `applySyncCompareChoices`（`sync_compare_dialog.dart` 原 :1040-1060）失败只 `developer.log(name: 'SyncCompare')`，SnackBar 只列书名、随即关框——用户日志与界面都看不到原因。
- **[x] ① 已修复** — `paged_book_sync_position.dart` 新增 `syncChapterCharTable`：页式书（含在线漫画）返回空表、不解析 chaptersJson，`_syncBookProgress` 改用它。`syncBook` 失败一律经 `ErrorLogService` 进 app 日志（`SyncManager.syncBook`，带书 key、来源类型 `syncBookSourceKind`、阶段 `SyncBookStage` 与堆栈）；`applySyncCompareChoices` 带回 `failureReasons`，对比弹窗失败时不关框、在框内显示「书名: 原因」，关闭时仍把已应用数带回。
- **[x] ② 已加自动化测试** — `fushi/test/sync/online_manga_sync_test.dart`（根因 TypeError 复现、在线漫画导出 / 自动方向 / 导入成功、失败日志带 key/来源/阶段、apply 结果带原因、对比弹窗 widget 失败显示）。
- **备注**：测试未在本分支运行（批次策略：合并后统一验证）。未做真机复测。在线漫画云通道 wire 只带「章内页码」（`exploredCharCount`），不带当前章（`sourceMetadata.currentChapterIndex`）——跨设备导入会把页码落到对端当前章，这是既有口径问题，未在本条改动，列为待决策项。
