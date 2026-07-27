## BUG-1164 · 漫画模块化重构遗留孤儿 i18n key 与 shelf 页面名违规
- **报告**：2026-07-27（用户：PR#474 审查 + develop 真单测门变红）
- **真实性**：✅ 真 bug（一组）。PR#474 删掉框选补扫 / 云 OCR 旧实现并把阅读器搬到
  `lib/src/media/manga/reader/` 后留下的残留与守卫失配：
  1. 19 个 i18n key（`manga_rescan_*` 13 个 + `manga_cloud_ocr_*` 6 个）与
     `preferences_repository.dart` 三对 `mangaCloudOcr*` getter/setter +
     `app_model.dart` 六个转发 wrapper 全部零消费方；
  2. 新建 `class MangaShelfPage`（`manga_shelf_page.dart:11`）违反命名术语表——
     `shelf` 已冻结给 `ShelfEntries` 域，新代码禁止用作页面名；
  3. `reader_hibiki_history_page.dart` 的 `mangaOnly` 分流零测试；
  4. develop 真单测门红：`reader_hibiki_history_page.dart:1050` 的
     `_mangaOnly ? books :` 三元把「借用映射源必须是未筛选全量」这条 BUG-963
     不变量在 mangaOnly 分支破了口；`manga_spread_double_page_test.dart` 的测试
     AppModel 漏了 PR#474 新增的三个偏好 override（`_loadBook` 抛 null-check，
     页面永远卡在加载态）；另有 4 条守卫的路径/判据假设没跟上模块重构。
- **[x] ① 已修复** — ① 19 个 key 经 `tool/i18n_sync.dart --remove` 删除（17 语言
  + `dart run slang` 重生成），三对 getter/setter 与六个 wrapper 一并删除；
  **`sync/pref_redaction_policy.dart:73` 的 `manga_cloud_ocr_api_key` 脱敏白名单条目
  保留不动**——老设备 db 里已写过该 key，删了会造成真实凭据出境。
  ② `MangaShelfPage` → `MangaLibraryPage`，文件 `manga_shelf_page.dart` →
  `manga_library_page.dart`，`pages.dart` / `home_page.dart` 引用同步。
  ③ 分流逻辑提成纯函数 `filterShelfEntriesByMangaSplit`（一次相等判断代替两个分支）。
  ④ 删除 `_mangaOnly ? books :` 三元恢复未筛选全量借用源；`manga_spread_double_page_test`
  补三个 AppModel override；`mime_types_test` 的 manga 图片服务豁免**跟随文件移动**
  到新路径（`_mangaMimeForPath` 逐字未变）；`md3_design_system_static_test` 给
  `google_lens_ocr_service.dart` 的 `MokuroBlock.fontSize` **数据字段**加与
  `mokuro_payload.dart` 同类的 reviewed 豁免，另两处 MD3 违规改新代码（向导
  `ListTile` → `HibikiListItem`，阅读器 debug 徽标 `BorderRadius.circular(8)` →
  `HibikiBorderRadius.chip`）；`manga_selection_dispatch_test` 换靶到新的字级选词
  入口 `selectFromPosition(node, 0, 40, x, y)`（maxLength 危险未变，判据换靶不放宽）
  并修掉两处宣称仍调 `selectText` 的假注释；`book_import_dialog_ocr_entry_test`
  换靶——Lens 全平台可用后「移动端默认隐藏」的前提消失，改判「两端都亮出入口且
  `probeCalls == 0`」（比旧判据更严：渲染决策不得产生网络副作用）。
- **[x] ② 已加自动化测试** — 新增
  `hibiki/test/pages/manga_library_page_split_test.dart`：分流谓词互补性（并集=全集、
  交集为空、顺序保持、空输入）+ 漫画库页确实接 `mangaOnly: true`、普通书架默认 false。
  负向验证：把谓词改成「两边都收漫画」→ 互补性用例转红，已还原。
  另 `hibiki/test/pages/manga_hibiki_page_test.dart` 新增
  `窗口 generation 闸门丢弃旧文档回调` 一组（BUG-1153 守卫补强，见下）。
- **备注**：BUG-1153 的原守卫只验「HTML 里写了 generation」，不验丢弃。本轮把丢弃
  判据提成纯函数 `MangaWindowGeneration.parse/isCurrent` 并补了行为断言（迟到旧
  generation / 对不上号 / 解析失败一律 fail-closed）。负向验证：把闸门放宽成
  `<= current` → 两条用例转红，已还原。
