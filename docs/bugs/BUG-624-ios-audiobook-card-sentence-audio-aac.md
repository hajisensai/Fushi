## BUG-624 · iOS 有声书制卡句音频仍以 .aac localhost URL 入卡
- **报告**：2026-07-07（用户：wight）
- **真实性**：✅ 真 bug。用户真机截图显示有声书制卡后卡片字段里直接出现 `http://127.0.0.1:53069/media/1-sentence.aac`，与 BUG-562 视频句音频的 AnkiMobile `.aac` localhost URL 残留同类。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki/mining.part.dart:88`：书籍/有声书 `_prepareMiningContext()` 仍硬编码输出 `sentence.aac`，没有使用视频制卡已验证的 `immersionMiningAudioExtension()` 平台选择；AnkiMobile 对 `.aac` 裸流 URL 不当作可下载媒体，因而字段保留可见 URL 且音频不可播。
- **[x] ① 已修复** — `15e14f84d`：`hibiki/lib/src/pages/implementations/reader_hibiki/mining.part.dart` 的书籍句音频输出改为 `sentence.${immersionMiningAudioExtension()}`；iOS 生成 `.m4a` 供 AnkiMobile 正常识别下载，桌面/Android 继续生成 `.aac` 避免桌面 ffmpeg-min 缺 mp4/ipod/m4a muxer 的 BUG-460 回归。
- **[x] ② 已加自动化测试** — `15e14f84d`：`hibiki/test/utils/misc/sentence_audio_ffmpeg_routing_guard_test.dart` 把旧的“book sentence-audio 必须硬编码 `.aac`”守卫改为平台自适应守卫，并断言不得硬编码 `sentence.aac` / `sentence.m4a`。
- **备注**：已先跑红灯确认守卫能抓到当前硬编码 `sentence.aac`，再修实现；仍需 iOS 真机上从有声书原路径实际制一张卡，确认 AnkiMobile 字段不再保留 localhost URL。
