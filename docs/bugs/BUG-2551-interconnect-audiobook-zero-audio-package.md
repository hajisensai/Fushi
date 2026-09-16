## BUG-2551 · 互联同步有声书只过去字幕、音频丢失且永不重推
- **报告**：2026-09-15（用户：勾了「上传有声书文件」，对端只拿到模型生成的字幕，音频没过去；重试也无效，只能手动在另一台设备重新下载音频）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/sync/sync_asset_package_service.dart:319`（srt-backed 导入分支）——必需资源校验是 `.map()` 里的**逐元素**检查，`audioPaths` 是空数组时一次都不执行，零音频包一路静默落库。

  完整故障链（互联通道下 `audiobooks` / `srt_books` / `audio_cues` 三张表**只能**经 `.fushiaudio` 包到达对端，所以「字幕过去了」本身就证明过去的是个零音频包）：

  1. 导出端 `exportAudioDatabasePackage`（同文件 `:186-202`）解析不出音频时**刻意不整包失败**（BUG-1577 的设计：一本书缺一个文件不该中断整次同步，拒绝落库交给导入端）。folder 模式目录失效 / 清单为空 → `audioPaths: []`，缺失只记进 `manifest.missingResources`。
  2. 导入端空数组漏判 → 字幕 / 对齐 / 封面照常落库，`audioPathsJson` 写成 `"[]"`，host PUT 返回 **200**，同步报告 `audiobooksExported++` 记一次成功。
  3. 书架断链徽章也看不出来：`_srtBookHasMissingAudio`（`fushi/lib/src/pages/implementations/reader_history/books.part.dart:390`）对空列表返回 false = 「无断链」，红徽章和「重新定位音频」入口都不出现。
  4. **吸收态**：host 的 `listAudiobooks()`（`packages/fushi_engine/lib/sync/local_library_host_service/audiobooks.part.dart:14`）纯按 DB 行枚举、一次 `File.exists()` 都没有，`RemoteAudiobookInfo` 也没有任何音频能力位。于是下一轮 sweep 的 `remoteKeys` 命中该 key → 永不重推；本端若是坏的那侧，`localKeys` 同样命中 → 永不拉回。用户再点多少次「立即同步」都不会自愈。

  既有测试没拦住，是因为 fixture 本身就在固化 bug 行为：`sync_orchestrator_live_audio_test.dart` 用的正是**空音频目录**的书、断言只数 `audiobooksImported` / `audiobooksExported`，`reader_remote_interconnect_test.dart` 的 BUG-2505 用例更是直接插了一条**没有 audioRoot 也没有 audioPathsJson** 的 Audiobooks 行来代表「本端已有有声书」。两处都从不问音频有没有落地。

  **用户追加报告**（同一病根的第四 / 第五处消费点）：「其实是能下载的，但如果第一次下载没下成功，就下不了有声书了」。手动下载的两个入口判据同样是「有没有 DB 行」——`remote.part.dart` 的 `localAudiobookKeys`（喂给 BUG-2505 的书卡菜单候选）与 standalone 占位卡的 `localUids`。一次落成零音频 / 半写的行之后，占位卡、书卡菜单、对比弹窗（它要求 `bookKey == null`，本地一有书就永远不适用）**一个都不剩**，零 UI 路径可重下；唯一残存的自愈是需要用户开着「上传有声书文件」开关的 sweep，而 standalone 连那条都被排除在 union 之外。

- **[x] ① 已修复**（`cd60e82347`）— 三处，都在「存在性判据必须问磁盘、不能只问表」这一条根因上：
  - 导入端拒绝静默落坏书：`sync_asset_package_service.dart` srt-backed 分支对空 `audioPaths` 抛 `SyncAssetPackageIncompleteException`（srt-backed 的不变式是「EPUB + 音频 + 对齐」）；standalone 分支**有意不同**——纯字幕书本来就可以没有音频，只有「导出端声明了 audioRoot 却一个都枚举不出来」才算坏，靠新的 manifest 键 `unresolvedAudioRoots` 区分（旧包无此键 → 按旧行为放行）。
  - 清单下发音频能力位：`RemoteAudiobookInfo.hasAudio`（`bool?`，null = 旧 host 未知，消费方必须按旧行为放行），host `listAudiobooks()` 用与打包同源的判据填。
  - sweep union 两侧都改问磁盘：`fushi/lib/src/sync/sync_orchestrator/audiobooks.part.dart` 的 `localKeys` 用 `audiobookAudioIsIntact` 过、`remoteKeys` 排除 `hasAudio == false`。坏书不再是吸收态——本端坏 → 从 host 拉回；host 坏 → 本端重推覆盖。
  - **书架两个手动下载入口同样改问磁盘**（用户追加报告：「其实是能下载的，但第一次下载没下成功就下不了有声书」）：`reader_history/remote.part.dart` 的 `localAudiobookKeys` 只收音频完好的 bookKey（否则一本零音频坏行会把 BUG-2505 好不容易补上的书卡菜单入口又挡掉）；standalone 占位卡的 `localUids` 判据加一条——对端 `hasAudio == true` 且本地同 uid 行音频不完好时**保留占位卡**。后者**刻意**要求两个条件同时成立：纯字幕书合法地没有音频，一律按「音频不完好」留卡会让纯字幕书永远挂着一张下不完的下载卡。
  - **导入写库段包进 `_db.transaction`**（srt-backed 与 standalone 两处）：`upsertAudiobook` → `upsertSrtBook` → tags → `replaceCuesForBook` 原本逐条 await，任一步抛出（磁盘满、标签表冲突、cue 批量写失败）都会把前面写下的行留在库里，而所有入口判据都是「有没有这行」——半成品行一落，占位卡 / 书卡菜单 / 对比弹窗同时消失。判据问磁盘只解决一半，写入不原子的话判据再对也会被半成品骗过去。解压刻意留在事务外（文件操作耗时长，包进去等于整段持锁；解压残留不会让任何入口消失）。
  - 共享判据 `resolveAudiobookAudioFiles` / `audiobookAudioIsIntact` 提到 `sync_asset_package_service.dart` 顶层，打包 / host 清单 / client sweep / 书架两个入口五处同源。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/audiobook_zero_audio_package_test.dart`（新建，8 条）：导出端下发 `unresolvedAudioRoots`；srt-backed 零音频导入抛且一行不落库；纯字幕书零音频仍合法放行；纯字幕书「声明了音频根却丢了」照样抛；`audiobookAudioIsIntact` 的断链 / 空清单 / 空目录判据；`hasAudio` 缺键 → null 而非 false 的 wire 契约。
  - `fushi/test/sync/sync_orchestrator_live_audio_test.dart`（+2 条自愈用例 + 修 fixture）：本端零音频坏书 → 从 host 拉回且拉回的能播；host 零音频坏书 → 本端好书重推覆盖。既有 pull 用例补了「拉回来的必须真能播」断言（原来只断言「有行」，正是 bug 藏身处）。
  - `fushi/test/sync/audiobook_zero_audio_package_test.dart` 再加 1 条：cue 段中途抛 → 已写下的 Audiobooks / SrtBooks 行一并回滚（验事务）。
  - `fushi/test/pages/reader_remote_interconnect_test.dart`（+1 条 + 修 fixture）：本端有声书行零音频时书卡菜单**仍**露「从对端下载有声书」。既有的 BUG-2505「本端已有有声书 → 不露入口」用例插的正是一条零音频行（没有 audioRoot / audioPathsJson），已给它补上真实音频——否则它验的其实是「零音频也算已有」，与本次修复正好相反。
- **备注**：`hasAudio` 是 `/api/library/audiobooks` 清单里唯一问磁盘的字段，其余全是 DB 行的投影。旧 host 不下发 → `null`，**不能当 false**，否则每轮 sweep 都会朝旧 host 重推所有有声书。
