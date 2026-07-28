## BUG-1188 · 选目录迁移产出第三种布局，到不了新装形态（DB 被拖进文档目录）
- **报告**：2026-07-28（用户：内部审计，走「设置 → 数据存储位置 → 选目录」即可触发）
- **真实性**：✅ 真 bug（在 develop `862ce0d17` 上跑真 `DataRootMigrator.migrate()` 实测复现）

  根因 `hibiki/lib/src/storage/data_root_migrator.dart:143-148`（改动前）：`migrate()` 无条件
  `AppPaths.rootsForDataRoot(req.newDataRoot)`，即**目标只有一种表达**——一个 dataRoot 字符串，
  硬派生 `<root>/documents`（`app_paths.dart:114`）+ `<root>/support`（`app_paths.dart:117`）。

  于是 BUG-1115 给老安装写的指引（`docs/bugs/BUG-1115-default-documents-root-flat.md:75-76,86-87`
  「走设置 →「数据存储位置」选 `Documents\Hibiki`」）产出的是**第三种布局**，与全新安装
  （`app_paths.dart:_resolveDefaultDocumentsRoot` → `<Documents>/Hibiki/data` + 平台固定
  `getApplicationSupportDirectory()`）不同：

  ```
  新装形态 documents 根: <Documents>\Hibiki\data
  新装形态 support 根:   <AppData>\app.hibiki.reader
  迁移实际 documents 根: <Documents>\Hibiki\documents      ← 名字不同
  迁移实际 support 根:   <Documents>\Hibiki\support        ← DB 被拖进文档目录
  data_root pref 写入:   <Documents>\Hibiki
  ```

  两个后果：
  1. **布局分裂**：同一个物理位置有两种持久化表达（`data_root=<Documents>/Hibiki` vs 无
     `data_root` + `documents_layout=nested`），磁盘形态还不一样。用户照文档整理完就**永远回不到
     新装形态**，也无法与新装机器对齐。
  2. **DB 被搬进用户文档目录**：Windows 的 `Documents` 常被 OneDrive 重定向同步，WAL 模式的
     SQLite 主库落在那里既有损坏风险，也会被反复上传；而持久化 `data_root` 的
     `shared_preferences.json` 按设计**不能**跟着搬（`data_root_migrator.dart` 的鸡生蛋铁律），
     结果两份配置存储被劈开在两处。改动前的迁移把「换个盘放数据」和「把散落目录收进子目录」
     这两件语义完全不同的事塞进了同一条硬派生路径。

- **[x] ① 已修复** — `fix(storage): normalize data-root migration to the default layout`
  - **把「迁移目标」提升成数据结构**：新增 `DataRootMigrationTarget`
    （`data_root_migrator.dart`），携带解析后的 `documentsRoot` / `supportRoot` /
    `dataRootPrefValue`；`DataRootMigrationRequest.newDataRoot` → `target`，
    `writeDataRootPref` → `commitLocation(target)`。两种情形因此是**同一条代码路径的两个取值**，
    不是两条分支：
    - `DataRootMigrationTarget.customRoot(R)` —— `<R>/documents` + `<R>/support`，提交写
      `data_root`。**行为逐字节不变**（换盘放数据的语义原样保留，DB 仍随之搬走）。
    - `DataRootMigrationTarget.defaultLocation(...)` —— documents 根 = `<Documents>/Hibiki/data`、
      support 根 = 平台固定落点（**DB 不动**），提交清掉 `data_root` 并把
      `documents_layout` 锚成 `nested`。
  - **归一化入口** `resolveDataRootMigrationTarget()`：用户挑的目录若是默认位置
    （`<Documents>/Hibiki` 伞目录，或 `<Documents>/Hibiki/data` 本身）就走 defaultLocation。
    这消除的正是「同一个物理位置两种表达」这个歧义，而不是给它加一个 if 分支。
    伞目录靠 `defaultDocumentsChildSegments` 恒 ≥2 段保证绝不等于共享 `Documents`（有守卫）。
  - **判定「默认位置」必须用不看锚点的根**：新增 `AppPaths.defaultLocationDocumentsRoot()`。
    `_resolveDefaultDocumentsRoot()` 在老安装上会因锚点 `flat` 返回平台 `Documents`，用它判定
    则老安装永远解析不出 defaultLocation 这个目标。
  - **support 根未变时的三条禁令**（`migrate()`）：不建搬移计划、不跑
    `_deleteOldSupportPreservingPrefs`（它会把活着的固定落点里除 prefs 外的一切删光，包括刚
    rebase 完的 `hibiki.db`）、不进 `_cleanupCreatedSubtrees`（整目录删掉 = 抹掉用户全部设置）。
  - **合并搬入**（自定义根 → 默认位置，目标固定落点里已有 prefs）：`_MovePlan.mergeIntoDestination`
    强制逐顶层项搬移（整目录 rename 到非空 dst 在 Windows 上必失败），回滚改用
    `_MovePlan.movedTopLevelNames`（只搬回**本次真正搬进去**的项）并保留 dst 本体——旧的
    `_rollbackSelective` 按 dst 列目录回滚，会把先于迁移就存在的 `shared_preferences.json`
    一起搬进即将被删的旧根。
  - **空目标校验收窄**：`_hasAnyFileAsync` 支持 `ignoreTopLevelNames`，检查目标 support 根时忽略
    顶层 prefs 文件族（它刻意不参与搬移），但**任何别的残留**（比如陈旧的 `hibiki.db`）仍照拒。
  - **提交原子性**：`_commitDefaultLocation` 先锚 `nested` 再清 `data_root` 再清 macOS 书签，
    任一步失败全部复原并抛错（引擎据此回滚整次迁移）。两个键必须同时生效——只锚 nested 会指向
    已搬空的旧根，只清 `data_root` 会把 documents 根解析回共享 `Documents` = 书库集体消失。
  - **确认弹窗**列出解析后的两个根，用户按下确认前就能看到数据到底会去哪（归一化不是暗箱）。
  - **未触碰**：`anime_downloads` 的搬移 / fast-resume / 活跃文件句柄逻辑（与 BUG-1174 同样刻意
    不碰）；未加「一键整理」按钮；`<dataRoot>/documents` 这个存量子目录名未改名（改名要给存量
    自定义根用户再加一个永久锚点，纯外观收益、爆炸半径不成比例）。

