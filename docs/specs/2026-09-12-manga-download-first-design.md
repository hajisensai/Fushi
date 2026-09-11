# 在线漫画「下载后才能看」与阅读器外 OCR 设计

- 日期：2026-09-12
- 状态：已拍板（用户 2026-09-11 / 09-12 两轮决策），分阶段落地
- 取代：`2026-07-25-manga-online-source-design.md` §5「阅读期懒 OCR」与 O3/O4 的在线直读定位；`2026-07-24-manga-ocr-design.md` 的「D：单框补扫（P4）」
- 相关 bug：BUG-2449（OCR 任务所有权）、BUG-2450（封面重试）、BUG-2457（beam 早停）

## 1. 决策（不再讨论）

1. **在线漫画（Mihon / Aidoku / 互联对端）强制下载后才能看**。点章节即入队下载，下载完成才可读。在线直读、阅读期页图缓存（`reader-cache/`）、在线懒 OCR 整条删除。
2. **阅读器内不触发任何 OCR**。顶栏整卷按钮、点击即识别、手动框选重识别（含撤销）全部移除。阅读器只保留：观察外部已启动任务的进度 HUD、逐页热替换、取消按钮。
3. **OCR 只在阅读器外触发**：作品页「识别本章 / 识别全部已下载」、书架本地漫画长按「整卷 OCR」、下载完成钩子「完成后自动识别」。任务一律经 `MangaOcrJobRegistry.start`（BUG-2449），阅读器按 bookKey + 目录接回进度。
4. **已有在线书架条目的阅读进度保留**：沿用现有 `epub_books` 那一行（`bookKey` / `uid` 不变），`manga_chapter_states(bookUid, chapterKey)` 零迁移。
5. **识别模型不换**（2026-09-11 对拍：PP-OCRv6 CER 好看但 0/5 全对、错在小假名/异体字/引号）。后续独立批次做「行检测切块逐行喂 manga-ocr」。

## 2. 数据结构

### 2.1 目录（统一到 `fushi_books`）

```
<documents>/fushi_books/<bookKey>/
  cover.*                       # 既有
  manga.json                    # 在线条目：占位 {"pages":[]}（保持既有契约，阅读器不读它）
  chapters/<digest>/
    manga.json                  # 该章 payload：pages[{url,width,height,blocks}]，真实尺寸
    images/page-000001.<ext>
```

- `digest = sha256(chapter.key).substring(0, 24)`（与既有 `chapterDirectory()` 同算法，只换根目录）。
- 在线条目的 `extractDir` 从 `<runtimeRoot>/library/<bookKey>` **迁到** `<fushi_books>/<bookKey>`：`OnlineMangaLibraryService.ensureBookDirectory(row)` 首次访问时移动目录（封面 + 占位 manga.json）并更新行；`bookKey` / `uid` 不变。三个运行时根下的 `library/`、`reader-cache/` 目录随后可删。
- 本地漫画（导入 / mokuro.moe 卷）维持 `<fushi_books>/<bookKey>/{manga.json, images/}` 单目录单 payload，**不改**：它已经是标准形状，改它没有收益。
- 一章「已下载」判据 = `chapters/<digest>/manga.json` 存在且 `pages` 非空且每个 `images/` 文件存在（`MangaStorage.resolvePageFilePath` 守穿越）。判据只写一处：`MangaChapterStorage.isDownloaded`。

### 2.2 表 `manga_download_jobs`（schema v102 → v103，device-local）

| 列 | 类型 | 说明 |
|---|---|---|
| `job_id` | text PK | `sha256(kind NUL bookKey NUL chapterKey)[:32]`，同章重复入队幂等 |
| `kind` | text CHECK | `chapter`（在线章节）/ `mokuro_volume`（mokuro.moe 卷，替代内存队列） |
| `book_key` | text | 在线条目 bookKey；mokuro 卷为 `mokuro:<seriesName>` |
| `chapter_key` | text | 章 key；mokuro 卷为卷名 |
| `runtime` | text | `mihon` / `aidoku` / `interconnect` / `mokuro_moe` |
| `title` / `chapter_title` | text | 展示用 |
| `status` | text CHECK | `queued` / `running` / `done` / `failed` / `cancelled` |
| `pages_done` / `pages_total` | int | 进度 |
| `attempt_count` | int | 自动重试次数（退避 2s/8s/20s，与 mokuro 队列既有语义一致） |
| `last_error` | text? | |
| `auto_ocr` | bool | 完成后自动起 OCR（Lens 引擎除外） |
| `created_at` / `updated_at` / `completed_at` | int 毫秒 | |

- 唯一索引 `(kind, book_key, chapter_key)`。
- 不复用 `video_download_jobs`：其 CHECK 强制 magnet / backend / fingerprint 非空，stage 限 torrent 六段；塞章节任务要造假值。
- 登记：`backup_service.dart` device-local 两处、`backup_merge_engine.dart` 跳过清单、`path_rebase_coverage.dart`（本表无路径列，登记 `none`）、`migration_v63_*` 的「升级不得新增表」白名单、全部 `schemaVersion` 字面量 +1、新建 `migration_v103_manga_download_jobs_test.dart`。

### 2.3 在线条目 `sourceMetadata` v3

