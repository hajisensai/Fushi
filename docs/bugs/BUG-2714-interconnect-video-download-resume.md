## BUG-2714 · 互联视频下载：切屏被杀后任务消失、下载中心看不到进度、续传不校验/同名串 part/公网下到 m3u8
- **报告**：2026-09-26（用户：所有者，Android 手机从已配对的 Windows 电脑下视频；「进度好像没」「切屏任务就没了」「fushi 不在前台下载任务就会中断，包括自动更新」）
- **真实性**：✅ 真 bug，五处根因：
  1. **进程保活缺失**：互联下载只活在内存里的 `InterconnectDownloadManager`（`fushi/lib/src/sync/interconnect_download_manager.dart`，原注释「前台服务通知为后续波次」），Android 切后台即杀进程，任务表整张消失；自动更新下载（`update_checker_download.dart` `downloadUpdateAsset`）同样没有保活。
  2. **重启后接不回**：没有任何持久化，`.part` 成孤儿，只有用户再点同一个标题才会续。
  3. **进度只在库页封面角上**：`remote_download_progress_badge.dart` 一个圆环，离开库页即不可见；下载中心（`downloads_page.dart` 任务链）不含本机互联下载，也无字节数。
  4. **续传不校验**：`interconnect_sync_backend.dart` `downloadRemoteVideo` 未带 If-Range / ETag，host `/stream`（`fushi_sync_server/video.part.dart`）也不发 ETag——host 换了文件时旧 part 后面直接拼新字节；落点 `home_video_page.dart` `_remoteDownloadDestination` 只按标题命名，同名视频（合集里的「第1話」）共用一个 `.part`。
  5. **公网下到播放列表**：`downloadRemoteVideo` 取流地址时带着播放画质档，host 开转码时签发 `hls.m3u8`，下载把播放列表存成 `.mp4`。
- **[x] ① 已修复** — 提交 b552ac782b8（PR #1677）
  - Android `DownloadKeepAliveService`（dataSync 前台服务 + 进度通知，`fushi/android/.../DownloadKeepAliveService.java`）+ Dart 门面 `platform/mobile/android_download_keep_alive.dart`（节流 / 去重）+ 多来源汇总 `platform/mobile/download_keep_alive_hub.dart`；互联下载、自动更新下载（及同 PR 接入的其它下载来源）各领租约，最后一个来源结束才撤服务。
  - 续传清单 `sync/interconnect_video_resume_store.dart`（与 `.part` 并排的 `.resume.json`，写入按落点串行、不挡传输）；视频页拿到远端清单后 `_resumeInterruptedRemoteDownloads` 自动接回（用户暂停过的以暂停态登记）。
  - 管理器加 `paused` 状态、字节进度、`pause` / `resume` / `discard`；下载中心新增「从配对设备下载」段（`interconnect_download_tasks_section.dart`），给「已收 / 总 (百分比)」与暂停 / 继续 / 重试 / 删除。
  - host `/stream` 发强 ETag（`videoFileEtag`）并认 If-Range；客户端视频与书共用 `.part.etag` 校验续传；没有 `.part.etag` 的旧 part 从头下（`/stream` 为了播放器 seek 必须接受不带 If-Range 的 Range，旧 part 无从校验）；下载恒取原片、非原容器直接报错；`cancelSignal` 中止保留 part。
  - 落点改 `<标题>.<id 短哈希>.mp4`（`remoteVideoDownloadFileName`）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_download_resume_test.dart`（暂停 / 继续 / 清单 / 下载中心条目 / 落点 / 保活）、`fushi/test/sync/interconnect_video_download_resume_test.dart`（真 host：206 续传、ETag 变更回 200、无侧车不续、转码 host 下载仍取原片、取消保 part）、`packages/fushi_engine/test/serve_file_with_range_if_range_test.dart`、`fushi/test/platform/android_download_keep_alive_test.dart`、`fushi/test/platform/download_keep_alive_hub_test.dart`。
- **备注**：未在真机上复测「切后台 → 下载继续 → 通知进度」与「杀进程 → 重开视频页自动续」；本机只编译了 Android debug 的 Java/Kotlin。老版本 host（不发 ETag）上视频下载不再续传（安全优先）。同一份日志里的互联同步 15 秒超时是另一根因（host 对端写入等本机整轮自动同步锁），单独 PR 处理。
