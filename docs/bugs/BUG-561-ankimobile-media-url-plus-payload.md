## BUG-561 · iOS AnkiMobile 制卡音频不播放且词典/详情字段出现加号和本地路径
- **报告**：2026-07-06（用户：）
- **真实性**：✅ 真 bug。根因 1：`hibiki/lib/src/anki/ankimobile_repository.dart:304` 之前把本地音频/封面/词典媒体塞成 `data:` 字段，AnkiMobile URL scheme 文档要求媒体字段是可下载 URL，导致音频无法被 AnkiMobile 导入播放。根因 2：`hibiki/lib/src/sync/immersion_mine_payload.dart:50` 之前直接字符串化远端 payload，未还原 form-urlencoded 的 `+` / `%xx`，且 `{document-title}` 可带入 `immersion_audio.aac` 沙盒路径。
- **[x] ① 已修复** — `hibiki/lib/src/anki/ankimobile_repository.dart` 改为短生命周期 localhost 媒体服务 URL；`hibiki/ios/Runner/AppDelegate.swift` 增加 iOS 后台任务保持导入窗口；`hibiki/lib/src/sync/immersion_mine_payload.dart` 规范化 form-encoded 文本并剔除沉浸音频临时路径。
- **[x] ② 已加自动化测试** — `hibiki/test/anki/ankimobile_repository_test.dart` 覆盖 AnkiMobile 字段产出可下载媒体 URL；`hibiki/test/sync/immersion_mine_payload_test.dart` 覆盖 `+`/`%xx` 还原、`C++` 不误伤、临时音频路径剔除。
- **备注**：对照 Hoshi Reader：Hoshi 通过 AnkiConnect `storeMediaFile` / 直接媒体文件名引用实现，字段里不放 `data:` 或应用沙盒路径；iOS AnkiMobile 端改为等价的可下载媒体 URL 交给 AnkiMobile 导入。