在 v2 基础上加两个可选位：`subscribed: bool`（追更）、`autoDownload: bool`（新章自动入队）。`tryParse` 兼容 v1/v2（缺省 false）。**不加 DB 列**。

## 3. 运行时适配器契约

`OnlineMangaRuntimeAdapter.openChapter(...)` 删除，改为两段式：

```dart
Future<List<OnlineMangaPageRef>> resolveChapterPages(entry, chapter);  // 页表
Future<Uint8List> fetchPage(OnlineMangaPageRef page);                   // 单页字节（可取消）
```

- Mihon：`runtime.getPages` + `fetchImageRequest`（已有，`CancellableMihonRuntime`）。
- Aidoku：`runtime.getPages` → `aidokuImagePagesFrom` + 既有 `_AidokuMangaReaderSession._file` 的取图逻辑（UA / Referer / cookie jar / 100 MiB 上限）迁成纯函数。
- 互联：`backend.remoteMangaManifest` + `fetchRemoteMangaPage`。
- 三个 `OnlineMangaReaderChapter` 实现与在线 `MangaReaderSession` 全部删除；`LocalMangaReaderSession` 是阅读器唯一会话。

## 4. 下载服务 `MangaDownloadService`（app 级，挂 `AppModel`）

- 单 worker 串行取任务（`status=queued` 按 `created_at`），任务内 4 并发取页；每页落 `images/page-NNNNNN.<ext>` 临时名 → rename；全部页齐后写章 `manga.json`（真实尺寸经 `mangaImageDimensions`）→ `status=done`。
- 失败：`attempt_count < 3` 退避重排；否则 `failed` 留 `last_error`。取消：`cancelled` 并删半成品目录。
- 启动时把 `running` 复位为 `queued`（进程死亡后续跑）。
- 完成钩子：`auto_ocr && 引擎偏好 != googleLens` → `MangaOcrJobRegistry.start(章目录任务)`。Lens 需要用户告知同意，后台不能替用户点；`auto` 偏好下无离线引擎就跳过并记日志。
- mokuro.moe 卷：`kind=mokuro_volume` 的任务由同一 worker 调既有 `MokuroMoeVolumeDownloader`；`MokuroMoeDownloadQueue`（内存）删除，目录页「下载已选 / 下载全部」直接入表。
- 下载中心：新增 `MangaDownloadTasksSection` 读表输出 `DownloadTaskEntry(kind: manga)`，取代 `MokuroMoeTasksSection`。
- **合规**：章节下载服务本身**不**挂 `StoreRestrictedCapability.downloads`——互联对端漫画在 iOS 是保留的在线源，改成必须下载后读，若下载被门挡住就是死路。iOS 上任务进度在作品页章节行显示；下载中心面板仍受模块门控。Mihon / Aidoku / mokuro.moe 入口继续受 `onlineMangaSource` 门控（iOS 无入口）。

## 5. UI

- **作品页**（`manga_series_page.dart`）：章节行加下载状态位（未下载 / 排队 / 下载中带进度 / 已下载 / 失败）；点章节：已下载 → 开读，否则入队并 toast；主动作区「继续阅读」若目标章未下载则先入队；新增「下载全部」按钮 + `FushiSelectableChip`「完成后自动识别」；溢出菜单：下载 / 删除下载 / 识别本章 / 识别全部已下载；AppBar 书签图标 = 订阅开关（开订阅默认同时开自动下载，可在菜单里单独关）。
- **阅读器**：在线条目 `_loadBook` 解析 `chapters/<digest>` 后走本地分支；换章到未下载章 → toast「未下载，已加入队列」并停在当前章；Cloudflare 挑战 UI、在线几何回写、在线 OCR 分支全删。
- **书架**：本地漫画长按菜单加「整卷 OCR」（走 `MangaModule.openBookOcr` → `registry.start`），补上阅读器删掉的那个入口。
- **订阅**：`runOnlineMangaUpdateProbe` 6 小时探针里，`autoDownload` 条目的新章直接入队（复用 `newlyAppearedChapters` 判据）；不另起 Timer。

## 6. 分阶段

| 阶段 | 内容 | 依赖 |
|---|---|---|
| A | 删阅读器内 OCR 入口 + 书架「整卷 OCR」外部入口 + HUD 取消按钮 | — |
| B1 | `manga_download_jobs` 表 v103 + DAO + 迁移测试 + 三处登记 | — |
| B2 | 适配器改两段式 + `MangaDownloadService` + 目录迁移 + 阅读器切本地 + 删在线会话/直读/懒 OCR（**已落地**：分支 `manga-download-first`，BUG-2464；作品页章节行状态位 + 点章入队 + 溢出菜单「下载 / 删除下载 / 重试」也在这一批做了最小可用版，「下载全部 / 自动 OCR chip / 订阅」留 C） | A, B1 |
| C | 作品页下载状态与动作 + 订阅位 v3 + 探针入队 + mokuro 队列并表 + 下载中心分区 | B2 |

每阶段独立分支、独立测试、合入 develop 后跑目录枚举型守卫整批。

## 7. 刻意不做

- 不做 iOS 互联漫画的例外分支：它和其它运行时走同一条下载队列。
- 不把 mokuro.moe 卷改成多章条目：现状即标准本地书形状。
- 不做按作品学习更新相位：固定 6 小时探针够连载节奏。
- 不做「边下边读」：下载完成才可读是产品决策，不留半下载可读路径。
