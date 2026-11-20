## BUG-4955 · Android 发布不留 Dart 调试信息，ANR 栈的 libapp.so pc 对不上源码
- **报告**：2026-11-16（应用内反馈 ICF67eBY57：iReader Ocean 5 Pro 墨水屏，Android 14，3.3.0，11-10～11-17 十几次 ANR）
- **真实性**：✅ 真问题（诊断缺口）。反馈里每次 ANR 的 `main` 线程都是 `state=R`、全部帧为
  `base.apk (offset 664000) (???) (BuildId: 0c5011d5…)` 的裸 pc（即 libapp.so，平台线程与 UI 线程合并后 Dart 在主线程连续跑满 5 s），
  多数停在 `ReaderFushiPage`，最后一次在 `TtsVoiceSettingsPage`；ANR 前 30 s 窗口 main 线程 CPU 19～24 s、anon 内存从约 270 MB 涨到 700～950 MB。
  根因无法定位，因为 `.github/workflows/release.yml` 的两条 Android release 出包命令（「Build release-signed debug-channel APK」
  与「Build release APK (split per ABI)」，修复前约 :1032 / :1103）之后没有任何步骤保留 AGP strip 前的 libapp.so：
  Android 上 gen_snapshot 不 strip（Flutter 3.47.6 `packages/flutter_tools/lib/src/base/build.dart`「let AGP handle stripping」），
  `fushi/build/app/intermediates/flutter/release/<abi>/app.so` 本来就带 `.symtab` + `.debug_info` + `.debug_line`，构建结束就随 runner 丢了；
  APK 里的 `lib/<abi>/libapp.so` 已被 strip（本机实测 0 个 symtab / debug 段）。iOS 已在 BUG-4655 保留，Android 没动。
  **ANR 本身的代码根因仍未定位**：要等用户升级到带本修复的版本、下一次 ANR 报告的 pc 用对应构建的符号还原后再立 bug。
  线索（未定性）：ANR 前各 30 s 窗口里 ui_activity_probe 的 `page=[ReaderFushiPage]` 同时记到 `_VideoFushiPageState.caretSetState@video_fushi_page.dart:3115`
  每窗 6～19 次（v3.3.0 该行是视频页 `caretSetState` 的 `setState(fn)`，与阅读器那份方法体不同，不是 AOT 去重假象），说明阅读器下面压着一个仍在刷新的视频页；
  另有 `DartWorker` 每 30 s 吃 30～40 s CPU。这两条要和符号化后的 ANR 栈一起看。
- **[x] ① 已修复（诊断缺口）** — 新增 `fushi/tool/android_dart_symbols.sh`：`stash <target-platform>` 在每次 `flutter build apk --release`
  之后把未 strip 的 `app.so` 收进 `build/android-dart-symbols/<abi>/`（逐 ABI 出包在循环里逐次收，换 target-platform 重编会清掉上一份），
  `verify` 对每个 release APK 的 `lib/<abi>/libapp.so` 核对 build-id 一致且收到的 ELF 带 `.symtab` / `.debug_line`；
  `release.yml` 加「Verify Android Dart symbols match APKs」与「Upload Android Dart symbols」（artifact `android-dart-symbols-<序号>`，
  正式 / 测试版 90 天、debug 通道 14 天，`continue-on-error`，不进 Release 资产）。
  不用 `--split-debug-info`：它连带 `--dwarf-stack-traces`，app 内 Dart 栈变 DWARF，`ui_activity_probe` 的 `who=` / `fcb=` 归因与反馈里的符号化栈全部退化；
  本修复运行时零改动。还原流程写进 `docs/agent/build.md`「Android 崩溃 / ANR 的 Dart 符号」。
- **[x] ② 已加自动化测试** — `fushi/test/build/android_dart_symbols_guard_test.dart`：两条 release 出包后都 stash（split 循环内、按 `$platform`）、
  stash 数 = release 出包命令数、Android 出包不带 `--split-debug-info` / `--obfuscate`、核对 / 上传步骤的条件 / 顺序 / 保留期 / continue-on-error、
  脚本 ABI 映射与路径；外加 Flutter SDK 契约（Android 分支不 `--strip`、中间产物目录 `intermediates/flutter/<variant>/`），升级 Flutter 改了就红。
- **备注**：
  - 脚本本机实测（真实 3.x arm64 release 构建的 `app-release.apk` + 中间产物 `app.so`，llvm-readelf 代 readelf）：stash / verify 通过（build-id `fc476590…` 一致）；
    收到的文件换成垃圾 → `mismatch` 退出 1；未 stash → `missing` 退出 1；未知 target-platform → 退出 1。
    `llvm-symbolizer --obj=app.so 0x249c48c` 还原出 `ColorSwatch.[]  package:flutter/src/painting/colors.dart:423`。
  - 3.3.0 那次构建的符号已不可得（runner 早已回收），这份反馈的十几次 ANR 无法回溯还原。
