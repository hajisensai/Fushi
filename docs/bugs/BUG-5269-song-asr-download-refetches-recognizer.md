## BUG-5269 · 歌曲字幕补分离模型时按推荐变体重下整套识别模型
- **报告**：2026-11-22（Jellyfin 服务器曲目「生成日语字幕」端到端取证时沿代码路径发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/subtitle/video_subtitle_model_ports.dart:113`（修前）歌曲素材（`song`，音乐库 / 服务器曲目生成字幕）的下载在混音那条确认识别文件就绪后，调 `_downloadMissing(language, song)`：对歌曲包 `plan()` 后按 `plan.variant` 下载。歌曲包 = 混音包 + 人声分离模型（同一目录），分离模型没下时两个编码器变体都不算就绪，`planAsrEncoderVariant` 于是回落到**推荐变体**——有独显（DirectML / CUDA、显存预算 ≥ 4 GB）的机器推荐 fp32。只装了 int8（CPU 推荐时下的、或手动放进去的）的机器点「下载」，本该只补 28 MB 的 `UVR_MDXNET_9482.onnx`，实际去下 2.5 GB 的 fp32 识别权重（`model.onnx` + `model.onnx_data`）。`shared_model_downloads.dart` `joinSongModelDownload` 的注释写着「那时下载器只剩分离模型要写」，但它只传了 `mixedReady: bool`，没把在盘的那个变体交给歌曲那条，不变量没有落到代码里。
- **[x] ① 已修复** — `joinSongModelDownload` 的 `mixedReady` 改为 `mixedReadyVariant`（混音包在盘的识别变体，未就绪为 null），`downloadSongMissing` 收这个变体；`AppVideoSubtitleAsrModelPort` 的歌曲那条按混音包 `plan()` 选出的已在盘变体去 `downloadModel`，于是只剩分离模型要下。
- **[x] ② 已加自动化测试** — `fushi/test/asr_host/shared_model_downloads_test.dart`「混音那条下完、识别文件就绪后才补分离模型」断言歌曲那条拿到的是混音包在盘的变体（int8），不是推荐变体；端到端由 `fushi/integration_test/music_server_asr_itest.dart` 覆盖（放入缓存的 int8 识别文件后走 app 下载入口，断言只下了 `UVR_MDXNET_9482.onnx`）。
- **备注**：不改上游 ASR 算法与清单，只改 app 层的下载装配。
