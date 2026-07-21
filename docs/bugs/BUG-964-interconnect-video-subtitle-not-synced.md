## BUG-964 · 互联视频live push不带外挂字幕
- **报告**：2026-07-21（用户：「hibiki互联 字幕好像没同步视频」）
- **真实性**：✅ 真 bug。互联视频 live push（`syncVideoFiles`）只上传视频文件本身：
  `hibiki/lib/src/sync/sync_orchestrator.dart` `_syncVideosLive` 仅调 `putRemoteVideo`，
  server 端也没有任何字幕上传端点（`hibiki_sync_server.dart` videos suffix 路由中
  `subtitle` 只收 GET，非 GET 405）。于是 client 推给 host 的视频，其外挂字幕
  （sidecar `.srt/.ass/.ssa/.vtt`）留在原机；其它设备从 host 串流/下载这条视频时
  `resolveVideoSubtitle` 找不到 sidecar → 无外挂字幕、无法查词（内嵌字幕轨在容器内
  不受影响）。下载方向（host→client）本来就通（`hasSubtitle` →
  `getRemoteVideoSubtitle` → 解析 cue），唯独上传方向整段缺失。
- **[x] ① 已修复** — 上传方向补齐整条链：
  - 纯函数 `listSidecarSubtitles` / `isSidecarSubtitleSuffix`
    （`hibiki/lib/src/media/video/video_sidecar.dart`）：枚举视频全部同 stem sidecar
    + 字幕后缀白名单（拒路径穿越）。
  - host `importVideoSubtitle`（`app_model_library_host_service.dart`）：sidecar 落
    视频同目录 `<host 视频 stem><suffix>`（`resolveVideoSubtitle` 天然可见），再按
    学习语言重解析首选 sidecar（多字幕推送顺序无关、收敛），镜像下载路径行语义
    （`subtitleSource`/`subtitleFormat`、`embeddedSubtitleTrack=null`、cue 落库）。
  - server 新增 `PUT /api/library/videos/<id>/subtitle`（后缀走
    `X-Hibiki-Subtitle-Suffix` header，400/404 语义化拒收）。
  - client `putRemoteVideoSubtitle`：404/405（老 host 无端点）返回 false 不抛。
  - `_syncVideosLive`：视频本轮上传 ⇒ 其全部 sidecar 一并推（不挑语言，host 端自己
    按学习语言解析首选）；host 已有视频但清单 `hasSubtitle=false` ⇒ 只补推字幕不重
    传视频；host 已有任一 sidecar ⇒ 跳过（幂等）；老 host 首个 405 后停止本轮后续
    字幕推送并在 report.errors 记一条可见提示（与合集端点缺失同纪律）。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/interconnect_video_subtitle_sync_test.dart`
  （7 例）：纯函数匹配/白名单；host 落位+行语义+cue+可见性、未知视频/非法后缀拒收；
  端到端视频连同全部 sidecar 推送 + 首选按 ja 解析、重复 sweep 幂等（mtime 不变）、
  缺字幕补推不重传视频；老 host 405 降级返 false 不抛。
- **备注**：v1 粒度与视频同尺寸跳过一致——host 已有任一 sidecar 即不再推（后加第二
  语言字幕、改字幕内容不会自动重推）；多集播放列表本就不在
  `_isUploadableLocalVideo` 范围（单文件资产模型），其字幕同样不在本批范围。
