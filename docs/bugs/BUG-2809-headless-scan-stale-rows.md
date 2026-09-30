## BUG-2809 · 无头服务端删掉视频文件后条目与刮削资料残留
- **报告**：2026-09-30（用户：lllzt）
- **真实性**：✅ 真 bug。扫描器只做**单向**导入，从不反向回收「库里有、磁盘上没有」的行：
  `packages/fushi_server/lib/src/library_scanner.dart` 的 `_scanVideos` 只遍历磁盘上现存的
  文件（`dir.list(...)` → `saveVideoBook` / 跳过重复），文件被删后对应行再也不会被任何一次
  扫描访问到；全仓也没有按缺失文件回收行的 reaper（唯一的 `orphan` 是封面 GC，方向相反）。
  行留在 `video_books` 里，挂在其上的刮削资料（`video_scrape_meta` / `video_metadata_*`）
  与封面文件因此一并残留：级联本来会生效（`PRAGMA foreign_keys = ON`，
  `packages/fushi_core/lib/src/database/database.dart:195`），但**行从来没被删过**，级联没有
  触发点。客户端经 `/api/library/videos` 读的 `allVideoBooks()` 也不做文件存在性过滤
  （`packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart:25`），
  所以条目照旧列得出来、`status` 的 `videos` 计数也不归零。
- **[x] ① 已修复** — `322483da39f`：新增引擎对账模块
  `packages/fushi_engine/lib/media/video/video_library_prune.dart`（枚举现存文件 → 挑失效行 →
  走 `deleteVideoBooksAndReclaimAssets` 回收），扫描器接入并加护栏；顺带把 O(n²) 的去重改成
  一次性路径集合。
- **[x] ② 已加自动化测试**（审查补修后的数目见备注）—
  `packages/fushi_engine/test/media/video/video_library_prune_test.dart`（10 条：判据 / 二次确认 /
  网络流 / 库根缺失 / 比例护栏 / dryRun / 幂等 / 库根外条目）与
  `packages/fushi_server/test/library_scanner_prune_test.dart`（3 条：删文件后重扫回收行与刮削
  资料 / `pruneMissing: false` 只导入不清理 / 重扫不重复）。
- **备注**：
  - `book` / `manga` 根**本轮不对账**：它们的正文被拷进
    `<documents>/fushi_books/<bookKey>/`（`packages/fushi_engine/lib/epub/epub_importer.dart`
    的 `epubPath` 只存文件名），行里没有源文件路径，判不出源文件是否被删；扫描时打一条诊断
    日志如实留痕，不假装已经管了。
  - 护栏（有意）：库根不存在 → 拒绝执行（NFS 未挂载 / 空挂载点会把整库删光）；失效占比
    超过阈值（默认 `>50%` 且 `>10` 条）→ 拒绝执行。可用 `--no-prune` / 服务端配置
    `scan_prune: false` 整体关闭。
  - **合并前审查补修**（W1ght，接手第三方 PR #1817）——原 PR 的护栏有洞，会连进度与
    刮削身份一起误删：
    1. 护栏分母被本轮新入库的行稀释：扫描先导入后对账，整库改名 / 搬家时旧 20 行失效、
       新 20 行入库，20/40 恰好不越过 0.5 → 旧行整批删掉。改为只在**导入前的基线行**
       上判失效与算比例（`pruneMissingVideoRows(baselineBookUids:)`）。
    2. 空挂载点 / 子挂载点：库根在但一个视频都枚举不到 → 拒绝（小库也拦，比例护栏的
       绝对下限不适用）；失效行最近的现存上级目录是空的或列不出来 → 视为脱挂、不判失效
       （`isVideoPathInDetachedSubtree`）。代价（有意）：删光某个子目录里的视频但留着
       空目录时，这些行要等「移除并清理」或放回文件。
    3. 部分删除失败时计数报 0：改取 `VideoBooksDeleteException.deletedCount`；租约改为
       对账自己先取（`VideoScrapeOperationGate.tryEnterOperation`），不再用 `on StateError`
       猜——那会把数据库自身的 StateError 当「租约被占」吞掉。
    4. 「移除并清理」遇到库根已不存在（最常见用法）时什么都没清、配置却照样移除，行成
       永久孤儿：purge 是显式意图，改用 `force`（只留「文件确实不存在」判据）；对账没做成
       则回 409、保留库根。
    5. `serve --no-prune` 只管启动那一次扫描：改存进 `AdminContext.pruneOverride`，本进程
       所有扫描生效（请求显式给的仍优先）。
    6. 多集合集行（`playlistJson` 非空）只看主路径判不了整行失效 → 不动。
    测试：引擎 16 条（新增空库根 / 子挂载点 / 基线 / 合集 / 租约 / force 缺根）、
    `library_scanner_prune_test.dart` 5 条（新增改名、空库根）、新增
    `packages/fushi_server/test/admin_library_purge_test.dart` 3 条（purge 缺根 / 409 /
    `--no-prune` 覆盖范围）。
  - 顺带修：`_scanVideos` 原先逐文件调 `isDuplicateVideoPath`，而它内部每次都
    `listAll()` 全表读（`packages/fushi_engine/lib/media/video/video_book_repository.dart:1302`），
    整个扫描是 O(n²)；改为一次性路径集合。
