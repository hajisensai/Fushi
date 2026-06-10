## BUG-168 · 导入视频文件夹显示无视频(非递归扫描+缺m2ts)
- **报告**：2026-06-11（用户：TODO-050 飞书巡检表第63行）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_filename_parser.dart:210`（修复前 `listVideoFilesInDirectory` 用 `dir.listSync(followLinks: false)` 非递归只扫顶层）。
- **链路**：`VideoImportDialog._pickFolder`（`video_import_dialog.dart:338`）→ `listVideoFilesInDirectory(dir)` → `videos.isEmpty` → 显示 `t.video_import_folder_empty`「无视频」。用户视频通常按 `番剧/Season X/E01.mkv`、`电影合集/某电影/movie.mkv` 这类结构组织，顶层只有文件夹、没有视频文件；非递归扫描只看顶层 → `out` 恒空 → 误报「无视频」。次要：扩展名白名单漏蓝光常见的 `.m2ts` / `.mts` / `.vob`。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/video_filename_parser.dart`：`listVideoFilesInDirectory` 改 `dir.listSync(recursive: true, followLinks: false)` 递归遍历所有子目录（`followLinks: false` 防符号链接成环）；`kVideoExtensions` 增加 `.m2ts` / `.mts` / `.vob`。提交 e2dca0076。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_filename_parser_test.dart` 新增 `listVideoFilesInDirectory` group（用 `Directory.systemTemp` 临时目录真实文件）：递归扫嵌套子目录视频 / 顶层+子目录混合 / `.m2ts`+`.ts` 蓝光扩展名 / 无视频→空 / 不存在目录→空。撤回 `recursive: true` 即变红。提交 e2dca0076。
- **备注**：`groupVideosIntoPlaylists` 只按 `p.basename(path)` 文件名分组，不受目录深度影响，递归后分组语义不变（同名系列文件无论在哪个子目录都归一组，符合「导入文件夹找全部视频」预期）。`.ts` 扩展名修复前已在白名单，只是因非递归在子目录里扫不到。真机复测原始失败路径（选含嵌套视频的文件夹→不再显示「无视频」）待用户设备验证。
