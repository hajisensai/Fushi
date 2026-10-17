## BUG-3483 · 详情页分区头 trailing 按钮不贴右缘（剧集多选 ✕ 位置歪）
- **报告**：2026-10-16（用户：Android 在线视频源作品页进多选后，「剧集 13」标题行的 ✕ 落在行中偏右的半空里，没贴右边；反馈 `GWal_-1tfs` 截图一）
- **真实性**：✅ 真 bug。`MediaDetailSectionHeader.build`（`fushi/lib/src/media/detail/media_detail_kit.dart`，修前 1139–1173 行）是 `Row[Flexible(标题), 计数胶囊, Spacer(), trailing]`：`Flexible`（flex 1）与 `Spacer`（flex 1）平分剩余宽度，松约束的短标题用不完自己那一半也不让出来，`Spacer` 只拿到另一半，trailing 于是停在「标题区那一半」的末尾。按截图换算（384dp 宽、页边 20dp）：剩余 260dp、各 130dp，✕ 落在约 238–278dp，与截图实测吻合。所有用 `MediaDetailSectionHeader` 且带 trailing 的详情页（在线视频 / 漫画 / 小说作品页）都受影响，标题越短越歪。
- **[x] ① 已修复** — 标题 + 计数胶囊收进一个 `Expanded(Row(...))`，去掉 `Spacer`，trailing 直接排在 `Expanded` 之后贴右缘；长标题仍在 `Expanded` 内省略。
- **[x] ② 已加自动化测试** — `fushi/test/media/detail/media_detail_section_header_test.dart`（短标题 + 计数胶囊时 trailing 右缘 == 分区头右缘；长标题省略不溢出、trailing 仍贴右）。
- **备注**：同批反馈的另外两项（扩展源下载任务误标「配对设备」、任务页删除连同文件）已在 upstream develop 的 PR #2082（`5e081975c6`）落地，本条不重复处理。
