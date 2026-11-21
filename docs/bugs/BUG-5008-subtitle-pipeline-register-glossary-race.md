## BUG-5008 · 字幕生成：一集登记抛错连带后面各集不登记；S0 期间保存的专名表被管线盖掉
- **报告**：2026-11-20（来源：路线图 `docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md` 的 gap-subpanels-7，c35 组；复核结论「部分成立，第 1 点被推翻」，只做「登记抛错不连带后面几集；保存看 `_active`」两点）
- **真实性**：✅ 真 bug，两处：
  - 登记：`fushi/lib/src/media/video/subtitle/app_video_subtitle_service.dart:1542`（基线 `origin/develop` 7745effa2e）在管线跑完后逐集 `await sink.register(...)`，没有逐集隔离。任何一集写库抛错（库被锁、条目刚被删等）都直接落进外层 `catch`，任务判失败，**后面已经导出成功的集全部不登记**——字幕文件在磁盘上，库里却没选上，播放页看不到。
  - 专名表：管线 S0 `packages/fushi_engine/lib/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart:762` 开头读旧表、`:786` 把生成的整张表写回。专名表编辑页的保存 / 重新生成（`app_video_subtitle_service.dart:1073` 的 `saveGlossary`、`regenerateGlossary`）不看有没有任务在跑，S0 期间用户存下的条目与 `userEdited` 标记会被 S0 的写回整个盖掉。
- **[x] ① 已修复** — 登记逐集 `try`：一集抛错记错误日志、继续登记后面的集，全部登记完再按第一处错误把任务判失败（原因照旧显示 / 给 CLI）。专名表：任务记下「已过 S0」（进度到 `glossary` 完成或更后的阶段），服务新增 `glossaryWriterFor(work, language)`；同作品、同语言、开了校对且还没过 S0 的任务在跑时，`saveGlossary` / `regenerateGlossary` 抛 `AppVideoSubtitleStartRefused(busy)`，编辑页显示「已有字幕任务在跑」，`ctl video subtitle-glossary --set` 回 conflict。过了 S0 管线只用内存里的表、不再写，编辑照常。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/video/subtitle/app_video_subtitle_service_test.dart` 的「BUG-5008 生成管线的失败隔离」组：整季两集、第一集登记抛错，第二集必须照样登记（修复前 `registeredBookUids` 为空）、任务判失败且带原因；识别停在半路（S0 之前）时同作品同语言的保存 / 重新生成被拒（修复前保存成功），普通话的表不受影响，任务结束后保存恢复。
- **备注**：`regenerateGlossary` 自身跑 AI 期间若有人新起一个生成任务，两边仍可能互相覆盖（重新生成不是登记过的任务）；窗口窄，记在 PR 遗留项。
