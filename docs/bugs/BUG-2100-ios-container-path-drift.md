## BUG-2100 · iOS 每次更新后全库绝对路径失效：书架全部「找不到书籍文件」
- **报告**：2026-09-03（用户：截图两张——iOS 书架点「继续阅读」直接弹红条「找不到书籍文件」；用户原话「ios每次更新文件都会失效」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/storage/data_root_migrator.dart:28`（文件头把「移动端沙箱固定、不需要重基」写成了设计前提）+ `fushi/lib/src/storage/app_paths.dart` 全文无任何容器漂移处理。

  库里存的是**绝对路径**（`epub_books.extract_dir` / `audiobooks.audio_root` / 封面 / 字幕 / 字体…，完整覆盖清单见 `fushi/lib/src/storage/path_rebase_coverage.dart` 的 `kPathRebaseColumns`）。这套持久化模型隐含前提「数据根在两次启动之间不变」。桌面成立，**iOS 不成立**：app 容器 UUID 每次安装/更新都会变（`/var/mobile/Containers/Data/Application/<UUID>/…`），文件被系统随容器搬走，库里那串旧 UUID 路径集体悬空。症状是「更新一次，整个书架全部『找不到书籍文件』」，且每次更新复发一次；从备份/换机恢复同样命中。

  仓库里其实**已有**一套完整的全库路径重基引擎（`DataRootMigrator._rebaseDatabasePaths`，覆盖 13 张表 + preferences + profile_settings，单事务、有覆盖面守卫），但它只服务「桌面用户主动换数据根」，从不在移动端调用——差别只在**谁来改根**（用户 vs 系统），「根变了、库里绝对路径要跟着变」这件事两边完全一样。

- **[x] ① 已修复** — 新增 `fushi/lib/src/storage/sandbox_relocation.dart`：启动期对账，根变了就复用同一套引擎重基，绝不另写一份覆盖清单。
  - 为此把引擎抽出可复用入口 `DataRootMigrator.rebaseOpenDatabasePaths`（作用在**已打开**的库上；启动路径里 app 正握着这个连接，不能像迁移那样按目录另开一个）。两条路径共用同一份调用清单。
  - 旧根有两条来源：**台账**（上次启动写下的根，精确，覆盖今后所有漂移）；台账为空时**从存量数据反推**（补救本功能上线前就已被挪走的那批安装）。
  - 反推**不猜**：只有「旧路径当前已不存在」且「把它数据根以下那段接到当前根之后**存在**」的映射才被采纳——改写目标必须真的躺在磁盘上。数据根以下那段的起点由 `AppPaths.fushiOwnedDocumentsEntries` 认定，外部媒体库路径（不含白名单顶层段）永不进入作用域。
  - 接线点 `fushi/lib/src/models/app_model.dart`：在 `recoverPendingImport` **之后**（崩在半途的备份导入恢复出的库同样带着导出设备的旧根）、在任何 repository 读路径列**之前**。自愈失败只上报不阻塞启动，且**故意不写台账**，下次启动重试。
  - 提交：`ffdaa2a3f4`
- **[x] ② 已加自动化测试** — `fushi/test/storage/sandbox_relocation_test.dart`（12 条，两层）：
  - 纯函数内核 7 条：容器 UUID 变化能反推；旧路径还在就不动；改写目标不存在则拒绝；外部路径/相对路径不碰；路径里出现两个白名单段时取靠右那个。
  - 真实磁盘 + 真实库端到端 5 条：台账为空 + 存量已被挪走 → 反推并重基，**且断言重基后书的 `manga.json` 真能沿新路径打开**（不是只比字符串）；重基后写台账 → 第二次漂移走精确路径；根没变则一字节不改；空库不炸；外部路径在重基中原样不动。
  - `test/storage/` 整目录 217 条通过。
- **备注**：与 BUG-2101 是同一次用户报告的两端——本条是「书为什么找不到」，BUG-2101 是「找不到之后为什么退不出去」。真机 iOS 复测未做（本机无 iOS 设备；远程 Mac 只能出模拟器包，而模拟器不复现容器 UUID 轮换）。
