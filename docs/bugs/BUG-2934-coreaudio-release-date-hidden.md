## BUG-2934 · CoreAudio 发现页把纸书初版日期当有声书日期展示
- **报告**：2026-10-04（用户：截图「響け！ユーフォニアム」各卷日期全是 2013-12-19，「京吹有声书都是在陆续上」）
- **真实性**：✅ 真 bug（数据契约错用）。`fushi/lib/src/media/discovery/sources/core_audio_discovery_source.dart` 原把目录 `release_date` 解析进 `CoreAudioVolume.releaseDate`（原 :140）并原样填进 `DiscoveryResourceItem.dateText`（原 :404）。上游 `https://coreaudio.netlify.app/data.json` 的 `release_date` 是**纸书初版日期**，且同系列各卷常复制第 1 卷的值：京吹 8 卷全是 2013-12-19（第 1 卷文库本发售日），而对应 ASIN 是 2025 年陆续上架的有声书；全目录 365 个多卷系列各卷共用同一日期。目录里没有任何字段给出有声书自身发售日，无法在本端纠正。
- **[x] ① 已修复** — 删除 `CoreAudioVolume.releaseDate` 字段与解析、不再填 `dateText`（该字段唯一消费者就是这一行）；发现页不再展示错误日期。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/sources/core_audio_discovery_source_test.dart`：语料带 `release_date` 时，browse 出的各卷 `dateText` 一律为 null。
- **备注**：截图里 `TMW (2155103)` 是 `kCoreAudioTmwPartBySource` 只映射到 Part 13、新 torrent 未登记，显示为原始 id，不影响下载，本条不处理。
