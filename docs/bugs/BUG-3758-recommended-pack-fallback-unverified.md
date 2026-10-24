## BUG-3758 · recommended-pack-fallback-unverified
- **报告**：2026-10-23（用户：审计导入路径时发现）
- **真实性**：✅ 真 bug。两个清单主机都拉不到时，`RecommendedPackDownloadController` 回退到内置 Google Drive 直链且**不带 sha256**（`fushi/lib/src/onboarding/recommended_pack_download_controller.dart` 回退分支）；`RecommendedPackDownloader` 只在 `sha256Hex != null` 时校验（`recommended_pack.dart` 单流收尾），于是这条线路下来的 9.5 GB 原样进备份导入（覆盖整库与偏好）。清单本身的 `sha256` 也是可选字段，缺了同样不校验。
- **[x] ① 已修复** — `sha256Hex` 改为必填：清单缺摘要整份判无效（回退）；回退线路钉死 `kRecommendedPackWholeFileSha256`（取自线上清单 `2026-10-16-r2`，其 `url` 就是这份 Drive 文件）；`fromManifest` 遇到手搓的无摘要清单抛 `ArgumentError`；单流收尾无条件校验。Drive 上原地换文件时须同步改常量，否则回退线路以摘要不符失败（有意）。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/recommended_pack_manifest_test.dart`：`missing sha256 rejects the whole manifest (BUG-3758)`、deflate 子清单缺摘要退回顶层、回退摘要为 64 位小写 hex。
- **备注**：
