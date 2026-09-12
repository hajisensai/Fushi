## BUG-2481 · 作品页 OCR 无进度显示；阅读器无识别范围显示；扩展无一键更新；源列表无按下载量排序
- **报告**：2026-09-12（用户：「ocr缺少进度显示」「同时加一个显示ocr出来的范围的按钮」「导入以后的扩展，加一个一键更新。还有根据下载量排序」）
- **真实性**：✅ 四项产品缺口。
  1. 作品页「识别本章 / 识别全部已下载」入队后只有一条 toast，任务跑没跑、跑到哪、排了几章全看不见（进度只在阅读器 HUD 里）。
  2. 阅读器 OCR 块是透明命中层，识别漏了哪块 / 框歪了无从看出。
  3. 扩展页只有逐条「更新」与「批量安装」（`installMany` 只装未装的）；已装扩展有更新要一个个点。
  4. 源列表只能上下箭头手排；仓库目录已有 `downloadCount`（GitHub release 计数）却没用来排源。
- **[x] ① 已修复** —
  - `MangaOcrJobRegistry` 加 `changes` 信号流 + `queuedDirectories(bookKey)`；作品页（`manga_series_page.dart`）订阅它挂到当前任务的事件流，章节列表上方出横幅「识别中 <章>：第 x/y 页 · N 章排队中」+ 取消，章节行副标题标「识别中 x/y」/「等待识别」，识别中 / 排队中的章不再出「识别本章」菜单项。
  - 阅读器工具栏加「显示识别范围」（`manga_ocr_boxes_toggle`）：body 挂 `ocr-boxes-visible`，`.ocr-box` 外描边 + 淡底、`.ocr-char` 虚线；当前文档改 class，重建文档由 `mangaWindowDocument(showOcrBoxes:)` 带上。会话内状态，不落偏好。
  - `MihonManager.installMany(upgrade: true)`：只动已装且仓库版本更高的（`hasMihonExtensionUpdate`，与角标同判据），`trustSigner: false` 让换签名的那条以 `SIGNER_NOT_TRUSTED` 进失败清单；扩展页「一键更新」按钮（`mihon_extension_update_all`）与批量安装共用 `_runBulk` 进度/结果框。
  - `MihonManager.sortSourcesByDownloads()`（纯函数 `mihonDownloadCountsByPackage` / `sortMangaSourcesByDownloads`：同包多仓库取最大、降序、无计数垫底、同分保原序）写穿 `sort_order`；源管理页搜索框旁「按下载量排序」按钮，目录快照为空时提示先刷新仓库。
- **[x] ② 已加自动化测试** — `test/media/manga/ocr/manga_ocr_job_registry_test.dart`（changes / queuedDirectories）、`manga_series_page_phase_c_test.dart`（横幅 + 行状态 + 取消）、`mihon_manager_install_test.dart`（upgrade 模式）、`mihon_sources_sort_by_downloads_test.dart`（纯函数）。
- **备注**：识别范围只画框不改几何，命中判定与平时逐字节一致。
