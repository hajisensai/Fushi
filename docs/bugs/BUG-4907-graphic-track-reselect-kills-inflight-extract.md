## BUG-4907 · 图形字幕整轨抽取跑到一半时重新选同一条图形轨，会把 ffmpeg 杀掉从头再抽
- **报告**：2026-11-20（BUG-4803 审查时记下的「已知未修」，路线图 #3722 c19 遗留 → c32；非用户反馈）
- **真实性**：✅ 真 bug（读代码确证）。根因（基准 `7745effa2e`）：
  - `fushi/lib/src/media/video/video_player_controller.dart:2009`（修前行号）：`selectEmbeddedGraphicTrack` 一进来就 `_resetGraphicTimingTables()`，不区分「换了一条轨」与「还是同一条轨」，撤销在途抽取并清空两张时间表。
  - BUG-4803 之后 loader 按等待者计数：没开「模糊」档时控制器是唯一等待者，它一撤，抽轨进程就被杀；隔几次 mpv 调用后才 `_loadGraphicSubtitleTimings` 重新发请求，开的是新任务——整文件从头再读一遍。已抽完的时间表也被清空，再选同一条又抽一遍。
- **[x] ① 已修复** — 选轨路径先判「重新选的是不是当前那条轨」（图形模式在场 + 同序号 + 同 codec + 同一个原盘标题代次 + 同一份取数来源；换片 / 关字幕 / 切文本字幕都会先把图形模式置 false，所以不用另比 load 令牌）：是就不清 cue、不复位时间表，原生下发照常重做；末尾抽取在途或已有结果时不再发请求，两者都没有（上次没取到）才再要。新增 `_graphicSubtitleDiscGeneration` 记选轨时的原盘标题代次。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_handles_test.dart`「重新选同一条图形轨」组（假 `PlatformPlayer` + 假 loader，走真 `selectEmbeddedGraphicTrack`）：在途时再选同一条——取消信号不触发、loader 只收到一次请求、结果照常落地；换另一条轨——旧抽取撤销、按新轨重抽；已抽到后再选同一条——表保留、不重抽。修前前后两条都红。
- **备注**：
  - 真机未验：Windows 上放带 PGS 轨的大 REMUX，不开模糊档，选图形轨后在抽取完成前再选一次同一条，数 `ffmpeg.exe` 进程不应重启。
