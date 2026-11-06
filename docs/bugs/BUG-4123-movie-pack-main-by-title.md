## BUG-4123 · movie-pack-main-by-title
- **报告**：2026-11-05（用户：内置 AI 任务下载「孤独摇滚总集篇」，库里出现两个 Re:Re:）
- **真实性**：✅ 真 bug。任务身份是「ぼっち・ざ・ろっく！ Re:Re:」(AniList 171099)，选中的种子是 VCB 合集包 `BOCCHI THE ROCK! Re：／Re：Re：`（两部同包）。电影整理器把**最大视频**当主片改名成任务标题：Re：（4.42 GB）比 Re：Re：（3.47 GB）大，于是 Re： 被改名成 `ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv` 并绑上 Re:Re: 身份；真正的 Re：Re： 作为并列正片保留原名、自动识别也认成 Re:Re:。根因 `packages/fushi_engine/lib/media/video/download/video_download_organizer.dart`（旧 `mainMovie` = 按体量排序取首）与 `download_confirmed_identity.dart` `mainMovieDownloadFile`（下游字幕 / 入库标题 / 身份绑定同样只取最大）——「哪部是任务身份」从不看任务标题。
- **[x] ① 已修复** — 新增共用纯函数 `mainMovieFeatureIndex`：在并列正片里按任务标题尾部词元对齐找唯一匹配（对齐必须越过各文件的区分段、锚进共有前缀），找不出才退回最大文件；整理器与 `mainMovieDownloadFile`（三个下游调用点）都走它，各阶段认同一个主片。并列正片体量门槛仍相对最大视频，与「谁是主片」解耦。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`：真实文件列表下任务 Re:Re: → Re：Re： 文件改名为主片、Re： 镜像原名；任务 Re: 反向；标题对不上时退回最大文件。
- **备注**：已入库的错标数据需手动处理（删除本次任务的库条目后重下，或手动把 `ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv` 改回 Re： 身份）。
