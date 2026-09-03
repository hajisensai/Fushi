## BUG-1697 · 自动下载的字幕从不校验内容，整季合并文件被当成单集装上去
- **报告**：2026-08-17（用户：「看看能不能优化下准确率，要检测字幕时长之类的？」）
- **真实性**：✅ 真 bug。全仓四条自动配字幕路径（下载流水线 / 番剧下载反查 / 合集批量 / 订阅），**没有任何一处**在拿到字幕字节后看过内容——匹配全靠文件名，文件名对了就落盘。根因两处：
  - `fushi/lib/src/media/video/download/video_download_pipeline_service.dart:1759`（修前）`candidate = result.items.first;`——排序只按 provider 优先级与下载量（`deduplicateVideoSubtitles`），既不看集号是否真等于该文件的集号，也不看内容；
  - `fushi/lib/src/media/torrent/anime_download_subtitle_resolver.dart:_download`——下下来直接写盘。

  最典型的漏网形状：把整季合并成一个文件的字幕（5 小时）装到某一集（24 分钟）上，播放时从第 3 分钟起全错位；以及来源站返回 HTML 错误页被当字幕存下来。
- **[x] ① 已修复** — 新增两个模块：
  - `fushi/lib/src/media/video/subtitle/subtitle_timing_check.dart`（纯函数）：`summarizeSubtitleTiming` 只扫时间轴（srt/vtt 的 `-->`、ass 的 `Dialogue:`），不把整套 cue/DB 语义拖进来；`checkSubtitleTiming` 给出 ok / unparsable / empty / overrunsVideo / suspiciouslyShort 五态。
  - `fushi/lib/src/media/video/video_duration_probe.dart`：走既有 `FfmpegBackend.runProbe`，桌面 ffprobe 与移动 ffmpeg-kit 同一条路径。`VideoBooks` 没有 duration 列、播放器时长又只在 controller 打开后才有，下载期只能现探。

  两档拒收强度是刻意分开的：
  - `rejected`（**有备选**，下载流水线）：读不出/空/超长都换下一个候选，最多试 `kSubtitleVerifyMaxCandidates`=4 条，且复用校验时下的字节不重复下载；
  - `contradictsVideo`（**无备选**，番剧下载按集号已锁定唯一一条）：只认「字幕比视频长得多」这种正面矛盾。本模块的扫描器只认三种时间轴写法，「我读不出」不足以扔掉用户唯一的字幕。

  容差按时长来源分档：ffprobe 是精确事实（1.15×+60s），刮削 runtime 是播出时长含广告位、只精确到分钟（1.5×+2min）。比例 + 绝对量双保险，避免 5 分钟 PV 被比例项误伤。探不到时长时判据退化成只做内容自检，**绝不因为探测失败就拒收**。
  字节解码复用 `fushi_audio` 的 `decodeTextBytes`（BOM / UTF-16 LE·BE / CP932），不自己写一份——裸 `utf8.decode` 对 UTF-16 字幕会解出夹满 NUL 的垃圾串，把好字幕误判成坏字幕。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_timing_check_test.dart`（14 条）：三格式时间轴解析（含 ass 两位小数是厘秒）、整季文件拒收、signs/歌词轨不拒、时长未知只自检、两档拒收强度不可混用、刮削容差必须更宽、短片不误伤、ffprobe json 解析的各种 N/A。**已做变异实测**：把 `probed` 容差从 1.15 改成 99.0，套件从 PASSED 变 FAILED（2 处断言捕获），还原后 sha256 与变异前逐字节一致。
- **备注**：这道判据**抓不了轴偏移**（同一集不同压制组 OP 差几秒）——那要靠发布组名匹配。模块头注释里写死了这一点，防止后来者拿它当「字幕对轴校验」用。
