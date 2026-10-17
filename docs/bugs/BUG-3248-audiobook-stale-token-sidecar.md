## BUG-3248 · 互联更新字幕后旧逐 token sidecar 残留
- **报告**：2026-10-10（PR #2023 审查遗留疑点）
- **真实性**：✅ 真 bug（代码路径确认 + 集成测试复现）。`packages/fushi_engine/lib/sync/sync_asset_package_service.dart` `importAudioSubtitlePackage`（「只更新字幕」）与 `importAudioDatabasePackage` / `_importStandaloneSrtPackage`（「重新下载有声书」）都把包解压进同一个落地目录、原位覆盖；host 这次没有 `<字幕>.tokens.jsonl`（换成了非转录字幕 / 重新转录没产出）时，本机目录里上一版的 sidecar 原样留在新字幕旁边。`attachAsrCueTokenTiming`（`packages/fushi_engine/lib/media/audiobook/audiobook_alignment_service.dart:85`）只认「同名 + 行数 == cue 数」，行数恰好相等时把旧的逐 token 时间挂到新 cue 上，跳播全偏且不报错。另：整包导出 `exportAudioDatabasePackage` 根本不带 sidecar（只有字幕包带），「重新下载有声书」后逐 token 时间与字幕版本对不上。
- **[x] ① 已修复** — 三条导入路径解压后都调 `_dropStaleTokenSidecar`：包里没登记该字幕的 sidecar 就删掉落地目录里同名的旧 sidecar（字幕路径恒在包的落地目录内，不碰用户目录）；整包导出与字幕包同口径带上 sidecar。提交 `cf8743e5c6`（`fix(interconnect): drop stale token sidecars on audiobook re-fetch`）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_audiobook_refetch_test.dart`「host 没有 tokens sidecar 了 → 更新字幕 / 重新下载都删掉本机旧 sidecar」（真 FushiSyncServer + 真导出/导入：整包下载带 sidecar；host 删 sidecar 后只更新字幕 / 整本重下都不再残留）。
- **备注**：
