## BUG-4791 · 视频「搬家」判定只凭同名 + 旧文件不在，删旧剧再放进同名新文件会把旧行错绑到新文件
- **报告**：2026-11-17（nmv 优化清单 gap-scanner-1，代码路径复核时发现，非用户实报）
- **真实性**：✅ 真 bug（代码路径逐行走通，未在真机复现）。BUG-2979 引入的 `isVideoRowMovedTo`（修前 `fushi/lib/src/media/source_library/source_library_scanner.dart:2967-2982`）全部判据是反证：不是清单 / 流、不是 URL、路径不同、basename 相同、旧盘在线、旧文件不存在——没有任何一条说明「新文件就是旧文件」。而视频 uid 只由文件名派生（`packages/fushi_engine/lib/media/video/video_library_import.dart:39-42`，刻意的跨设备身份），app 内扫描又有意不回收已删文件的行（BUG-4055 选 B），所以「同名旧行的文件不在了」是常态：
  - `A/01.mkv` 入库 → 库外删掉 → 放进 `B/01.mkv` → 扫描：`rowByUid['video/01']`（修前 `:2479-2481`）取到 A 行，判成搬家，A 行被改指到 B 的文件（修前 `:2484-2499`），进度 / 看完 / cue / 合集全带过去；
  - A、B 的 `01.mkv` 都在库（B 是 `video/01 (2)`）→ 库外删 A → 重扫：A 的进度 / 看完 / 标签 / 合集被并进 B 行，A 行被删（修前 `:2501-2510`、`:2617-2660`）。
- **[x] ① 根因修复** — `1f9ad3f6a23`：搬家要**正证据**（`videoRowMoveEvidence`，取代 `isVideoRowMovedTo`）。规格缓存 `video_file_specs` 里探过旧路径时只比字节数（相等 = 搬家，不等 = 另一个文件）；没探过时比路径尾段——父目录名一致才允许把旧行改指到新路径。会删行的合并分支更严：要字节数相等，或父目录与再上一层目录名都一致（`VideoMoveEvidence.allowsMerge`）。证据不够时新文件照常新建一行、旧行原样不动。
- **[x] ② 自动化测试** — `fushi/test/media/source_library/source_scan_integrity_test.dart`「视频搬家判定要正证据」组（真实临时目录 + 内存库跑整条 `SourceLibraryScanner.scan`）：整棵目录挪位置后只剩一行且进度保留（BUG-2979 ② 欠的那条）；不同目录同名文件新建一行、旧行不动；规格大小不等不认、相等即认；同名集都在库时删一部不合并；两层尾段一致的 `X (2)` 残留并回一行。
- **备注**：没有规格缓存、且父目录名通用（`剧A/Season 01/01.mkv` 删掉后放进 `剧B/Season 01/01.mkv`）时，改指分支仍会把 A 行指到 B 的文件——路径尾段只比一层是计划拍板的口径（BUG-2979 的真实案例里新旧根不同、只有 `Season 03` 这一层必然相同）。根治要给视频记内容指纹（清单 gap-scanner-6，未立项）。待真机：桌面用真实视频库验一次「整部剧挪目录后重扫」不出重复卡。
