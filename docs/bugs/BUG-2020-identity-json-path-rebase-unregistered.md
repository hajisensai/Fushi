## BUG-2020 · 刮削 P1 新增的 identityJson 两列漏登记 kPathRebaseColumns，合入即把 develop 打红
- **报告**：2026-09-01（合并后跑目录枚举型守卫整批时发现，非用户报告）
- **真实性**：✅ 真 bug。PR #1126（刮削重设计 P1，v94）给 `VideoDownloadJobs` 与 `VideoDownloadSubscriptions` 各加了一列 `identityJson`（`packages/fushi_core/lib/src/database/tables.dart:2066` / `:2244`），但没有在 `fushi/lib/src/storage/path_rebase_coverage.dart` 的 `kPathRebaseColumns` 里登记。合入 develop 后 `test/storage/path_rebase_coverage_guard_test.dart` 立即变红：
  ```
  Expected: empty
    Actual: ['VideoDownloadJobs.identityJson', 'VideoDownloadSubscriptions.identityJson']
  ```
- **为什么定向测试挑不到**：该守卫属于**目录枚举型**——它现场枚举 `tables.dart` 的全部路径形 `TextColumn` 并与登记表比对。一条改「视频下载 / 刮削身份」的 PR，定向测试会挑 `test/media/video/**`、`test/pages/video_*`，**没有人会想到去跑 `test/storage/path_rebase_coverage_guard_test.dart`**。按名字挑测试就永远挑不到它，漏掉不是概率问题而是必然。这正是 CLAUDE.md「合并后必跑目录枚举型守卫整批」那条规则的由来形态，本次是它第 N 次生效。
- **[x] ① 已修复** — 两列判定为 `PathRebaseKind.notAPath` 并登记。判定依据是沿写入方核实的，不是看列名猜：写入点 `video_download_pipeline_service.dart:857` 是 `encodeVideoMediaReference(request.media)`，而 `VideoMediaReference`（`fushi/lib/src/media/video/discovery/video_discovery_provider.dart`）的全部字段是 `providerId`/`mediaId`/`title`/`originalTitle`/`aliases`/`year`/`season`/`episode`/`tmdbId`/`imdbId`/`tvdbId`/`anidbId`/`anilistId`/`bangumiId`/`externalIds`(Map<String,String> 的 namespace→id) —— **没有任何路径字段**，序列化出的 17 个键同样没有。所以它不需要在 `DataRootMigrator` 里改写。
- **[x] ② 已加自动化测试** — 守卫本身即测试（`path_rebase_coverage_guard_test.dart` 第 1 条）。修复前实测 `FAILED`（上面那两列），修复后 `FLUTTER TEST VERDICT: PASSED - 10 tests ran, all tests passed`。该守卫是登记制：将来再加路径形列而不登记，同样会直接红。
- **备注**：漏登记的真实代价不是「测试红」，而是——**如果它真是路径而漏登记，用户换数据位置后这一列指向的内容会全部失效**。所以正确做法是显式判定并写明理由，而不是把列名加进白名单了事。
