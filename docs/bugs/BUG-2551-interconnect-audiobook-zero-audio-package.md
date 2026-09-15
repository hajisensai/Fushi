## BUG-2551 · 互联同步有声书只过去字幕、音频丢失且永不重推
- **报告**：2026-09-15（用户：勾了「上传有声书文件」，对端只拿到模型生成的字幕，音频没过去；重试也无效，只能手动在另一台设备重新下载音频）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/sync/sync_asset_package_service.dart:319`（srt-backed 导入分支）——必需资源校验是 `.map()` 里的**逐元素**检查，`audioPaths` 是空数组时一次都不执行，零音频包一路静默落库。

  完整故障链（互联通道下 `audiobooks` / `srt_books` / `audio_cues` 三张表**只能**经 `.fushiaudio` 包到达对端，所以「字幕过去了」本身就证明过去的是个零音频包）：

  1. 导出端 `exportAudioDatabasePackage`（同文件 `:186-202`）解析不出音频时**刻意不整包失败**（BUG-1577 的设计：一本书缺一个文件不该中断整次同步，拒绝落库交给导入端）。folder 模式目录失效 / 清单为空 → `audioPaths: []`，缺失只记进 `manifest.missingResources`。
  2. 导入端空数组漏判 → 字幕 / 对齐 / 封面照常落库，`audioPathsJson` 写成 `"[]"`，host PUT 返回 **200**，同步报告 `audiobooksExported++` 记一次成功。
  3. 书架断链徽章也看不出来：`_srtBookHasMissingAudio`（`fushi/lib/src/pages/implementations/reader_history/books.part.dart:390`）对空列表返回 false = 「无断链」，红徽章和「重新定位音频」入口都不出现。
  4. **吸收态**：host 的 `listAudiobooks()`（`packages/fushi_engine/lib/sync/local_library_host_service/audiobooks.part.dart:14`）纯按 DB 行枚举、一次 `File.exists()` 都没有，`RemoteAudiobookInfo` 也没有任何音频能力位。于是下一轮 sweep 的 `remoteKeys` 命中该 key → 永不重推；本端若是坏的那侧，`localKeys` 同样命中 → 永不拉回。用户再点多少次「立即同步」都不会自愈。

  既有测试没拦住，是因为 `sync_orchestrator_live_audio_test.dart` 的 fixture 用的正是**空音频目录**的书，断言只数 `audiobooksImported` / `audiobooksExported`，从不问音频有没有落地——等于把 bug 行为当成正确行为钉死了。

- **[x] ① 已修复**（`cd60e82347`）— 三处，都在「存在性判据必须问磁盘、不能只问表」这一条根因上：
  - 导入端拒绝静默落坏书：`sync_asset_package_service.dart` srt-backed 分支对空 `audioPaths` 抛 `SyncAssetPackageIncompleteException`（srt-backed 的不变式是「EPUB + 音频 + 对齐」）；standalone 分支**有意不同**——纯字幕书本来就可以没有音频，只有「导出端声明了 audioRoot 却一个都枚举不出来」才算坏，靠新的 manifest 键 `unresolvedAudioRoots` 区分（旧包无此键 → 按旧行为放行）。
  - 清单下发音频能力位：`RemoteAudiobookInfo.hasAudio`（`bool?`，null = 旧 host 未知，消费方必须按旧行为放行），host `listAudiobooks()` 用与打包同源的判据填。
  - sweep union 两侧都改问磁盘：`fushi/lib/src/sync/sync_orchestrator/audiobooks.part.dart` 的 `localKeys` 用 `audiobookAudioIsIntact` 过、`remoteKeys` 排除 `hasAudio == false`。坏书不再是吸收态——本端坏 → 从 host 拉回；host 坏 → 本端重推覆盖。
  - 共享判据 `resolveAudiobookAudioFiles` / `audiobookAudioIsIntact` 提到 `sync_asset_package_service.dart` 顶层，打包 / host 清单 / client sweep 三处同源。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/audiobook_zero_audio_package_test.dart`（新建，8 条）：导出端下发 `unresolvedAudioRoots`；srt-backed 零音频导入抛且一行不落库；纯字幕书零音频仍合法放行；纯字幕书「声明了音频根却丢了」照样抛；`audiobookAudioIsIntact` 的断链 / 空清单 / 空目录判据；`hasAudio` 缺键 → null 而非 false 的 wire 契约。
  - `fushi/test/sync/sync_orchestrator_live_audio_test.dart`（+2 条自愈用例 + 修 fixture）：本端零音频坏书 → 从 host 拉回且拉回的能播；host 零音频坏书 → 本端好书重推覆盖。既有 pull 用例补了「拉回来的必须真能播」断言（原来只断言「有行」，正是 bug 藏身处）。
- **备注**：`hasAudio` 是 `/api/library/audiobooks` 清单里唯一问磁盘的字段，其余全是 DB 行的投影。旧 host 不下发 → `null`，**不能当 false**，否则每轮 sweep 都会朝旧 host 重推所有有声书。
