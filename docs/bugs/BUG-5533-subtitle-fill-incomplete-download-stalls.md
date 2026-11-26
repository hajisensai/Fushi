## BUG-5533 · 整库补字幕遇到没下完的视频，每集卡到 5 分钟停滞超时才失败
- **报告**：2026-11-26（整库补字幕首次实跑：前 8 集全部失败，每集约 5 分钟）
- **真实性**：✅ 真问题。复现：用户库里 `D:\APP\HIBIKI_date\documents\anime_downloads\content\hibiki\[BDMV] [JPN] Hibike! Euphonium (Sound! Euphonium) - Season 1\Vol1–3` 是旧本机 BT 下载留下的半截文件（`00001.m2ts` 从 32 MB 起抽样全是 0，预分配空洞；`video_download_jobs` 里没有对应任务，app 无从知道它没下完），却作为 25 集原盘成员在库里。补字幕对每集依次：PGS 轨抽取失败 → 无刮削集号不下载 → ASR 抽音频 ffmpeg 在零区间报 `max resync size reached, could not find sync byte` 并停滞，直到 `kVideoSubtitleAudioStallTimeout`（`packages/fushi_engine/lib/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart` `extractVideoSubtitleAudio`）返回 exit null。参数改写本身无误（`prepareBlurayFfmpegArgs` 生成的 concat 清单单独跑前 10 秒成功）。
- **[ ] ① 未修复** — 两层：(a) 库层：没下完的媒体不该以正常条目存在 / 应可识别（旧下载路径留下的数据，至少在资源检查里能标「文件不完整」）；(b) 补字幕：同一份底层媒体（同一 m2ts / 同一文件）抽取已判定不可读时，后续条目直接记失败，不再各自等满停滞超时。实跑时的临时处理是先抽样扫出零填充文件，从任务范围里排除。
- **[ ] ② 未加自动化测试** — (b) 可在 `library_subtitle_fill_test.dart` 用假 host：同一底层文件第一次 generate 抛「不可读」，断言后续同文件条目不再调用 host。
- **备注**：抽样判据（24 个 64 KB 块中 ≥25% 全零）只用于这次手动排查，不建议直接搬进产品当判据。
