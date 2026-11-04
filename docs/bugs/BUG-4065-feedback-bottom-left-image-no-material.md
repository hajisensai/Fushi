## BUG-4065 · 歌词模式左下角插图卡不自动收起
- **报告**：2026-11-04（开发者反馈 yR5QF92EHO「左下角的图片应该会自动消失」，Windows）
- **真实性**：✅ 真 bug（首次拉材料失败未定位；重新拉到日志：阅读器有声书歌词模式 `ReaderDiag lyricsMode=true`）。左下角是歌词模式插图卡 `LyricsIllustrationPopupCard`（`lyrics_illustration_view.dart`，alignment bottomStart）。弹出和收起不成对：顺着播放走过插图时 `LyricsIllustrationController.observe`（`fushi/lib/src/media/audiobook/lyrics_player/lyrics_illustrations.dart`，修前 `:434` `_cardOpen = autoOpenCard`）就把卡弹出；唯一的自动收起是「停留」结束时的 `closeCard`（`fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart`，修前 `:1306`），它只在停留真正开始后才挂监听。非连续播放（修前 `:1281` `if (!continuous) return;`，如 ±10 秒 / 跳句跨过插图）、「图片暂停」0 秒或阅读器不可见（修前 `:1292` `if (!ctrl.isImagePaused) return;`）都提前返回，卡永久留在左下角。
- **[x] ① 已修复** — 状态机自己负责卡的生命周期：`observe` 弹卡时按 `kLyricsIllustrationCardAutoClose`（5 秒展示时长）起计时、到点 `closeCard`（插图位留缩略图 + 提示点）；页面真正开始停留时调 `holdCardOpen()` 交给停留结束收卡（原有路径）；用户翻看插图（`showAt`）、手动关卡、回封面、重新装载、往回 seek 收回、`dispose` 都作废计时；红点模式不弹卡也不计时。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_illustrations_test.dart`「插图卡自动收起」组（fakeAsync）：没有停留时到点收卡且插图位仍是该插图；`holdCardOpen` 后不再按时长收；翻看 / 关卡 / 回封面 / 重装 / dispose 作废计时；红点模式不计时。
- **备注**：5 秒展示时长是本轮自定的默认值（没有现成偏好）。未在桌面实机复测（本轮不做真机验证）。
