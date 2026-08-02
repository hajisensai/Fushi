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

- **[ ] ① 未修复** — vendor macOS 版 ffmpeg/ffprobe 到 `third_party/ffmpeg-min/macos/`；
  在 `release-desktop.yml` 的 macos job 加装配步，把二者拷进
  `hibiki.app/Contents/MacOS/`，ad-hoc `codesign` 后重签整个 app（镜像既有
  `Bundle and sign pinned Mihon desktop runtimes` 的做法：逐个签 Mach-O →
  `codesign --force --deep --sign -` 重签 app → `codesign --verify --deep --strict`）。
- **[ ] ② 未加自动化测试** — 源码扫描守卫：`release-desktop.yml` 中每个产出发布物的
  桌面 job 都必须有对应的 ffmpeg-min 装配步；新增平台漏装配即当场红。避免再次出现
  「加了平台却没接装配线」。
- **备注**：与 [BUG-1420](BUG-1420-desktop-ffprobe-never-bundled.md) 同源——配方 /
  产物 / 装配 / 消费四处无单一真相源。macOS 的 ad-hoc 签名（`--sign -`，不做公证）
  意味着往 `Contents/MacOS/` 放辅助可执行文件是安全的，无需 Helpers 目录或
  entitlements 调整。