- **[x] ② 已加自动化测试** — `hibiki/test/storage/data_root_default_location_migration_test.dart`
  （12 例，行为 + 源码守卫）：
  - ① 目标解析归一化：伞目录 / 默认 documents 根 → defaultLocation（且 `dataRootPrefValue==null`）；
    别的目录 → customRoot 且与 `AppPaths.rootsForDataRoot` 逐字节一致；共享 `Documents` 根本身
    **不是**默认位置 + `defaultDocumentsChildSegments.length >= 2` 不变量守卫。
  - ② 扁平老安装照文档指引整理的**端到端**（真 `migrate()`）：产物 == 新装形态、`Hibiki` 伞下
    只有 `data`（无 `documents`/`support`）、`hibiki.db` 仍在平台固定落点、用户文件与 prefs 一字
    未动、DB 内 documents 路径已 rebase 而外部视频路径/support 路径不动、提交是 defaultLocation
    语义。
  - ② **幂等**：默认位置的路径改写连跑两次逐字节 no-op，并显式断言不出现
    `Hibiki/data/Hibiki/data`。
  - ③ 旧方式搬过的用户：`<root>/documents` + `<root>/support` 解析规则原样不变（继续正常工作）；
    再选一次 `Hibiki` 能归一化回默认位置（DB 合并搬回固定落点、既存 prefs 一字未动）；
    提交失败回滚时**平台固定落点不被整目录删掉**、prefs 与旧根数据都还在。
  - ④ 源码守卫：UI 必须经 `resolveDataRootMigrationTarget` 解析且不得自己再
    `AppPaths.rootsForDataRoot`；默认位置提交必须同时锚 nested 并清 `data_root`；
    `supportUnchanged` 的两条禁令必须在源码里。
  - 负向验证（改回旧逻辑 → 转红 → 还原 → 转绿）三条各自确认：
    ① 关掉归一化（恒 customRoot）→ 4 例红；② 去掉 `if (!supportUnchanged)` 删旧 support 守卫
    → 2 例红（`hibiki.db` 被从固定落点删掉）；③ 让 `newSupport` 无条件进 `_cleanupCreatedSubtrees`
    → 2 例红（回滚删掉平台固定落点）。还原后 12/12 绿。

- **备注**：
  - **数据库位置的选择**：默认位置目标下 DB **留在** `getApplicationSupportDirectory()`
    （Windows `%APPDATA%\app.hibiki.reader`）——① 那就是全新安装的落点，不这样就谈不上「同形」；
    ② 用户 `Documents` 常被 OneDrive 重定向，WAL SQLite 放进去有损坏与反复上传风险；
    ③ `shared_preferences.json` 按鸡生蛋铁律钉死在固定落点，DB 留在它旁边避免两份配置存储劈开。
    显式选一个普通目录（换盘）时 DB **仍然跟着搬**，语义与改动前逐字节一致。
  - `schema` 未改动；持久化 key 未改名；`data_root` / `documents_layout` 的取值域未扩。
  - 已按旧方式搬过的用户零破坏：`AppPaths._resolveDocumentsRoot` 的 dataRoot 分支优先于布局锚点，
    解析规则一字未改，他们的 `<root>/documents` + `<root>/support` 继续工作；愿意收敛的话再选一次
    `Documents\Hibiki` 即可归一化（不强制、不自动）。
  - 未做真机验证（纯路径解析 + 文件搬移逻辑，单测可在真实文件系统上端到端覆盖）。真机需验的是：
    老安装选 `Documents\Hibiki` 后重启，书库/有声书/词典资源全部可见且 `Documents\Hibiki` 下只有
    `data`、`%APPDATA%` 下仍有 `hibiki.db`。
