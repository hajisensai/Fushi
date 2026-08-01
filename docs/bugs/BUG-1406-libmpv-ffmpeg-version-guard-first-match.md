## BUG-1406 · libmpv FFmpeg 版本守卫只校验第一个匹配，单 ABI 静默降级不报红
- **报告**：2026-08-02（PR#685 复核方发现，TODO-2608）
- **真实性**：✅ 真 bug（守卫盲区，已实测复现）。根因
  `hibiki/test/build/libmpv_truehd_guard_test.dart:45-54`（改前）——`ffmpegVersionOf`
  用 `RegExp(...).firstMatch(text)`，整份构建文件**只取第一个** `ffmpeg<x.y.z>` 标记，
  后续标记根本不参与比较。
  `third_party/media_kit_libs_android_video/android/build.gradle` 在**同一个文件里**钉了
  四个互相独立的 ABI 产物（arm64-v8a / armeabi-v7a / x86_64 / x86）；firstMatch 只看
  arm64-v8a 那一条，另外三个 ABI 的版本无人校验。
  实测复现（改前，基底 `origin/develop` = `4de73c62b`）：只把 x86 一个 ABI 的 URL 降到
  `ffmpeg6.0.0` → 守卫 `FLUTTER TEST VERDICT: PASSED - 4 tests ran`，全绿。
  证据 `.codex-test/todo2608/01-repro-x86-downgrade.log`。
  四个 MD5 pin 兜不住：旧断言只校验「**存在** ≥4 个 32-hex 校验和」，不校验值，也不校验
  哪个校验和属于哪个 ABI；降级方连 MD5 一起换成 6.0.0 产物的真实值，gradle 侧的
  MD5 verification 完全通过，守卫照样绿。
  安全后果：TODO-1137 自建 6.1.6 分支的理由是 media-kit 出厂的 FFmpeg 6.0 仍带 magicyuv
  OOB write（构造的 mkv/mov/avi 即可触达），而这个 .so 解的是用户随手打开的任意文件。
  盲区意味着「某个 ABI 悄悄用回旧版 FFmpeg」不会被任何测试发现。
  同类盲区（一并修）：① iOS/macOS Makefile 版本只有一处（`MPV_XCFRAMEWORKS_VERSION=`），
  URL 靠 `${MPV_XCFRAMEWORKS_VERSION}` 插值；若把版本**硬写进 curl URL**，变量仍读 6.1.6，
  firstMatch 命中变量判绿，实际下载的却是 URL 里那一版（该变异改前同样全绿）。
  ② Windows `CMakeLists.txt` 的 `set(LIBMPV ...)` / `set(LIBMPV_URL ...)` 也用 firstMatch
  扫**未剥注释**的原文，而该文件有 40 余行 `#` 注释在详述旧上游 pin。
  ③ 附带发现：PR#685 引入的 `withoutComments` 是手搓 `startsWith('//')`，
  `test/tools/source_guard_adoption_test.dart` 在 `origin/develop` 上因此**已经红**
  （证据 `.codex-test/todo2608/02-adoption-baseline.log`），不在既知三条红之列，本条一并修好。
- **[x] ① 已修复** — `hibiki/test/build/libmpv_truehd_guard_test.dart`：
  `firstMatch` → `allMatches`，`expectEveryMarkerPatched` 逐个标记比下限，失败时回原文取
  **整行**打进 reason，报错自带是哪个 ABI。Android 改为**逐条解析下载表**（url / md5 /
  destination 三元组）各自校验：destination 的 ABI ∈ 硬编码四元集合、URL 与 destination 的
  ABI 一致、该条 URL 自带版本标记、每 ABI 只出现一次；锚点是
  `md5ByAbi.keys.toSet() == androidAbis`，表结构一变就红，不会退化成扫零条。
  MD5 **不比对硬编码常量**（值本来就在 build.gradle 里，抄进测试只意味着每次换产物都要改两
  个文件，证明不了任何事），改为校验**对应关系**：一 ABI 一 pin、四个 pin 互不相同，堵住
  「粘贴同一个校验和 → 两个 ABI 验同一个 jar」。darwin：SHA256 恰好一处 + 下载 URL 必须插值
  `${MPV_XCFRAMEWORKS_VERSION}`（不许硬写版本）+ ios/macos 两份 SHA256 必须不同（相同即一份
  Makefile 是从另一份粘来的，`shasum -c` 验的是另一个平台的 tarball）。Windows：先
  `maskHashComments` 再取值，且每个 `set()` 必须恰好一处。手搓 `withoutComments` 删除，改用
  共享 helper——gradle 走 `maskComments`，Makefile / CMake 走**新增**的 `maskHashComments`
  （`hibiki/test/helpers/source_guard.dart`，等长掩码 + 引号状态 + 逐行重置）。
- **[x] ② 已加自动化测试** — 守卫本体
  `hibiki/test/build/libmpv_truehd_guard_test.dart`；新原语单测
  `hibiki/test/helpers/source_guard_lexer_test.dart`（3 条 `maskHashComments`：等长 + 行尾
  注释也掩、引号内 `#` 不误剪、漏配引号不跨行传染）。变异实测（证据 `.codex-test/todo2608/`）：
  反向 ×4，每个 ABI **单独**降到 6.0.0 → 每次都红且 `Offending line:` 打出的正是该 ABI 那一行
  （`10-mut-arm64-v8a.log` / `11-mut-armeabi-v7a.log` / `12-mut-x86_64.log` / `13-mut-x86.log`）；
  正向：四个 ABI 全升 6.1.7 → **仍绿**（`14-mut-positive-617.log`），没写死「必须恰好等于
  6.1.6」；x86 抄 x86_64 的 md5 → 红（`15-mut-md5-collision.log`）；ios 抄 macos 的 SHA256 →
  红（`16-mut-darwin-sha-collision.log`）；ios URL 硬写 `ffmpeg6.0.0` 而变量留 6.1.6 → 红
  （`17-mut-darwin-url-hardcoded.log`）。
- **备注**：产物本身没有降级，四个 ABI 现在都真是 6.1.6；本条修的是**守卫**，不是产物。
