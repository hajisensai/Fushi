## BUG-4004 · app 本地视频来源重扫从不回收已删除文件，删掉的视频留在待确认刮削队列
- **报告**：2026-11-02（反馈 i5rQ5dMlBH，Windows 10 / app 3.0.0+19763：「视频刮削不存在的文件。我把那个视频删除之后，它把这视频也当成刮削的内容了，现在显示资料源不可用」；截图：后台任务 → 待确认 1 条「擅长作弄的高木同学.07.中日双语.720p.HDT…」，动漫文件，原因「资料源不可用」）
- **真实性**：✅ 现象属实、代码路径已坐实；但根因处是一条**现行的有意语义**，改它要所有者拍板（见「选项」），本条不擅自改。
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
- **[ ] ① 未修复（待拍板）** — 已先落三个选项都需要的前置修正（提交 `0705088af7`）：`selectStaleVideoRows` 默认存在判据由裸
  `File(path).existsSync()` 改为 `videoMemberExistsSync`（`packages/fushi_engine/lib/media/video/video_library_prune.dart`）。
  DVD 标题是虚拟路径 `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`，裸判恒假，任何 app 侧接入都会把仍在盘上的 DVD 当成「文件没了」
  删掉；它躲过守卫 `fushi/test/build/video_member_file_exists_guard_test.dart` 只因变量名叫 `path`。服务端扫描器不导入原盘，
  目前对服务端是潜在问题。
- **[ ] ② 未加自动化测试（主修复待拍板）** — 前置修正的测试：`packages/fushi_engine/test/media/video/video_library_prune_test.dart`
  「DVD 标题按盘上真实文件判：盘在 → 保留，盘没了 → 失效（默认判据）」（`dart test` 17 条全绿）。
- **备注**：app 的来源扫描只在「添加来源」与手动「重新扫描」时跑，没有定时 / 文件监听重扫；无论选哪项，库外删文件后都要等
  下一次扫描（或 B 的判定时机）才生效。
