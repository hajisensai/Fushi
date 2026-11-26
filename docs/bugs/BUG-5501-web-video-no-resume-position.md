## BUG-5501 · PC 上 YouTube 不登录就记不住观看进度（网页档只写进度不读）
- **报告**：2026-11-25（用户：应用内反馈 2ajU2PuEDA，PC 端「在 Fushi 观看」YouTube，不登录账号每次从头）
- **真实性**：✅ 真 bug（沿真实代码路径确认，未在 Windows 真机复测）。网页档每秒把播放头写进这一集书的 `lastPositionMs`（`fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart` `_persistWebPosition` → `_persistPosition`），但打开时 `_initWebSource` 只在制卡重放换回来（`widget.webReturnState`）时建恢复，其余情况从不读 `lastPositionMs`，`VideoPlayerController.loadWeb` 也没有起播位置参数；站内换到已看过的一集（`_bindWebEpisode`）同样不读。于是续播只能靠站点账号书签。反馈 AI 总结指向的 `web_video_fushi_page.dart` 在 #4400 后只当制卡重放宿主，用户实际走的是原生播放器页网页分支。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/web_video_resume.dart` `WebVideoResumeSeek`：按书的 `lastPositionMs`（≥ `kWebVideoMinPersistPositionMs`）建，首个「是这一集、非广告、有视频、位置已知」的站点快照到来时一次性决定：站点从片头起播（<5 s）才 seek 到记下的位置；站点已自己续播（`t=` / 账号书签）、站内已去别的视频、进度离片尾不足 10 s 都不动。`_initWebSource` 打开某一集的书、`_bindWebEpisode` 新一集落书两处建，`_onWebState` 每拍过一次 `_applyWebResumeSeek`；制卡重放恢复在途时让给它。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/web_video_resume_test.dart`：无进度不建、片头起播 seek 一次且只一次、广告 / 无视频 / 位置未知时等待、站点已续播不覆盖、站内别的视频不套用、片尾不续播；网页分支两处建 + 每拍判定的源码守卫。
- **备注**：没在 Windows 真机上复测（需要 WebView2 Windows 包 + 真实 YouTube 播放）。
