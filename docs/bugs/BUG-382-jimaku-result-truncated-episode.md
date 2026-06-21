## BUG-382 · Jimaku 自动获取字幕结果项文件名单行截断，集数被省略号吃掉看不见
- **报告**：2026-06-21（用户：自动获取字幕(Jimaku)对话框搜索结果列表里每条文件名单行截断带省略号，番名都一样，区分集数的部分被吃掉，看不出是第几集；要求显示区域更大+换行）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart:341-342`（原 `JimakuCandidateList` 的 `ListTile.title` / `subtitle` 都用 `Text(..., overflow: TextOverflow.ellipsis)`，默认 `maxLines:1`，加 `dense:true`。番名相同的字幕文件名只有集数段不同，被单行 ellipsis 截在番名处，集数（第01話/E01）落在省略号之后不可见）。
- **[x] ① 已修复** — 结果项标题文件名改多行软换行：`title` Text 设 `maxLines:3 + softWrap:true + overflow:TextOverflow.fade`（去 ellipsis，超长才 fade 兜底），`subtitle`（罗马音番名）设 `maxLines:2 + softWrap:true + fade`；`ListTile` 改 `isThreeLine:true` + `contentPadding: EdgeInsets.symmetric(vertical:4)`（去 `dense`）让多行行高自适应、不裁切。只动 `JimakuCandidateList` 结果项，不碰筛选框/番名/搜索按钮/Flexible+ListView 滚动布局（保留 BUG-279 修复）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/jimaku_dialog_scroll_test.dart` 新增 `TODO-673: result title wraps (maxLines>1 + softWrap), episode visible`：用番名相同、仅集数（第01話/第02話）不同的长文件名候选，断言标题 Text `maxLines>1`、`softWrap==true`、`overflow!=ellipsis`，且 `第01話`/`第02話` 完整渲染可见。
- **备注**：TODO-673。纯 UI 截断修复。属视频子系统瞬态内容，已在 md3 守卫 allowlist。真机/模拟器复测原始失败路径待用户（需有效 Jimaku API key + 联网真实搜索结果）。
