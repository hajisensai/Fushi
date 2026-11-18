## BUG-4806 · 互联视频同步：host 已有的视频本地文件不在时每轮都报一条 local file missing
- **报告**：2026-11-17（优化计划第一波 c20 / gap-remote-8，代码审查发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/sync_orchestrator/videos.part.dart:375`（修前）：`_syncVideosLive` 里「本地文件不在就记错并跳过」排在「host 是否已有」的判断之前。视频放在移动硬盘 / NAS 上、盘没挂时，库里每个本地视频每一轮同步都报一条 `local file missing`，包括早就传过、host 已有、本轮根本无事可做的那些。同一处的存在性判断是同步 `existsSync`，`:496` 的 sidecar 目录列举是 `listSync`，都跑在主 isolate 上。另外同一轮里 `_syncVideosLive` 与 `_syncVideoProgressLive` 各取一次 host 视频清单（`:65`、`:341`），没有上传时第二次是重复请求。
- **[x] ① 已修复** — 提交 `17049337570`。文件不在时：host 已有 → 静默跳过；host 没有 → 保留原报错（真的传不上去）。存在性判断换成已有的异步 `hasLocalSingleMediaFile`，sidecar 列举改异步 `list()`。`_syncVideosLive` 在「本轮没有任何东西要推」时把取到的 host 清单交回，`sync_orchestrator.dart` 传给 `_syncVideoProgressLive` 复用；推过东西就重取（进度排在上传之后，就是要上传之后的清单）。审查后补（提交 `a3c1635b0c1`）：交回的清单带年龄（从发出清单请求起算），超过 `kHostVideoListReuseMaxAge`（2 秒）也重取——文件阶段在休眠的盘上会拖数秒到数十秒，进度的三方判定要 host 当下的断点。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_orchestrator_live_video_test.dart`：「host 已有的视频本地文件不在（盘没挂）：不报错；host 没有的才报」「一轮里没向 host 推任何东西：host 视频清单只取一次；推过或清单超龄则重取」（真 server / host / client 端到端）。
- **备注**：阻塞时长没有实测（需要会休眠的网络盘）；云后端分支 `syncVideoAssets` 本来就用异步判断，不在本条范围。
