## BUG-5201 · drift 行映射（`$Table.map`）仍在 UI isolate 上，大库查询回来逐行构造数据类卡帧
- **报告**：2026-11-22（BUG-5197 视频合集 / 页面切换卡顿排查中发现的遗留）
- **真实性**：✅ 真问题。`NativeDatabase.createInBackground` 只把 SQL 执行放后台 isolate，结果行回到 UI isolate 后由 drift 生成的 `$Table.map` 逐行构造数据类。1.6 万条视频的库上 VM CPU 采样：`$VideoBooksTable.map` ≈ 17 ms、`$StudySegmentsTable.map` ≈ 15 ms，落在视频页 / 首页切换的帧里。全表加载入口：`packages/fushi_core/lib/src/database/database_prefs_media.part.dart:611` `allVideoBooks()`，调用方见 `fushi/lib/src/models/app_model.dart:1501`、`media_sources_view.dart:2163` 等。
- **[ ] ① 未修复** — 方向：把「全表加载 + 聚合」挪进 DB isolate（`computeWithDatabase`）或 Rust 胖核心，UI 只收聚合后的结果；不要在 UI isolate 上持有全表行。
- **[ ] ② 未加自动化测试** —
- **备注**：同类：`fushi/lib/src/media/sources/reader_fushi_source.dart:107` `fushiBooksProvider` 整体 `ref.watch(appProvider)`，任意 AppModel `notifyListeners` 都触发 `getBooksFromDb` 整表重载 + UI isolate 行映射；改成只依赖真正影响书架的信号前要先盘点所有刷新入口（BUG-793 / BUG-4356 已有专用 key provider）。跨 fushi_core / app 多模块，单独做。度量用 `fushi/integration_test/video_collection_perf_itest.dart` + `helpers/ui_cpu_profile.dart`。
