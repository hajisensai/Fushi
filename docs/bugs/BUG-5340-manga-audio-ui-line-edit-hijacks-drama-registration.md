## BUG-5340 · 登记的是广播剧 / 动画音轨时，app 内单句补回 / 保留候选会把登记悄悄换回合成成品
- **报告**：2026-11-23（合并审查 #4255 时发现，存量问题，非该 PR 引入）
- **真实性**：✅ 代码路径确认（未跑复现测试）。`mangaAudioEditTarget`（`fushi/lib/src/media/manga/audio/manga_audio_stores.dart:136-141`）登记的是广播剧时返回本机合成清单、`kind` 记 `drama`，只有 ctl 据此 409（`ctl_tts_support.dart` `requireLineEditableAudio`）；app 内的入口（单句候选保留 `keepMangaCandidate`、补回任务 `runMangaRenderJob` 的 lineRequests 分支、拿掉不读的句子，`manga_audio_render_service.dart:165/350/395`）不看 `kind`，照常改合成清单后调 `updateMangaAudioLine(s)`。广播剧也用 `kMangaAlignmentFormat` 登记（`manga_drama_track_service.dart:277`），段数与合成清单行数一般对不上，`updateMangaAudioLines`（`manga_audio_library.dart:146-157`）于是走「整份重登记」分支，把这一卷的登记从广播剧换成合成成品；行数恰好相等时则把合成句的路径写进广播剧登记，两份混在一起。
- **[ ] ① 未修复** — 待定行为：app 内入口在登记广播剧时是像 ctl 一样拦下（提示先整卷生成），还是只改合成清单、不碰库里的登记（`updateMangaAudioLines` 在登记的清单不是本次改的那份时不写库）。后者改动集中在一处，但用户改完听不到（播的是广播剧），需要维护者定。
- **[ ] ② 未加自动化测试** —
- **备注**：#4255（拍板 isATnQZ_eN-external）把外部导入清单改成原地改写后，广播剧是唯一「登记的不是本次要改的清单」的情形。
