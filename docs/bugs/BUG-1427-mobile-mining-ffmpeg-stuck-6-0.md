## BUG-1427 · 移动端制卡链 FFmpeg 停在 6.0，上游已迁到 ffmpeg-kit-next (FFmpeg 8.1.2)
- **报告**：2026-08-02（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug（安全面）。Android / iOS 的制卡链走 `KitFfmpegBackend`
  （`hibiki/lib/src/media/video/ffmpeg_backend.dart:624`，进程内 ffmpeg-kit），
  vendored 包 `third_party/ffmpeg_kit_flutter` 版本 6.0.3，内含 **FFmpeg 6.0**
  （Lavc 60）。播放链已升 6.1.6（PR#685），桌面制卡链是自建 n7.1.5，唯独移动制卡链
  停在 6.0。两条链吃**同一批不可信视频文件**（用户从 Nyaa 等处下载），播放路径补了
  漏洞，但对同一文件做一次「制卡」（抽帧 / 抽音频）就换到了这条未修的路径。

  **卡住的真正根因（比「构建脚本没适配」深一层）**：ffmpeg-kit 的核心价值是把整个
  `fftools` 树 fork 成手改副本，改造成可作为库调用的会话式接口——
  `apple/src/fftools_*.{c,h}` 共 21 个文件、**3652 行改动**（`ffmpeg.c` 1139 /
  `ffmpeg_opt.c` 704 / `ffprobe.c` 667 / `opt_common.c` 323 为大头）。
  `arthenica/ffmpeg-kit` 归档时死掉的正是这份 fork 的维护。而 iOS 沙箱不允许 exec
  子进程，这份 in-process fork **不可替代**（桌面走 CLI 子进程，所以不受影响）。

  自行升版的成本已实测量化，**不可行**：
  | 目标 | fftools 结构变化 | 上游在 `ffmpeg.c` 的 churn |
  |---|---|---|
  | n6.0（现状，4196 行） | 基线 | — |
  | n6.1.6 | +`ffmpeg_dec.c` `ffmpeg_enc.c` | **3352 行** |
  | n7.1.5 | 再 +`ffmpeg_sched.c/h`（调度器重写） | 更大 |
  我们要保的 1139 行 fork 改动与上游 3352 行 churn 大面积重叠 → **补丁无法 rebase，
  只能手工重推**，是数天级的 C 移植工作。

- **[ ] ① 未修复** — **正解是迁移而非移植**：`arthenica/ffmpeg-kit-next` 是同作者的
  官方续作（2026-06-01 建仓，2026-08-01 仍在推，未归档，`archived=false`），
  `scripts/source.sh` 把 FFmpeg 钉在 **n8.1.2**，已发 v8.1.1（2026-07-28）。
  那份 fftools fork 一直有人维护，且已移植到 8.1.2——**比桌面的 7.1.5 还新**。
  迁移步骤：
  1. vendored 包 `third_party/ffmpeg_kit_flutter`（6.0.3）→ `ffmpeg_kit_next_flutter`
     （8.1.1）。上游该包 `publish_to: none` 且自带 `LICENSE.GPLv3`，**本就设计成
     vendored**，与本仓现模型一致；`lib/` 下 `ffmpeg_kit.dart` / `ffprobe_kit.dart`
     文件名与现用完全同名。**Dart 侧 API 已核对（2026-08-02）**：
     `flutter/flutter/lib/ffmpeg_kit.dart` 的 `class FFmpegKit` 提供
     `executeWithArgumentsAsync(...)` 与 `cancel([int? sessionId = null])`，与本仓
     `ffmpeg_backend.dart` 实际用到的 4 个符号（`FFmpegKit.executeWithArgumentsAsync` /
     `FFmpegKit.cancel` / `FFprobeKit.executeWithArguments` /
     `FFprobeKit.executeWithArgumentsAsync`）签名一致——**含我们赖以「只取消本次
     session、不误杀并发字幕抽取/制卡任务」的可选 sessionId 参数**（见
     `ffmpeg_backend.dart:621` 的注释）。故 Dart 侧改动预期仅为 import 包名。
  2. cert-pin 补丁（`third_party/ffmpeg_kit_flutter/patches/ffmpeg-tls-pin-sha256.patch`，
     185 行 / 6 个 TLS 文件）rebase 到 8.1.2。**移动端只需 2 个文件**：`tls.c` 的共享
     helper `ff_tls_check_cert_pin` + `tls_openssl.c` 的握手后调用点（Android/iOS 用
     `--enable-openssl`，其余 3 个后端是桌面的）。注意上游 `tls_openssl.c` 6.0→8.1.2
     churn 938 行（重写），调用点需重新定位，但补丁是**加法式**的，语义是我们自己的。
  3. 用 ffmpeg-kit-next 的 `scripts/` 构建体系（顶层入口从 `android.sh`/`ios.sh` 改为
     `nix-android.sh` 等）重编 AAR + xcframework，保持
     `--enable-gpl --enable-x264 --enable-openssl`（`scripts/help-android.sh` 确认
     `--enable-gpl` 与 GPL 库仍在）。
  4. 更新 `ffmpeg_kit_mobile_recipe_guard_test.dart` 的期望值与
     `patches/README.md` 的重编流程。
- **[ ] ② 未加自动化测试** — 现有 `hibiki/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart`
  静态抠二进制内嵌 configure 串与 libx264 符号，迁移后需同步期望值；另需补一条
  「vendored ffmpeg-kit 的 FFmpeg 主版本不得低于 N」的守卫，避免再次悄悄落后一个大版本。
- **收敛目标（后续，不在本条范围内）**：三条链当前是 播放 libmpv 6.1.6 / 桌面制卡
  ffmpeg-min n7.1.5 / 移动制卡 6.0，**三个版本**。FFmpeg 现最新稳定是 **n8.1.2**
  （`n7.1.5` 是 7.1 分支 tip，`n8.2-dev` 未发）。本条落地后移动端就在 8.1.2，届时
  把桌面 ffmpeg-min 从 n7.1.5 也抬到 n8.1.2，可让**制卡两端同 ref**，cert-pin 补丁
  收敛成**一个** rebase 目标（当前是桌面 7.1.5 + 移动 6.0 两个）。
  桌面那一步很便宜——`build-ffmpeg-min.sh` 的 `FFMPEG_REF` 一行 + 重跑 ffmpeg-min.yml
  重新 vendor，行为回归由 smoke-test.sh 兜（它逐条覆盖了 Hibiki 实际用的参数形态）。
  **但必须单独一个 PR**：把「补漏装配」和「升大版本」混在一起，出回归无法二分定位。
- **备注**：本条**不能与 BUG-1420/1421 同批做**——需要独立 worktree、远程 Mac 构建机
  （iOS xcframework 只能 macOS+Xcode 编，且必须 `brew install nasm`，否则 x86_64 模拟器
  切片的 x264 会挂**而 arm64 切片先成功**，极易误判成「编好了」，见
  `third_party/ffmpeg_kit_flutter/patches/README.md`）、Android NDK，以及真机验证四条：
  片段导出 H.264 / AVIF-WebP-GIF 封面 / 句子音频 / 远端制卡 https + cert-pin。
  在完成真机 E2E 之前，只能标 `implemented_unverified`，不得宣称「已修好」。
