## BUG-526 · 推荐词典下载链接失效
- **报告**：2026-07-02（用户：）
- **真实性**：✅ 真 bug。真实 App 里「下载推荐词典」选择 `surasura` / 默认 `JPDB Frequency` 后，`surasura` 在旧仓库重定向链里触发 macOS App TLS 校验失败，`JPDB Frequency` 返回 404。根因是 `packages/hibiki_dictionary/lib/src/formats/dictionary_downloader.dart:44` 的 MarvNC catalog 基础地址仍指向旧 `yomichan-dictionaries` raw 路径，`packages/hibiki_dictionary/lib/src/formats/dictionary_downloader.dart:458` 的 JPDB asset 名仍为不存在的 `JPDB.Frequency.List.zip`。
- **[x] ① 已修复** — MarvNC 推荐词典改为直连当前 `raw.githubusercontent.com/MarvNC/yomitan-dictionaries/...`，JPDB Frequency 改为 tag-pinned release `2022-05-09/Freq.JPDB_2022-05-10T03_27_02.930Z.zip`。（修复提交：本提交）
- **[x] ② 已加自动化测试** — `hibiki/test/dictionary/dictionary_downloader_catalog_guard_test.dart` 覆盖 MarvNC 直连 raw host 与 JPDB tag-pinned release asset。（测试提交：本提交）
- **备注**：`curl -I -L` 验证新 JPDB 与 surasura URL 均返回 200；修复前守卫测试在旧 host / 旧 asset 名上失败，修复后通过。
