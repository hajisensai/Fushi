## BUG-1983 · Gal 同句换行快照未原地折叠导致换行错乱
- **报告**：2026-08-31（用户：「而且gal弹窗还有换行问题」；截图为 SiglusEngine 同一句台词的游戏内换行与 Hook 浮窗）
- **真实性**：✅ 真 bug。Gal 引擎会对同一句先吐连续文本、再按文本框重绘带换行的快照；`fushi/lib/src/sync/texthooker_line_fold.dart:85` 的渐进折叠刻意拒绝归一化后等长文本，`fushi/lib/src/sync/texthooker_service.dart:828` 因而把“字符完全相同、只改空白/换行”的后到快照追加成另一句。浮窗跟随最新项时会丢稳定 lineId/出现重复或采用错误的当前排版，字数也可能重复累计。
- **[x] ① 已修复** — `ad52944d70`：新增 `isWhitespaceOnlyLayoutRefresh`，仅在同一 Windows engineHook 端点/线程内把“去空白后完全相同、原文确有变化”的快照原地折叠；保留最早 lineId、采用后到原文和 ruby 坐标、字数增量为零。逐字相同的两次真实台词仍不折。
- **[x] ② 已加自动化测试** — `fushi/test/sync/texthooker_progressive_fold_test.dart` 覆盖纯换行刷新判据，并以截图同形的日文句验证只留一行、lineId 不变、后到换行被保留、学习字数不重复。同 PR 后续提交补齐负向覆盖：两句不同台词（含互为前缀的那种）不得被空白折叠、服务层两条短台词不得折成一条、以及极短行的排版刷新照样折。
- **判据下限的不对称是有意的**：`isProgressiveTextUpdate` 有 `kMinFoldableLength >= 4` 的下限，`isWhitespaceOnlyLayoutRefresh` **没有**。前者是**包含**判据（前缀/后缀），短串上假阳性率极高——任何长句都可能刚好以「はい」开头或结尾；后者是**等值**判据（去空白后逐字符相同），串多短都不改变「本来就是同一句」这个结论，没有可被短串放大的假阳性面。反过来给它补一个下限，只会让「はい」→「は\nい」这类真排版刷新漏折，在工作台上留一条重复短行——正是本条要消的症状。理由固化在 `texthooker_line_fold.dart` 的函数注释里，并有对应用例（变异实测：加上下限后该用例变红）。
- **顺带清掉一处死条件**：折叠循环里 `if (!layoutRefresh && normalizeForFold(tail.text).length > normalizeForFold(mergedText).length)` 的 `!layoutRefresh` 恒不影响结果——排版刷新两侧归一化后长度必然相等，严格 `>` 本就不成立。已删除并把注释改成如实说明「后到排版天然胜出」。
- **备注**：聚焦 Flutter 测试在执行任何 case 前被 `pdfium_dart` 原生资产下载超时阻塞；未在原始 SiglusEngine 启动路径做真实 Hook/换行 E2E，能力状态只能算 implemented_unverified。
