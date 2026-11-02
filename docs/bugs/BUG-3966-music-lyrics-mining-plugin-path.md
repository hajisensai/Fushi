## BUG-3966 · music-lyrics-mining-plugin-path
- **报告**：2026-11-02（用户：应用内反馈 jrT0LdK8ax）——在线音源插件曲目在歌词页制卡失败「sentence audio export failed」。
- **真实性**：✅ 真 bug。`_MusicLyricsPageState.onMineFromPopup`（`fushi/lib/src/pages/implementations/music/music_lyrics_page.dart` 原 506）把 `item.path` 直接交给 ffmpeg；插件曲目的 path 是 `fushi-music-plugin://<插件>/<曲目>` 逻辑占位（`music_plugins.dart` `isMusicPluginPath`），ffmpeg 打不开。播放侧有 `resolveMusicMedia`（`mpv_music_output_backend.dart` 126）统一解析逻辑路径，制卡侧绕过了这层。
- **[x] ① 已修复** — 新增制卡边界解析器 `resolveMusicClipSource`（`fushi/lib/src/media/music/music_clip_source.dart`）：插件曲目经 `resolveMusicPluginStream`（与播放同一个取流真相源）拿流 URL + 请求头；本地文件 / CUE 曲目沿用原路径与文件内偏移；`cdda://` / 光盘章节路径明确报不支持；取流失败抛带原因的 `MusicClipSourceUnavailable`。歌词页制卡改用解析结果，`MusicLyricsClipExtractor` 增加 `httpHeaders` 参数一路传给 `TtsChannel.extractAudioSegment`，解析失败返回带原因的 `MinePopupResult.failed`。（未提交）
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_clip_source_test.dart`（插件取流 URL + headers、取流失败带原因、本地 / CUE 偏移、CD / 光盘章节不支持）；`fushi/test/pages/music_lyrics_page_test.dart` 断言本机曲目原样交出、无请求头。
- **备注**：收藏批量制卡里没有音乐音频分支（只走文本路径），本轮无需改；真实插件流的 ffmpeg 裁剪（含 403 / 过期）未在真机验证。
