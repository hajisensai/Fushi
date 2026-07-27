## BUG-1115 · 默认数据根时 16 个 Hibiki 目录直接摊在用户文档根下
- **报告**：2026-07-26（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/storage/app_paths.dart:196`（改动前）：
  `_resolveDocumentsRoot()` 在没有自定义数据根时直接 `return getApplicationDocumentsDirectory()`，
  于是 documentsRoot **等于**平台 `Documents` 本身（Windows = `%USERPROFILE%\Documents`），
  `AppPaths.hibikiOwnedDocumentsEntries` 那 16 个目录（`audiobooks` / `hoshi_books` /
  `video_covers` / `game_covers` / `video_subtitles` / `mpv_shaders` / `remote_videos` /
  `videos` / `anime_downloads` / `custom_fonts` / `hibikiExport` / `browser` / `thumbnails` /
  `dictionaryResources` / `dictionaryImportWorkingDirectory` / `webArchive`）全部作为顶层项
  摊在用户文档根下。

  历史成因：TODO-935 E0 把十几处散落的 `getApplicationDocumentsDirectory()` 收敛进 `AppPaths`
  时，刻意保持「行为等价、旧数据零迁移」，于是「默认根 = 共享用户目录」被固化成常态——
  TODO-1226 的迁移白名单、`DataRootMigrator` 的选择性搬移模式，都是为这个特殊情况打的补丁。

- **[x] ① 已修复** — commit 见 PR；改动三处：
  1. `app_paths.dart`：默认 documents 根改为 **`<Documents>/Hibiki/data`**
     （`defaultDocumentsChildSegments`）。取 `Hibiki/data` 而非 `Hibiki`，是因为
     `<Documents>/Hibiki` 已被桌面/iOS 的**用户可见导出目录**占用
     （`DesktopDirectoryService.getHibikiExportDirectory`），数据落其下的 `data/`，
     文档根下只多出一个 `Hibiki/` 伞，内部数据与导出物分层。
  2. **老安装零破坏**：新增 `documents_layout` pref（`flat` / `nested`）。判定
     「support 根下有没有 `hibiki.db`」= 这台机器上是否已有跑过的安装：有 → 锚定 `flat`
     （documents 根仍是平台 `Documents`，一个字节都不搬）；没有 → `nested`。判定结果
     **一次性固化**，之后永不重新探测——布局若随「此刻磁盘上有没有某个文件」漂移，同一台
     机器两次启动就会解析出两个内容根 = 整个书库凭空消失。探测失败/超时一律按老安装处理
     （保守：宁可新装多摊一次，绝不把老用户切走）。
     刻意**不**用「Documents 里有没有 `videos`/`browser`/`thumbnails`」当判据：这些名字在
     用户自己的文档目录里撞名概率不低，全新安装会被误判成老安装。

     **判定只在启动期的 `AppPaths.resolve()` 里做一次**，解析路径（`_resolveDocumentsRoot`
     / `documentsSubdirectory` 等静态便捷层）**绝不碰文件系统**。这条边界是被测试打出来的：
     第一版把探测放进解析路径，结果 11 个 `home_video_*` widget 测试集体挂掉——`testWidgets`
     跑在 FakeAsync 上，真实文件 IO 的 future 在那里永不完成，`.timeout()` 还会留下
     「Timer is still pending」。解析路径未判定且 prefs 无锚点时兜底 **`flat`**（= 改动前
     行为），所以没跑过 `resolve()` 的夹具/早期调用一律拿到旧语义，不会被静默切根。
  4. **iOS 容器重定位跟着修**：`relocateMissingAppDocumentPath`（视频封面/资源在容器 UUID
     变化后的自愈）是把旧路径里 `Documents/` 之后的相对段拼回当前 documents 根。新布局下
     那段相对路径**已经包含** `Hibiki/data`，直拼会得到 `.../Documents/Hibiki/data/Hibiki/
     data/...`，重定位永远落空。改为以「当前根路径里的容器 `Documents` 段」为基准，扁平
     布局下两者恰好相等、行为逐字节不变。
  3. **给老安装一条自救路径**：老安装的 documents 根就是共享 `Documents`，想把散落的 16 个
     目录收进 `Documents\Hibiki` 会被 `validateDataRootTarget` / `DataRootMigrator._validateTarget`
     的「新数据根不能位于旧数据目录内部」一刀切拒绝。共享根走的是**白名单选择性搬移**——
     只有白名单顶层项会被搬走，`Hibiki` 不在白名单里、全程是旁观者——所以新增
     `AppPaths.isSafeNestedTargetInSharedDocuments()`，共享根下的**非白名单**子目录放行；
     白名单项本身（含其子目录、含大小写变体）仍拒绝，专属根的整树搬移语义下仍拒绝。
     顺带把 `_currentLocationLabel()` 从显示 `appDirectory.parent`（扁平布局下是用户主目录，
     新布局下是导出目录，两种都误导）改为显示 documents 根本身。

- **[x] ② 已加自动化测试** —
  - `hibiki/test/storage/app_paths_default_documents_layout_test.dart`（新建，14 例）：
    新装 → `<Documents>/Hibiki/data`；老装（support 下有 `hibiki.db`）→ 扁平且每个派生点
    与升级前逐字节一致；两种判定各自固化进 prefs；已锚定后即使主库文件出现/消失也不翻转；
    **未跑 resolve 且无锚点 → 兜底扁平老布局**；自定义 dataRoot 优先；并发解析拿到同一个
    根；`isSafeNestedTargetInSharedDocuments` 的白名单/大小写/根内外判定。
  - `hibiki/test/media/video/video_resource_check_test.dart`（+1 例）：documents 根嵌套在
    容器 `Documents` 之下时，容器 UUID 变化后仍能重定位，且绝不产出 `Hibiki/data` 拼两遍
    的路径。
  - `hibiki/test/media/video/video_cover_repair_test.dart`：封面夹具改为经
    `AppPaths.videoCoversDirectory()` 解析（与产品侧自愈查的目录同源），不再硬拼
    `<Documents>/video_covers`。
  - `hibiki/test/storage/data_root_migrator_test.dart`（+3 例）：共享根内的
    `Documents\Hibiki` 目标能真正搬成（白名单项离开文档根顶层、共享根本体与用户文件原样
    保留、DB 路径 rebase）；白名单项当目标仍抛错且旧根一字未动；专属根整树语义下嵌套目标
    仍抛错。
  - `hibiki/test/settings/data_root_settings_test.dart`（+4 例 +1 源码守卫）：
    `validateDataRootTarget` 的 `sharedDocumentsRoot` 放行/拒绝矩阵，以及守卫「共享根判定
    必须喂给触发前校验」（否则老用户在进确认弹窗之前就被拒）。
  - 既有 `app_paths_data_root_test.dart` / `write_paths_data_root_test.dart` 的默认根断言
    同步更新为新布局，并在 setUp/tearDown 清进程内布局缓存。

- **备注**：
  - 仅改「默认根」的落点，**不做任何自动迁移**：启动期搬整个书库既慢又可能被文件锁半途
    打断。老用户要整理，走设置 →「数据存储位置」选 `Documents\Hibiki`（迁移引擎会连 DB 里
    的绝对路径一起 rebase），或任意其它目录。
  - `ErrorLogService` 的 `error_log.txt` / `*_breadcrumb.txt` 仍直连平台 `Documents`
    （刻意不随数据根走，搬走会让服务失去续写目标），本次未动——文档根下仍会看到这两类
    **文件**（不是目录）。要一并收编需单独评估旧日志的续写衔接。
  - 白名单 `hibikiOwnedDocumentsEntries` 及其守卫 `documents_whitelist_guard_test.dart`
    **长期有效**：老安装可能永远停在扁平布局，新增 `<documents>/<child>` 派生点仍必须收进
    白名单。
  - 未做真机验证（本次是纯路径解析 + 单测可覆盖的逻辑）；真机需验的是：新装首启后
    `Documents\Hibiki\data` 下出现运行时目录、老装升级后书库/有声书/词典资源全部照常可见。
  - **本机现有安装（含报告者本人）会被判为老安装、继续用扁平布局**——这是刻意的零破坏
    设计。要立刻看到文档根变干净，走设置 →「数据存储位置」选 `Documents\Hibiki`（本次
    放开的正是这条路径），迁移引擎会把 16 个目录搬过去并 rebase DB 里的绝对路径。
