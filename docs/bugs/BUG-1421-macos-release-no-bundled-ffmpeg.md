## BUG-1421 · macOS 发布产物从不捆绑 ffmpeg，桌面制卡全链在未装 ffmpeg 的 Mac 上失效
- **报告**：2026-08-02（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因在装配层：`.github/workflows/release-desktop.yml` 只有
  `Install vendored ffmpeg-min runtime into Windows bundle`（第 402 行起）这**一个**
  平台的装配步，`macos` job（第 610 行起）从 `Build macOS release` 直接走到
  `Bundle and sign pinned Mihon desktop runtimes` 再到 `Prepare macOS app release asset`，
  中间没有任何 ffmpeg 装配。于是 `hibiki.app/Contents/MacOS/` 下只有主程序，
  `ffmpeg_backend.dart` 的 `_bundledExecutablePath()`（第 283-291 行，按
  `Platform.resolvedExecutable` 的同级目录找）恒返回 null，`resolveFfmpegExecutable()`
  落到 PATH 的 `'ffmpeg'`。

  Mac 上没有系统自带 ffmpeg（不像某些 Linux 发行版），未装 Homebrew ffmpeg 的用户
  等于**整条桌面制卡链不可用**：视频帧封面、句子音频、cue 动图、片段导出、内封字幕
  抽取全部 `ProcessException`。Windows 侧对应的坑（TODO-416：曾经跨 workflow 取
  artifact，过期即发出无 ffmpeg 的包）当年被修掉了，macOS 从头到尾就没接过这条线。

  **范围澄清**：`release-desktop.yml` 的 job 只有 `windows` / `macos` / `ios` / `publish`，
  **没有 Linux 发布 job**；Linux 只在 `build-multiplatform.yml:238` 有一个
  `flutter build linux --debug` 的编译冒烟，不产出发布物。所以本 bug 的用户可见面
  **仅 macOS**——「mac/Linux 都缺 ffmpeg」的说法里，Linux 那半是「根本没发布」而非
  「发布了但缺 ffmpeg」，不要据此去给 Linux 加装配步。

- **[x] ① 已修复** — vendor `third_party/ffmpeg-min/macos/{ffmpeg,ffprobe}`（mode 100755）；
  `release-desktop.yml` macos job 新增 `Install vendored ffmpeg-min runtime into macOS bundle`：
  拷进 `hibiki.app/Contents/MacOS/` → 逐个 ad-hoc `codesign` → `--force --deep` 重签 app →
  `codesign --verify --deep --strict` → `-version` 硬门。位置在 Mihon 重签之后、打包之前
  （commit 229f8bd46）。
- **[x] ② 已加自动化测试** — 新增 `hibiki/test/tools/desktop_ffmpeg_bundling_guard_test.dart`：
  凡 job 跑了 `flutter build <桌面平台> --release` 就必须装配 ffmpeg-min 且 ffmpeg/ffprobe 齐全，
  **不硬编码平台清单**（将来加 Linux 发布漏装配同样红）；并校验被引用的 vendored 二进制真实存在
  且非占位文件。
- **备注**：与 [BUG-1420](BUG-1420-desktop-ffprobe-never-bundled.md) 同源——配方 /
  产物 / 装配 / 消费四处无单一真相源。macOS 的 ad-hoc 签名（`--sign -`，不做公证）
  意味着往 `Contents/MacOS/` 放辅助可执行文件是安全的，无需 Helpers 目录或
  entitlements 调整。
