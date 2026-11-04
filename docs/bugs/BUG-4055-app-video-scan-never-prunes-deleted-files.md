## BUG-4055 · app 本地视频来源重扫从不回收已删除文件，删掉的视频留在待确认刮削队列
- **报告**：2026-11-02（反馈 i5rQ5dMlBH，Windows 10 / app 3.0.0+19763：「视频刮削不存在的文件。我把那个视频删除之后，它把这视频也当成刮削的内容了，现在显示资料源不可用」；截图：后台任务 → 待确认 1 条「擅长作弄的高木同学.07.中日双语.720p.HDT…」，动漫文件，原因「资料源不可用」）
- **真实性**：✅ 现象属实、代码路径已坐实；根因处是一条**现行的有意语义**，按下文「拍板」选 B 修。
  - 待确认队列 / 自动补刮的数据源是刮削计划器，它只看库里的行：
    `VideoLibraryScrapeSweep._plannedWorks`（`packages/fushi_engine/lib/media/video/metadata/video_library_scrape_sweep.dart:391-426`）
    → `VideoSourceWorkPlanner.plan`（`packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart:84-86`，
    `allVideoBooks()` 按 `sourceId` 过滤，不看磁盘）。行在，作品就在计划里；没有身份就进待确认，被自动补刮一轮轮拿去问资料源。
  - 行为什么还在：app 的 `SourceLibraryScanner` 视频分支只做单向导入，**有意**不回收磁盘上暂缺的文件
    （`fushi/lib/src/media/source_library/source_library_scanner.dart:1128-1130` 注释「重扫复用已有成员且不删除缺失文件」；
    锁定测试 `fushi/test/media/source_library/source_library_scanner_test.dart:803-819`「暂缺磁盘文件不得破坏观看进度与用户资料」/
    「暂缺旧分集仍保留合集成员关系」，来自 2026-08-09 `c22490be86`（#792）。对账原语 `pruneMissingVideoRows`
    （`packages/fushi_engine/lib/media/video/video_library_prune.dart`）只接在无头服务端（BUG-2809）。BUG-3654 备注 ②
    也记过这个缺口。
  - 「删除」若走 app 内删除（`fushi/lib/src/media/video/video_library_delete.dart` → `deleteVideoBooksAndReclaimAssets`）
    行会被删掉，不会出现本现象；本现象只来自库外删文件，与反馈一致。「资料源不可用」只是那一轮补刮问资料源时的挂起原因。
  - 本轮实做过选项 A（重扫接入 `pruneMissingVideoRows`），上面那条锁定测试随即变红（删 E01 后重扫行数 3→2）——
    证明 A 就是在推翻 #792 定下的语义，所以撤回、改为待拍板。
- **选项（需所有者选）**：
  - **A. 重扫对账回收**（与服务端 BUG-2809 同口径）：导入前取本来源行作基线，导入（含 BUG-2979 搬家重链）后、归组前调
    `pruneMissingVideoRows`；护栏沿用（库根不存在 / 一个视频都没有 / 失效子树疑似脱挂 / 失效占比 >50% 且 >10 条都不删，
    不删用户文件、不写跨设备墓碑）。代价：真删掉的文件的观看进度 / 刮削资料 / 合集成员随之消失；改成同名不同路径
    （库外改名）也会丢进度。需同时改写 `source_library_scanner_test.dart:803-819`。实现与测试草稿已写好未入库。
  - **B. 保留行、标记暂缺**：行与进度保留（#792 语义不变），但计划器 / 待确认 / 自动补刮跳过「所有成员文件都不在」的作品，
    库页给暂缺态。代价：要定「暂缺」的判定时机（每次进视频页对待确认作品成员做 async 存在性判断，网络盘冷目录慢，BUG-3756），
    删掉的条目仍在库里。
  - **C. 显式清理入口**：重扫照旧不删；来源菜单加「清理已删除的文件」，走 A 的同一判据（用户显式意图，可像服务端 purge 那样
    `force`）。代价：用户得知道去点；待确认队列在清理前仍会列出它。
- **拍板**：2026-11-04 所有者委托按根因选 —— 选 **B（保留行、刮削跳过）**。理由：
  - 现象的根因不是「行没删」，而是**刮削计划把「行在库里」当成「文件在磁盘上」**：待确认队列 / 自动补刮 /
    资料刷新 / 哈希补齐都从 `VideoLibraryScrapeSweep._plannedWorks` 派生，它对一部成员文件全都不在的作品照样
    排进去——哈希算不出、sidecar 写不了，问资料源只会一轮轮挂成「资料源不可用」。
  - 行保留是 #792（`c22490be86`）有意定下的语义，护的是拔掉的移动盘 / 离线网络盘：盘回来时观看进度、刮削资料、
    合集成员都还在。A 会推翻它（库外改名、暂时离线都会丢进度），且锁定测试 `source_library_scanner_test.dart:803-819`
    正是在守这一条；C 不修队列（清理前队列照样列出它）。B 两头都对：语义不动，刮削只碰此刻真在的作品。
- **[x] ① 已修复** — `packages/fushi_engine/lib/media/video/metadata/video_library_scrape_sweep.dart`
  `_plannedWorks` 对每部作品先判 `_hasPresentMember`（默认判据 `videoMemberExists`，原盘按盘上真实文件，逐成员判、
  命中即停），成员全不在的作品不进待确认 / 已忽略 / 已识别任何一份清单；行与进度不动，文件回来下一次计划自然复现。
  构造参数 `memberExists` 只为测试注入。只作用于本地来源（sweep 本来就只看 `transport == 'local'`）。
  未做：库页「暂缺」视觉态、手动整源刮削（`scrapeSource` 不经 sweep）仍会把暂缺作品排进去——用户显式操作，留作后续。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`
  「成员文件都不在磁盘上的作品不进待确认队列、不自动补刮，文件回来后复现」（真实临时目录 + 默认判据）、
  「合集只要还有一个成员文件在就照常进队列；全不在才跳过」；`source_library_scanner_test.dart:803-819`（#792 语义）不改仍绿。
  前置修正（`0705088af7`）的测试：`packages/fushi_engine/test/media/video/video_library_prune_test.dart`。
- **备注**：app 的来源扫描只在「添加来源」与手动「重新扫描」时跑，没有定时 / 文件监听重扫；无论选哪项，库外删文件后都要等
  下一次扫描（或 B 的判定时机）才生效。
