## BUG-4802 · 本集字幕面板多选：全选无视筛选、重搜不清勾选、多选态点行仍直接下载并关页、部分失败的原因与已落盘文件随关页丢失
- **报告**：2026-11-17（优化计划 W1 c23 / gap-subpanels-3：代码走查发现，五处都按代码路径确证，未经用户报告）
- **真实性**：✅ 真 bug（五处，同一个「多选」契约没立住）。根因均为修前行号：
  1. 全选 / 反选取全量：`fushi/lib/src/pages/implementations/subtitle_search_panel.dart:1635-1656` 用 `_candidates`，而列表显示的是 `:1519-1526` 按语言 / 类型 / 关键词筛过的 `filtered`。筛到「日语 · ASS」后点全选会把所有语言、所有来源的文件一起勾上，包括按次计配额的 OpenSubtitles。
  2. 重搜不清勾选：`_selectedCandidates` 只在 `:498-509`、`:1636-1655` 被改，`_search`（`:648-660`）与 `_selectSeries`（`:765-772`）都不清。换词重搜后批量栏仍显示上一轮的「已选 N」，点下载下的是已经不在列表里的文件。
  3. 多选态点行仍直接下载：`subtitle_version_group_list.dart:50` 的说明是「非空时列表进入多选态：点行只勾选，不再直接下载」，但 `:283-285`（文件行）与 `:70-78`（卡片）不看 `selectedIdentityKeys`，一律 `onPickCandidate` → 面板 `_downloadSource` → 宿主 `Navigator.pop`（`subtitle_workbench_page.dart:296`）。勾了几条后手滑点到某一行，页面关掉，勾选全丢。
  4. 部分失败的提示被关页带走：`subtitle_search_panel.dart:1058-1059` 先 `_showError('失败 N 条')` 紧接着 `onDownloaded(saved)`，宿主当场 pop；每条失败的原因在 `:1044-1047` 只 `debugPrint`，不带状态码、不进错误日志。
  5. 批量途中离开页面：`:1024` `if (!mounted) return;` 直接返回，已落盘的几条不回调，成了没人登记的孤儿文件。
- **[x] ① 已修复** — 提交 `74582918ebe`、`65aec9ab2c0`（审查后补：页面已关的判据）。
  - 面板（`subtitle_search_panel.dart`）：筛选结果收成 `_filteredCandidates()`，列表渲染与批量栏共用；全选 = 把看得见的全部勾上，反选只在看得见的范围内翻转，筛选只影响显示、不影响已有勾选。`_search` / `_selectSeries` 清空候选的同一个 `setState` 里清勾选。多选下载每落盘一条就经新回调 `onSubtitleSaved` 交给宿主并取消该条勾选；部分失败时（宿主接了该回调）不再调 `onDownloaded`，面板留着显示「N 项失败 · 原因（HTTP 状态码）」，失败的几条仍勾着可重试；每条失败经 `logSubtitleDownloadFailure` 进错误日志。页面已关时不再往盘上写，写盘期间关页的那一条删掉。「页面已关」的判据是 `_pageClosed`：`!mounted` **或**所在路由已不 `isActive`——只看 `mounted` 不够，`Navigator.pop` 当下宿主的 push future 就完成并读走了已落盘路径，而面板要等退场转场（约 300 ms）跑完才 dispose，这段时间里回来的下载仍会写盘、路径进一个没人再读的列表（`65aec9ab2c0` 补上）。单条下载 `_downloadSource` 用同一判据：页面已关不写盘、不回调宿主（宿主的回调是 `pop`，此时弹掉的会是底下那一页）。
  - 版本卡列表（`subtitle_version_group_list.dart`）：有勾选时点文件行切换勾选、点卡片只展开 / 收起。
  - 宿主：`SubtitleWorkbenchPage.open` 在路由外收 `onEpisodeSubtitleSaved` 的路径，关页（面板主动关 / 页头返回 / 系统返回）时由纯函数 `workbenchEpisodePaths` 与显式结果合并返回；存量对话框壳 `JimakuSubtitleDialog` 改成 StatefulWidget，「取消」带回已落盘的第一条。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_search_panel_reliability_test.dart`「BUG-4802 多选」组（筛选后全选只勾看得见的、反选不动看不见的勾选、重搜后批量栏消失；部分失败不关页、原因带 404、成功的取消勾选、已落盘路径逐条交给宿主；宿主没接回调时仍走旧出口；`workbenchEpisodePaths` 合并顺序；经 `SubtitleWorkbenchPage.open` 推页：部分失败后系统返回、返回值含已落盘路径；批量 / 单条下载途中返回、退场转场内才回来的那条不落盘且底下的页不被 pop；对话框壳部分失败后「取消」带回已落盘的第一条），`fushi/test/pages/subtitle_version_group_list_test.dart`「多选勾选」组新增三条（有勾选时点行只切换勾选、点卡片只展开；没有勾选时点行仍直接下载）。
- **备注**：
  - 对话框壳点遮罩 / 系统返回关闭时拿不到已落盘路径（单值出口、生产里已无调用方，只有测试在用），没有为它加 pop 拦截。
  - 作用域开关把本集面板换掉（`AnimatedSwitcher`）会让在跑的多选批量静默中止：已落盘的仍会带回，正在下的那一条不写盘，没有提示。
  - 桌面与手机各走一遍「Jimaku 搜索 → 多选 → 部分失败 → 返回播放页看字幕轨列表」的真机复测未做，见 PR 说明的待真机验证清单。
