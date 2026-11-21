## BUG-5108 · manga-download-pause-waits-verify
- **报告**：2026-11-22（外部审计 HBK-AUDIT-046，Codex 2026-11-21 PR 审查，来源 PR #3795：「漫画下载暂停仍可能等完最后一次全章校验」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/download/manga_download_service.dart` `_download` 在全部页齐后逐页 `readAsBytes` + `mangaImageDimensions` 写 manga.json（修前 1263-1277 行），循环里不看中止令牌、也不与 `token.tripped` 赛跑；`_pauseWhere`（834 行起）要等 `active.done`，所以在校验阶段点暂停 / 取消，要等整章（几百页高清图）读完解完才返回。取页工作池 `pending.removeAt(0)`（修前 1230 行）头删，P 页一章共 P(P-1)/2 次元素搬移：本机 Dart 实测 P=1000 为 499500 次 / 1.5 ms，P=10000 为 4999 万次 / 131 ms，游标出队 0 次搬移、<40 µs（正常章节页数下影响很小，属于渐近问题）。
- **[x] ① 已修复** — 校验循环每页读前、读后都 `_throwIfCancelled`，解尺寸经 `_untilTripped` 与令牌赛跑（读页本身不赛跑、读完为止：赛跑会把仍开着句柄的读丢在后台，取消随即删章目录，Windows 上删有打开句柄的文件报 errno 32，半成品删不掉——本机 Dart 实测复现），暂停 / 取消立即按既有优先级收尾（暂停留页图、取消删半成品）；取页改为游标出队。解尺寸函数经构造参数 `pageDimensions` 注入（默认 `mangaImageDimensions`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_download_service_test.dart`「全章校验可被中止（HBK-AUDIT-046）」两条：解尺寸卡住时 `pause` 5 秒内返回、行 paused、只解了 1 页、恢复后不重取页即跑完；校验第 1 页时取消 → 只解 1 页、cancelled、半成品删掉。变异实测：撤掉校验循环的令牌检查与 `_untilTripped` 后两条都红。
- **备注**：游标出队是纯内部结构替换，没有单独的行为测试（行为由既有暂停 / 续跑 / 并发取页测试覆盖）。
