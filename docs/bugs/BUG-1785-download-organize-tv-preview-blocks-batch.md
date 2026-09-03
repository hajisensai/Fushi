## BUG-1785 · TV 整理被无集号特典文件整批卡死
- **报告**：2026-08-23（用户：`unable to determine episode number: [VCB-Studio] Hibike! Euphonium 2 [Ma10p_1080p]\Previews\[VCB-Studio] Hibike! Euphonium 2 [WEB Preview02][Ma10p_1080p][x265_flac].mkv`，种子 100% 完成后卡在「整理」任务出错）
- **真实性**：✅ 真 bug。根因：`fushi/lib/src/media/video/download/video_download_organizer.dart` 的 `plan()` 中 episodic 分支对**每一个**视频文件硬解析集号，解析不出直接 `throw FormatException`，整批整理失败；movie 分支却有 Extras 兜底（非正片全进 `Extras/`）。VCB-Studio 类 BDRip 标配 `Previews/`、`SPs/`、`Menus/` 目录，预告/特典/菜单天生无集号（`[WEB Preview02]`、`[NCOP]` 均不匹配纯数字集数块），一个特典文件即拖死全部正片入库。
- **[x] ① 已修复** — episodic 与 movie 共用同一条 Extras 规则：认得出集号的进 `Season NN/`，其余镜像种子内目录结构（剥共享发布根目录）进 `Extras/`——路径天然唯一，不同子目录同名特典不互顶；下游 `kind: 'extra'` 是既有概念，直接兼容。一集都认不出仍显式失败（kind 误标不静默入库）。同时把 `p.basename` 换成平台无关切段（内置引擎在 Windows 报 `\` 分隔路径，Linux 上 `p.basename` 不认）。提交：见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`：VCB 布局（正片 + Previews/SPs 特典 + 反斜杠路径）出计划不抛错、特典镜像进 Extras；全无集号仍失败的既有用例保留。
- **备注**：与 BUG-1784 同一条用户报告链（同一批響け！ユーフォニアム下载任务）。
