## BUG-1174 · 封面刮削/匹配失败被静默吞掉，用户只看到「无结果」
- **报告**：2026-07-28（来源：PR#477 独立审查第 6 条意见，当时判定不在该 PR 范围内，单独跟进）
- **真实性**：✅ 真 bug。视频「在线匹配海报」弹窗把搜索异常整体塌缩成空列表，界面渲染
  `video_scrape_no_results`（「无匹配」）——网络断了、Bangumi 返回 503、TMDB key 无效，
  用户看到的都是同一句「无匹配」，既不知道该重试还是该换关键词，也拿不到任何可上报的原因。
  根因 `file:line`（基底 `5af29b2da`）：
  - `hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:133`（Bangumi URL 直取
    `catch (_) → results = []`）、`:157`（关键词搜索 `catch (_) → results = []`）：失败与
    「零结果」共用同一出口，且 `_buildResults` 只有 `_searching` / 空态两种分支，**根本没有
    失败态**。
  - 同文件 `:185` / `:190`（数字关键词双路：`searchCandidates().catchError(→[])` +
    `fetchBangumiCandidateById` `catch (_) → null`）：**两路都失败时** `_searchSource` 返回
    空表而**不抛**，于是连上面的失败态也够不着，必然显示「无匹配」。
  - `hibiki/lib/src/media/metadata/book_cover_scrape_dialog.dart:117`（数字关键词直取
    `catch (_)`）：这一路本身是可接受的尽力而为降级（同函数里的关键词搜索未 guard，真失败
    会冒泡成可见失败态），但没有任何取证出口。
  - 三个弹窗的**全部** catch 都不落日志：即使界面提示了「失败」，用户与开发者都无从知道
    为什么失败。书籍弹窗虽已有 `_searchFailed` 错误行，但同样只说「失败了」。
- **[x] ① 已修复** — `2026-07-28`，逐处判「该报还是该吞」：
  - **该报**（video）`cover_match_dialog.dart`：新增 `Object? _searchFailure` 单一失败态
    （替代 bool+空表塌缩），两处搜索 catch 落 `ErrorLogService.instance.log` 并置失败态；
    `_buildResults` 新增 `_buildSearchFailure` 错误行（error 图标 + 标题 + 可行动原因），
    与书籍弹窗同风格；数字关键词双路改为「一路失败＝降级（`logDiagnostic` 留痕、界面不打扰）、
    两路都失败＝带原始栈 `Error.throwWithStackTrace` 重抛」，消除「两路都炸也显示无匹配」。
  - **该报**（video）应用封面失败：原本已 toast，补 `ErrorLogService.log` + 在 toast 里追加
    可行动原因。
  - **保留静默 + 写明理由**（video）`onApplied()` 回调异常：界面吞掉（刷新回调失败不该拦住
    「已应用」和关弹窗），但补 `ErrorLogService.log`，否则「封面应用了、库页没刷新」永远查不出。
  - **该报**（book）`book_cover_scrape_dialog.dart`：`_searchFailed` 改为 `Object? _searchFailure`，
    搜索失败与封面下载失败各补 `ErrorLogService.log`，错误行/toast 追加可行动原因。
  - **保留静默 + 写明理由**（book）数字关键词直取 `catch`：注明「这是尽力而为的第二路，
    同函数的关键词搜索未 guard，真失败仍会冒泡成可见失败态」，并补 `logDiagnostic`。
  - 可行动原因只做**数据支持得起**的二分：领域异常有无 `statusCode` = 「没拿到可用响应」
    （`scrape_reason_network`）vs 「拿到了但对面报错」（`scrape_reason_server`）。不做
    「网络/格式/占用」这种下层已被压平、猜出来就是撒谎的假分类；技术细节只进错误日志。
  - 新增 i18n key（走 `tool/i18n_sync.dart` + `dart run slang`）：`video_scrape_search_failed`
    / `scrape_reason_network` / `scrape_reason_server`。
  - 未引入任何新弹窗：沿用页面既有的结果区状态行 + `HibikiToast` + 错误日志。
- **[x] ② 已加自动化测试** — widget 行为层：
  - `hibiki/test/media/video/scraper/cover_match_dialog_test.dart`：「搜索失败出可见错误行
    （非「无匹配」）+ 可行动原因 + 落错误日志，且可重试」「源站带 HTTP 状态码时给出「源站报错」
    而非「检查网络」」。
  - `hibiki/test/media/metadata/book_cover_scrape_dialog_test.dart`：「搜索失败带可行动原因 +
    落错误日志」「源站 HTTP 500 给出「源站报错」而非「检查网络」」。
  - 负向验证：把两处 `_searchFailure = failure` 改回静默（置 null），定向套件由 8 passed
    变成 3 passed / 5 failed；还原后重新全绿。
- **备注**：本条是「失败没有出口」这一系统性形态的末梢（同批还有 OCR 降级静默、测试 exit 0
  但零测试、`assert` 在 release 被剥离等）。修复守住的行为契约是：**搜不到 ≠ 搜不了**，
  两者在 UI 上必须可区分，且失败原因必须有一个用户可查、可上传的落点。
