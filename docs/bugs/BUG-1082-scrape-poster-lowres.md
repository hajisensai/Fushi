## BUG-1082 · TMDB刮削海报w500缩略图发糊非满分辨率
- **报告**：2026-07-25（用户）
- **真实性**：✅ 真 bug。用户反馈刮削海报很糊，要求默认满分辨率。逐源核查：Bangumi 取 `images.large`（各源最高档）、离线库取 `record.picture`（MAL CDN 原图）、落盘 `poster_downloader.dart` 原样写字节无重编码、渲染 `resizedFileImage` 解码上限 720 高于封面墙格子物理像素——均非瓶颈。唯一根因是 TMDB 源。
- **根因**：`tmdb_client.dart:33` `posterBase='https://image.tmdb.org/t/p/w500'` 钉在 **w500（500px 宽缩略档）**，非 `original`（满分辨率原图）。凡 TMDB 命中的电影/日剧，落盘只有 500px 宽，放大到高 dpr 大格子发糊。
- **[x] ① 已修复** — commit（见末）。`tmdb_client.dart:33` `w500` → `original`。落盘无损，渲染层 `resizedFileImage` 解码上限自会按需降采样，不因原图更大而展示变慢。Bangumi / 离线库无需改。
- **[x] ② 已加自动化测试** — `test/media/video/scraper/tmdb_client_test.dart` 断言 `posterUrl == 'https://image.tmdb.org/t/p/original/tv.jpg'`（原断言 w500，随修复更新，守住尺寸段不再回退到缩略档）。
- **备注**：属「统一各媒体页服务」P1 刮削域。非刮削卡（16:9 抽帧封面在 2:3 槽的高斯模糊垫底层，`poster_cover_image.dart` sigma14）是另一回事，属设计观感非分辨率，本 bug 不涉及。
