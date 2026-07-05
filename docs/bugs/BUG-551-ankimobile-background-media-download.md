## BUG-551 · iOS AnkiMobile 视频句音频导入后仍保留 localhost URL
- **报告**：2026-07-06（用户：）
- **真实性**：✅ 真 bug。根因是 `hibiki/lib/src/anki/ankimobile_repository.dart:320` 之前的实现先 `openUrl` 切到 AnkiMobile，之后才异步启动 iOS background task；Hibiki 进后台后 localhost media server 可能被挂起，AnkiMobile 下载失败后把 `http://127.0.0.1:.../immersion_audio.aac` 原样写进字段。
- **[x] ① 已修复** — `55645be21`：有本地媒体时在跳转 AnkiMobile 前启动 background task，并用同一个关闭路径管理 server / background task 生命周期；`openUrl` 失败或异常时立即关闭。
- **[x] ② 已加自动化测试** — `55645be21`：`hibiki/test/anki/ankimobile_repository_test.dart` 覆盖本地 mp3/aac/gif/svg 字段，并断言 background task 在 `openUrl` 前开始、保活结束后关闭。
- **备注**：复现信号来自用户截图：AnkiMobile 卡片内直接显示 `http://127.0.0.1:55893/media/1-immersion_audio.aac`，说明 addnote 字段已生成但 AnkiMobile 没能在导入时抓取媒体文件。
