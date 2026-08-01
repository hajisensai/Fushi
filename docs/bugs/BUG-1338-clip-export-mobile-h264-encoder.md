## BUG-1338 · 移动端片段导出缺 H.264 编码器导致静默产出不可播文件
- **报告**：2026-08-01（用户：手机上导出片段视频会静默产出打不开的文件，TODO-2357）
- **真实性**：✅ 真 bug。根因不在 Dart 逻辑，在**入库的移动端 ffmpeg 二进制能力**：
  移动自编 ffmpeg-kit 是 min 变体（无外部 GPL 库），configure 无 `--enable-libx264`，
  故 `_clipVideoCodecArgs` 只能给移动端退到 libavcodec 原生 `mpeg4`
  （`hibiki/lib/src/media/audiobook/audiobook_clip_export.dart:541`，改前）。
  而导出画布恒为 **1080×1920 / 1920×1080**
  （`hibiki/lib/src/media/audiobook/audiobook_clip_text_render.dart:101`），
  远超 MPEG-4 Part 2 Simple/Advanced Simple Profile 的 level 上限；libavcodec 既不
  clamp 也不写正确的 `profile_and_level_indication`，严格硬件解码器有权拒绝。
  失败模式是**静默**：`audiobook_clip_export.dart:686` 判成功的三元判据是
  「exit 0 且文件存在且长度 > 0」，全链无 ffprobe 回读，编码成功而设备解不了时
  一律判成功 → 用户拿到打不开的卡片且无任何报错。与更早的 mjpeg/.mov（BUG-809）
  及 BUG-1322 同型。
  **无替代路**（静态实证，非推断）：iOS 四个切片 configure 全部明写
  `--disable-videotoolbox`；Android 明写 `--disable-mediacodec`，且当前 FFmpeg 6.0
  根本没有 `h264_mediacodec` **编码器**（6.1 才加入）；Android 仅剩的
  `h264_v4l2m2m` 依赖多数设备不向 app 开放的 `/dev/video*` m2m 节点，不能算数。
  **顺带同因**：`hibiki/lib/src/media/video/video_clip_exporter.dart:164` 的播放器
  片段重编码兜底**硬编码 libx264 且无平台分支**，在移动端一旦被触发（`-c copy`
  快路径失败的源）必然 `Unknown encoder 'libx264'`。同一约束下两条导出管线做法不一致。
- **[x] ① 已修复** — 根因修在能力层而非加特例分支：移动端 ffmpeg-kit 重编时加
  `--enable-gpl --enable-x264`（保留 `--enable-openssl` 与 cert-pin 补丁，BUG-891 不回退），
  两端遂共用同一个 `libx264`。Dart 侧随之**消除特殊情况**：`_clipVideoCodecArgs` 的
  `h264` 开关与 `mpeg4` 分支整个删除，退化为单一 const 参数表；
  `audiobook.part.dart` 的 `useH264` 变量及两处 `h264:` 透传一并删除
  （`isDesktop` 保留——它另有存盘/清理用途，与编码无关）。
  许可：产物由 LGPLv3 变 GPLv3，与 Hibiki 自身 GPL-3.0 一致，`android.sh` 自动写入
  `LICENSE.GPLv3` 与 `license_x264.txt`（已验证 AAR 内 `res/raw/license.txt` 已切 GPL）。
  重编配方入库于 `third_party/ffmpeg_kit_flutter/build/`，流程与 nasm 依赖记于
  `third_party/ffmpeg_kit_flutter/patches/README.md`。
- **[x] ② 已加自动化测试** —
  新增 `hibiki/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart`：静态抠入库 AAR /
  xcframework 内嵌的 configure 串与 libavcodec 里的 `libx264` / `x264 - core` 符号，
  双 ABI + iOS device/simulator 切片逐一断言；并复核 cert-pin（`tls_pin_sha256`）与
  GPL 许可文件未回退；含负向对照（`--disable-mediacodec` 仍在、必不存在的开关必须扫不到）
  防判据失真。**这是移动端首个二进制能力守卫**——此前只有桌面侧
  `ffmpeg_min_vendored_recipe_guard_test.dart`，移动端"换没换、编了什么"全靠人肉
  llvm-strings（BUG-1057/1058 的结构性缺口在移动端原样存在）。
  另反转既有守卫：`audiobook_clip_vertical_webview_guard_test.dart` 原断言
  `useH264` 必须绑定 `isDesktop`（旧约束"移动端不许用 libx264"如今是错的，留着会
  阻止正确实现），改为**禁止型**守卫——`useH264` / `h264:` 不得再出现、参数表必须是
  单一 const 列表、`mpeg4` 不得回流；`audiobook_clip_synth_test.dart` 的移动端断言
  由「必须 mpeg4、绝不 libx264」整体反转，并新增「单图与序列帧两条路径必须产出
  逐字节相同的编码器参数段」——PR#607 的变异实测正抓到过"只改一条路径"的空洞。
- **备注**：**未做真机端到端验证**（按项目规则真机验证已取消）。已完成的是静态硬实证：
  两个 Android ABI 与 iOS 各切片的二进制里 `libx264` 与 `x264 - core` 均在、configure
  含 `--enable-gpl --enable-libx264 --enable-openssl`、`tls_pin_sha256` 未回退。
  「设备能否播放」这一步在代码层仍不可自检——`exit 0 + 文件非空即判成功` 的判据未变，
  只是产物换成了规格上限不再被超出的 H.264。若要彻底消除"静默"这一失败形态，
  需另加导出后 ffprobe 回读自检（本轮未做，与本 bug 的根因是两件事）。
  AAR 体积 24.0MB → 26.2MB（+2.1MB）。
