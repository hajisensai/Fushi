## BUG-1039 · 制卡「原片档」把 GIF 按源分辨率+源帧率导出 → 制卡/覆盖巨慢、Anki 无响应
- **报告**：2026-07-23（用户：qqbotxiaoxiao，原话「这个覆盖巨慢。直接把 anki 弄无响应了」「不止这里的覆盖，视频普通查词制卡也无响应」，附视频页「卡片已在 Anki 中」弹窗截图，进度条卡在 busy 态）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart` 的
  `MiningMediaCompression.imageTiers[3]`（原片档）过去写成 `(gifFps: 0, gifWidth: 0, ...)`，
  即用「0 = 不限制」哨兵同时表达**截图不缩放**和 **GIF 源分辨率+源帧率**。这是把静态图的
  语义错套到动图上：截图原图直通只是一张几 MB 的 JPEG，而 GIF 是 8-bit 调色板逐帧 LZW、
  **无帧间压缩**，体积随「像素×帧数」线性爆炸。
  `buildFfmpegClipGifArgs`（同文件 L917-921）据此整段省略 `fps=`/`scale=` 滤镜，
  `ImmersionMiningEngine.mine`（`hibiki/lib/src/mining/immersion_mining_engine.dart:111-123`）
  把该档喂给 ffmpeg。
  - **实测**（1080p 番剧源、**4 秒**字幕区间、与代码逐字一致的 ffmpeg 参数）：
    标准档(480px/8fps) **1.5 秒 / 1.5 MB**；原片档(0/0) **48.9 秒 / 54 MB**（33× 慢、35× 大）。
    cue 上限 `maxDurationMs=10000` 时约 135 MB，还会撞 `extractClipGifViaFfmpeg` 的 120 秒超时。
  - **传导链**：GIF → `AnkiConnectRepository._storeLocalMedia` 读全量字节 → base64（已在
    BUG-933 卸到 isolate）→ `AnkiConnectService._request` 在 UI isolate `jsonEncode` 这坨
    ~72 MB 字符串 → POST 给 AnkiConnect；**Anki 在自己主线程解析该 JSON → 直接无响应**。
    落到卡片里后每次复习都要解 54 MB GIF，AnkiWeb 也同步不上去。即「GIF 原片」不是一个更高
    的质量档，而是**在任何口径下都不可用**的配置。
  - 覆盖（`updateMinedNote`）与新建（`mineEntry`）走**同一条** `ImmersionMiningEngine` 媒体
    链路，故用户观察到的「覆盖慢」与「普通制卡也无响应」是同一根因，不是覆盖特有。
  - 用户生产库偏好实测：`mining_image_quality|i:3`（原片档）、`mining_audio_quality|i:2`。
- **[x] ① 已修复** — 原片档不再对 GIF 用 0 哨兵：`imageTiers[3]` 的 GIF 参数改为封顶值
  `gifNativeFps=12` / `gifNativeWidth=960`（新增两个具名常量），截图侧 `maxLongEdge: 0`
  （原图直通）语义完全不动。实测同一 4 秒区间：**6 秒 / 7.7 MB**，仍明显优于高清档
  （720px/12fps，4 秒 / 4.3 MB）。同步修正类文档注释与设置项说明文案
  （`mining_image_quality_hint`，en / zh-CN / zh-HK）。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/desktop_audio_clipper_test.dart`：
  新增回归守卫「BUG-1039：没有任何图片档把 GIF 参数留成 0（不限制）哨兵」（遍历全部
  4 档断言 `gifFps > 0 && gifWidth > 0`）；原「满档用 0 哨兵」用例改断言封顶值；
  单调递增用例的 GIF 部分从「排除满档」扩到覆盖满档。
  `hibiki/test/settings/mining_media_quality_guard_test.dart` 同步更新满档断言。
- **备注**：ffmpeg 参数本身（`-ss`/`-t` 在 `-i` 前的输入侧 seek、palettegen/paletteuse 双遍）
  没问题，不需要动。**待用户真机复验**：视频页查词 →「+」新建 / 点「✓」→ 覆盖，在原片档下
  制卡应从 ~49 秒回到个位数秒，Anki 不再卡死。UI 侧的弹窗形态/层级见 [BUG-1040](BUG-1040-mined-card-dialog-centered-and-above-popup.md)。
