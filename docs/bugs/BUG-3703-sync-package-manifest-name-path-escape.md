## BUG-3703 · sync-package-manifest-name-path-escape
- **报告**：2026-10-23（用户：审计导入路径时发现）
- **真实性**：✅ 真 bug。`importDictionaryPackage` 取 manifest 的 `dictionary.name` 直接 `p.join(dictionaryResourceRoot, name)` 当落地根（`packages/fushi_engine/lib/sync/sync_asset_package_service.dart` `importDictionaryPackage`）；`_extractResourcesInIsolate` 的 `isWithin` 校验以这个**已被篡改的根**为基准，`name = "../x"` 时资源条目本身干净也能写到词典目录之外。`importLocalAudioPackage` 的 `dbFileName` 同理（`../outside.db` 让导入方接管暂存目录外的任意文件）。包来自已配对对端，对端被攻破或恶意即可利用。
- **[x] ① 已修复** — 新增 `_requireSinglePathSegment`：两处 manifest 名字必须是单个路径段（拒 `..` / 分隔符 / 绝对路径 / NUL），不合法直接 `FormatException`，不改写成安全名（词典名同时是 DB 主键，改写会让资源目录与 DB 行对不上）。C++ 导入器 `sanitize_title` 产出的合法词典名本就不含分隔符、不以 `.` 结尾，不误伤。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_asset_package_service_test.dart`：`rejects dictionary name "…" that escapes the root`（6 种越界名）、`rejects dbFileName that points outside the staging dir`。
- **备注**：
