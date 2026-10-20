## BUG-3622 · 补刮账本把含凭据的配置指纹明文落盘
- **报告**：2026-10-20（排查 BUG「系列封面出不来 / 集数重复」时在用户 `%APPDATA%\Fushi\Fushi\video_scrape_sweep_ledger.json` 里发现）
- **真实性**：✅ 真 bug。账本 `fingerprint` 字段原样是 `VideoSourceScrapeGlobalConfig.runtimeFingerprint`（`packages/fushi_engine/lib/media/video/metadata/video_source_scrape_config.dart:178-194`）的 `\u0000` 拼接串，含 `tmdbApiKey`（发布版是 CI 注入的内置 key）、`anidbUsername`、`anidbPassword` 明文；`VideoScrapeSweepLedger.save`（`packages/fushi_engine/lib/media/video/metadata/video_scrape_sweep_ledger.dart:135`，修前）直接写进 support 目录。用户拷目录 / 整盘备份 / 发给别人排查就会带出账号密码。app 与无头服务端（`packages/fushi_server/lib/src/video_scrape_host.dart:68`）同一份账本类。指纹只做相等比较、从不解析回来。
- **[x] ① 根因修复** — `ensureLoaded` 把指纹换成 `sha256:<hex>` 摘要后再存内存与落盘（`VideoScrapeSweepLedger.fingerprintDigest`）。兼容旧文件：盘上值等于本次明文时视为同一套配置，只改写成摘要、不清 `attempted` / `transient`，升级不触发一轮重刮。
- **[x] ② 自动化测试** — `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`：「账本不落明文配置指纹（含凭据），只落摘要」断言文件里没有密码 / key 子串、字段等于摘要；「旧版明文指纹的账本：同一套配置不清账、不重刮，并改写成摘要」。
- **备注**：已经落过明文的旧文件在下一次补刮存账时被改写成摘要；改写前该文件仍含明文。若该目录曾被分享出去，应修改 AniDB 密码。
