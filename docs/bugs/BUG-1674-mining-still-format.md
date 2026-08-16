## BUG-1674 · 视频卡片图片：描述不准，且静态截图格式不可选
- **报告**：2026-08-15（用户：截图指 Anki 设置「视频卡片图片」一项）
- **真实性**：✅ 真 bug（两处，均沿真实代码路径复核）
  - **描述不准**：`fushi/lib/i18n/strings_zh-CN.i18n.json` 的 `video_mining_image_mode_hint` 写「视频制卡封面用动图还是截图」，而这一项是**三**档（`VideoMiningImageMode`：gif / currentFrame / subtitleStart，`fushi/lib/src/mining/immersion_mining_request.dart:72`）。二元描述盖不住三档，也没说清两种截图取的是哪一帧。英文原文 "How covers on video cards are captured" 在中文翻译时被压成了二元。
  - **静图格式不可选**：静态截图格式过去**硬编码 JPEG**，设置里没有任何入口——ffmpeg 抽帧 `immersion_mining_engine.dart:253`（`immersion_frame.jpg`）、Dart 截图降采样 `immersion_mining_engine.dart:272`（`encodeJpg` → `immersion_shot.jpg`）、Netflix 录制片段 `immersion_capture_channel.dart:247`（`clip_frame.jpg`）与其封面命名 `immersion_capture_channel.dart:175`。已有的「动图格式」（`MiningAnimatedFormat`，AVIF/WebP/GIF）按设计只对动图生效，故用户一旦选了两种截图档中的任意一种，格式就锁死 JPEG。
- **[x] ① 已修复** — 新增与 `VideoMiningImageMode`/`MiningAnimatedFormat` 正交的第三根轴 `MiningStillFormat`（jpg/png，`immersion_mining_request.dart`）：
  - 偏好 `video_mining_still_format`（默认 jpg = 现状零破坏），设置项「视频卡片截图格式」落在 Anki 设置的媒体区，并进设置搜索索引；
  - 两条静图产出链都按它取扩展名：ffmpeg 抽帧（app 内视频 / YouTube / Netflix 片段）与 Dart 截图降采样（`card_screenshot_downsampler.dart` 新增 `CardScreenshotEncoding`）；
  - 首选格式失败按 `MiningStillFormat.encodeAttempts` 退回 JPEG（捆绑 ffmpeg 缺 png 编码器时该丢的是格式，不是整张封面），**落盘扩展名跟随实际字节而非用户所选**——否则会写出 `.png` 里装 JPEG 的卡，Anki 按扩展名判 MIME 时封面不显示；
  - 顺带修掉 `img.findFormatForData` 对过短/损坏字节抛 RangeError（GIF 嗅探越界）的路径，嗅探失败保守回退，与降采样器既有纪律一致；
  - 文案改准：中文「视频卡片封面用字幕区间动图，还是某一帧静态截图（取哪一帧也在这里选）」，英文同步，其余 15 份（本就是英文原文）一并更新。
  - **第二轮（用户追加：gal 与浏览器扩展也要支持）**：
    - gal 侧补对称的 `gal_mining_still_format` 偏好 + 「游戏卡片截图格式」设置项（与 image mode / animated format 同样的「视频与 gal 分开存」分法），透传到 `GalHookMiningCoordinator.mineLine` 的两个入口（浮窗 `gal_hook_text_overlay_controller.dart`、`texthooker_page.dart`）。gal 改动前落什么格式全看「这张抓图需不需要缩放」（需要 → JPEG，不需要 → 原样 PNG），同一设置两种结果、用户既无从预测也无从选择。
    - 浏览器扩展这条**本身不产静图**：扩展只发 `clipBase64`（录制片段）与纯文本，静帧是 app 侧从片段里抽的，故第一轮的 `clip_frame.<ext>` 已让它生效；额外补的是**外部直接给字节**那条路——引擎在 `providedCoverBytes` 分支按偏好归一化（`transcodeCardScreenshot`：只换编码不改尺寸，动图字节由嗅探原样放行），文件名经 `providedCoverFileName` 只换扩展名、保留 `netflix_frame`/`external_window` 这类来源线索。
    - 第二轮踩到并修掉的自造缺陷：`stillFormatOfBytes` 一度对「嗅探不出」统一兜底 jpg，而 gal 那条链的入参恒为 PNG——降采样解码失败时会写出 `.jpg` 里装 PNG。改成兜底方向由调用点显式声明（视频侧 jpg / gal 侧 png），并在测试里把两个方向都钉住。
  - 提交：见本文件所在提交及其后续提交。
- **[x] ② 已加自动化测试** — `fushi/test/mining/mining_still_format_test.dart`（31 例）：偏好解析默认/未知值回退、`encodeAttempts` 降级链、ffmpeg 抽帧扩展名跟随偏好、png 编码器缺失退 JPEG、Dart 截图链产出**字节真是 PNG**、降采样器「只缩不放」捷径在换格式时不得原样返回、外部给定字节按偏好转码且动图字节原样放行、`providedCoverFileName` 只换扩展名、`stillFormatOfBytes` 两个兜底方向、Netflix `stillFormat` 随结果带回并决定 `netflix_frame.<ext>`、`frozen()` 保留偏好、默认档逐字等价改动前。
  gal 链在 `test/mining/gal_hook_mining_coordinator_test.dart` 补两例（选 PNG/JPG 各落对应扩展名；**必须喂真 PNG 字节**，用 `[80,78,71]` 那种假字节会走「解不开→原样+兜底」路径，怎么选都落 `.png`，等于没测——这坑本轮踩过一次）。
  `test/settings/mining_media_quality_guard_test.dart` 补一条源码守卫：三个制卡入口都必须显式透传静图格式偏好（漏传时形参默认 jpg，用户选的 PNG 静默失效，与动图格式那条同形）。
  变异实测两轮：① 引擎抽帧扩展名改回硬编码 `.jpg` → 2 例红；② texthooker 入口的 `stillFormat:` 实参换成字面量 → 守卫红。两次反向替换回滚后 sha256 均与变异前一致。
- **备注**：动图那根轴（`MiningAnimatedFormat`，AVIF/WebP/GIF）完全不受影响，两轴各管各的；`transcodeCardScreenshot` 的嗅探保证动图字节不会被误当静图解成第一帧。gal 的默认档仍是 jpg（BUG-1473 起 gal 截图就走降采样重编码 JPEG，「小图原样返回 PNG」只是不值得重编码的捷径，不是意图）。
