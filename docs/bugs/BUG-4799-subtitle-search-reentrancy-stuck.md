## BUG-4799 · 本集字幕面板搜索可重入且无代次：迟到的旧一轮覆盖新结果；保存 key 抛错后搜索钮永久禁用；合集面板批量途中回车重搜清掉行状态
- **报告**：2026-11-17（优化计划 W1 c23 / gap-subpanels-5：代码走查发现，按代码顺序推出，未在真机上复现）
- **真实性**：✅ 真 bug（三处）。根因均为修前行号：
  1. 重入无代次：`fushi/lib/src/pages/implementations/subtitle_search_panel.dart:1326`、`:1341` 两个输入框的 `onSubmitted` 与 `:1159-1162` 的「显示全部集」直接调 `_search()`，不看 `_searching`（只有底部按钮 `:1686`、备选词 `:1253`、系列行 `:1200` 看）。`_search` / `_fetchCandidates` 全程没有代次（同文件的语言探测有 `_probeGeneration`、合集面板有 `_generation`）。先返回的一轮在 `:740` 把 `_searching` 置回 false，后返回的一轮在 `:878-895` 覆盖结果——最终显示的是「最后返回的」而不是「最后提交的」。
  2. 搜索钮卡死：`:649` 置 `_searching = true` 之后，`:665-670` 的 `endOfFrame` 与 `onApiKeyChanged` 在 `:673` 的 try 之外。`AppModel.setJimakuApiKey` 的偏好写与下载管线重建抛错时 finally 不执行，搜索钮灰到关页。
  3. 合集面板：`subtitle_collection_panel.dart:1600` 的 `onSubmitted` 不看 `_running`（同一面板的按钮 `:1608`、系列行 `:1476` 都看）。批量途中回车会重搜并 `_statusByUid.clear()`（`:958`）、换掉来源，在跑的批量继续用旧候选，行状态被清空后又被陆续写回。
- **[x] ① 已修复** — 提交 `74582918ebe`、`65aec9ab2c0`。`_search` / `_selectSeries` 在**提交时刻**（任何 await 之前）`++_searchGeneration`——Jimaku key 框为空时检索先 await 一次来源探测，代次若在它之后才分配，两次探测乱序返回时先提交的旧词反而拿到更大的代次（`65aec9ab2c0` 修正）；`_fetchCandidates` 接收代次，每个 await 之后与 finally 里都过 `_isCurrentSearch`（挂载且仍是最新一轮）才写状态：后提交的一轮顶掉前一轮，被顶掉的不落结果、不收转圈。`endOfFrame` 与 `onApiKeyChanged` 收进 try；本地故障（保存 key、建 HTTP client 抛错）进错误日志并在面板内提示。合集面板 `onSubmitted` 套上与「查找字幕」按钮相同的 `_resolving || _searching || _running` 条件。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_search_panel_reliability_test.dart`「BUG-4799 搜索代次」组（旧一轮先返回：不落结果、搜索钮仍禁用；旧一轮后返回：不覆盖新结果；保存 key 抛错：搜索钮恢复、面板内有失败提示；两次来源探测乱序返回仍是后提交的词赢），`fushi/test/pages/subtitle_collection_panel_test.dart`「BUG-4799 批量途中在输入框回车不重搜」。
- **备注**：慢网下连按回车的真机复现没做（需要可控的慢网络），靠 widget 测试用挂起的 provider 复现同一时序。
