## BUG-588 · 字幕对轴波形显示密度不利于辨句
- **报告**：2026-07-07（用户反馈：TODO-1244 波形能显示了，但「密度不对」，句子边界看不清，让参照成熟工具）
- **真实性**：✅ 真 bug（视觉/主观项，客观可测的是波形映射函数）。两处根因：
  - 振幅对比错：`hibiki/lib/src/media/video/audio_energy_probe.dart` 的 `downsampleEnergyEnvelope` 直接对 **RMS 分贝值**做 min/max 线性归一化。分贝是对数量纲，房间底噪（约 -60~-80dB）与语音峰值（约 -15~-30dB）在分贝轴上只差几十，线性拉伸后底噪仍有 ~40% 柱高，语音和静音糊成一条均匀带——看不出句间静音、辨不出句子边界。成熟工具（Audacity/Aegisub）画的是线性 PCM 振幅 `10^(dB/20)`：静音塌到接近 0、语音尖峰凸出。
  - 时间密度太粗：波形显示探测复用自动对轴的 `kSubtitleAutoAlignBinMs=100ms`（10 帧/秒），画成波形只有 10 根柱/秒，粗且无法看细节（`hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart` `_loadSubtitleWaveformEnvelope`）。
- **[x] ① 已修复** — 根因修：`downsampleEnergyEnvelope` 先经新纯函数 `dbToLinearAmplitude`（`10^(dB/20)`）把每帧 dB 转成线性振幅再取桶内峰值 + 归一化；归一化上限改用高分位（`normalizeCeilingPercentile=0.99`，`_percentileValue`）而非绝对峰值，单个爆音/配乐重音不再把整段语音压成一线，安静段仍可见轮廓。显示探测改用新常量 `kSubtitleWaveformWindowMs=20`（50 帧/秒，密度 ×5），自动对轴仍 100ms 不受影响（独立探测/缓存）。提交：2a1f91dc3
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/audio_energy_downsample_test.dart`：新增 `dbToLinearAmplitude` 刻度/单调/静音塌底、`波形对比`（-50dB 安静段线性域 <0.1 而非旧 0.5、纯静音画平全 0）、`离群瞬态抑制`（200 桶含单个 0dB 爆音时语音桶仍 >0.9；`percentile=1.0` 退化为绝对峰值则语音被压 <0.1）三组；并更新既有归一化断言到线性振幅域语义。19 条全绿。
- **备注**：视觉/主观项，客观可测的是波形→像素列的映射函数正确性；真机视觉观感（波形是否「像成熟播放器」）交用户验收。时间/缩放默认（`_basePxPerMs=0.12`≈120px/s、zoom 0.25~8×）未改，已够用。
