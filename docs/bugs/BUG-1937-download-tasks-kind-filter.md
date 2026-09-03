## BUG-1937 · 下载任务面板缺少类型筛选
- **报告**：2026-08-29（用户：「下载队列缺少类型筛选和排序，我记得改了这个问题来着」）
- **真实性**：✅ 真 bug（一半）。排序在 PR #931 已做（`video_download_jobs_panel.dart` `VideoDownloadJobSort` 四维：添加时间/名称/进度/状态），用户记得的是它；**类型筛选从来没有**——全历史 `git log -S mediaKind -- video_download_jobs_panel.dart` 只命中 #794 的原始落地，面板工具条只有搜索框 + 排序菜单。`video_download_jobs.mediaKind` 的值域按 organizationPolicy 分治（`video_download_pipeline_service.dart:906`：视频任务 `VideoMetadataMediaKind.name`，发现域手动任务 `DiscoveryMediaKind.name`），数据早就带类型，只是 UI 没暴露。
- **[x] ① 已修复** — `2e25d45775`：`VideoDownloadJobKindFilter` 六档（全部/视频/小说/有声书/游戏/漫画）+ 纯函数 `filterVideoDownloadJobsByKind`（判据 `DiscoveryMediaKind.values.asNameMap()[mediaKind]`，查不到即视频——不写 movie/tv 白名单，历史/未知值不会被筛成两头不属的幽灵）+ 工具条图标菜单（筛选中换 `filter_alt` 主色，tooltip 报当前档）。工具条改成按宽度分行（`_kToolbarSingleRowMinWidth`=480 以下搜索框独占一行、筛选/排序靠右另起一行）：360 逻辑像素宽的单行原本只剩几十像素余量，测试字体 Ahem 下更宽，加任何控件必右溢出。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_download_jobs_panel_test.dart` `kind filter (BUG-1937)` 组：纯函数六档（tv/movie/未知值归视频，四发现域精确匹配，六档标签互异）+ 菜单选「游戏」只剩游戏任务、筛到空给「没有匹配」空态、切回全部恢复 + 360 宽工具条不溢出。
- **备注**：筛选/排序都是会话级、不落偏好（与 #931 的排序同一纪律）。
