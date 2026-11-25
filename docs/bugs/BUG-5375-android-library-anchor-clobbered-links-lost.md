## BUG-5375 · Android 更新后书库全部失去链接（书库位置锚点被别的进程冲掉 + 沙箱重基不经磁盘核实）
- **报告**：2026-11-24（应用内反馈 RCv76PPoiJ：「更新后小说库文件失去链接」；Android Xiaomi 23116PN5BC，3.4.0-debug.32147 → 32168）
- **真实性**：✅ 真 bug（沿代码路径确认；未拿到报告人设备上的库与偏好文件，触发链下面第 1 步是按时间线推断的最可能路径）。截图：小说库所有封面空白，两本有声书报「音频文件丢失」；日志：缓存里同时有 32147 与 32168 两个更新包，32147 进程只活了 41 秒就因 `installPackageLI` 被结束，之后冷启动 `sandbox-relocation` 正常跑完、没有任何报错。
- **根因**：
  1. `fushi/lib/src/storage/app_paths.dart:261`（修复前）：Android 书库位置锚点（内部 / 外部，9f141cd2fb 新增，11-22 合入）存在 SharedPreferences。app 有 `:popup`、`:second_screen` 等独立进程（`AndroidManifest.xml` 的 `android:process`），弹窗进程也会跑 `AppPaths.resolve()`（`app_model.dart` `initialiseForDictionaryPopup` → `_prepareRuntimeDirectories`）。Android 的 SharedPreferences 每个进程各持一份内存副本，任一进程写任何键都会把**整份**副本落盘：长驻的弹窗进程带着迁移前的旧值一写，主进程刚提交的「外部」锚点（以及「已提示」标记）就被冲回去。下次冷启动书库根判回内部——而迁移成功后内部书库已删空。
  2. `fushi/lib/src/storage/sandbox_relocation.dart:68`（修复前）：台账路径（上次启动记的根 ≠ 本次解析出的根）**不经磁盘核实**就把全库绝对路径改写到本次的根。本次的根解析错了时，这一步把本来正确、文件也都在的外部路径集体改到空的内部根，并把台账换成内部——下次启动也救不回来。反推路径（台账为空）一直要求磁盘作证，台账路径漏了同一条纪律。
- **[x] ① 根因修复** —
  - 锚点改成 support 根下的小文件 `android_library_location.json`（`AndroidLibraryAnchor`，同进程独占临时文件 + rename 原子替换），不再写 SharedPreferences；旧 prefs 值只在锚点文件还不存在时当种子读一次。迁回内部时的布局（nested）也记在锚点文件里，Android 上以它为准（`app_paths.dart` `_ensureAndroidDocumentsLocationDecided`；提交点 `data_root.part.dart` `_commitAndroidLocation`）。
  - 判定后与磁盘对账（`reconcileAndroidDocumentsLocation` / `hasLibraryFiles`）：锚定的根的白名单目录里一个文件都没有、另一个根里有 → 以磁盘为准改正锚点。常态下锚定的根第一个文件就停，不碰另一个根。这一步同时修好**已经中招**的安装：根纠正回外部后，沙箱重基按（错写成内部的）台账把路径改回外部，磁盘证实后才改。
  - 沙箱重基台账路径加磁盘核实（`SandboxRelocation.rebaseEvidenceFor`）：抽样存量路径，出现「旧路径在、改写后不在」的反证就拒绝改写、台账不动。
  - 诊断：锚点纠正、重基改写 / 拒绝都写进诊断日志（`AppPaths.androidLocation`、`AppModel.sandboxRelocation`），下次同类反馈能直接看到这一步做了什么。
- **[x] ② 自动化测试** —
  - `fushi/test/storage/sandbox_relocation_test.dart`「反馈 RCv76PPoiJ」组：书库在外部、本次根判成空的内部 → 拒绝改写，路径与台账都不动（旧实现在此把路径改坏）；已被改坏的安装在根纠正后按台账改回、封面可沿新路径打开；`rebaseEvidenceFor` 证实 / 反证 / 中性 / 作用域外四种情形。
  - `fushi/test/storage/android_documents_location_test.dart`「反馈 RCv76PPoiJ」组：磁盘对账判定、`hasLibraryFiles` 只认白名单内文件、锚点文件原子写与坏内容、编解码、守卫（lib 里不许再把位置锚点写进 SharedPreferences）。
  - 定向 2 文件 35 条通过（`heavy.dart -- flutter test … --no-pub`，exit 0）。
- **备注**：
  - 未在真机复现「弹窗进程冲掉锚点」这一步（需要老安装 + 迁移 + 弹窗进程常驻的真机现场）；修复不依赖这一步是否成立：无论根因为何让解析出的根变错，台账重基都会被磁盘反证拦下，锚点也会被磁盘对账纠正。
  - 同类隐患：其它 SharedPreferences 键（含 Android 上的布局 / 容器锚点、各功能偏好）在多进程下同样可能被旧副本覆盖。Android 书库位置这一条已搬离；其余键的多进程一致性另行登记。
  - 补漏（#4366 指出、小米真机取证：书库 17 GB 在内部，锚点指向外部空根，与上面推断的方向相反；该机全程无 `:popup` 进程记录，锚点为何翻到外部仍未确定）：
    1. `hasLibraryFiles` 原把冷启动自建的 `fushiExport/.nomedia` 当书库文件，已中招的安装外部根里恰好只有它，对账判「锚定的根有书」、永不自愈。现跳过 `AppPaths.libraryEvidenceIgnoredEntries`（导出目录 / 导入暂存 / 推荐包暂存 / 引导状态）并忽略 `.nomedia`。
    2. `planAndroidDocumentsMigration`（`data_root.part.dart`）原无条件 `newDocs.delete(recursive: true)`：锚点错指空根时点「移回内部」，目标就是真书库，会被整树删光。现先核实目标是源的子集（`AppPaths.firstAndroidMigrationTargetOnlyFile`，中断的跨盘复制不删源，所以半成品一定是子集），有源里没有的文件就拒绝（`data_storage_migrate_target_has_library`），一个字节都不删。
    3. 测试：`android_documents_location_test.dart` 小米现场自愈判定、`.nomedia` / 空运行目录不算书库、目标子集核实三情形；`sandbox_relocation_test.dart` 书库在内部、路径被改到外部 → 根纠正回内部后改回。
  - 两边根都有书（拍板台 review-library-anchor-both-roots，维护者「根本性修复」）：锚点错指期间用户往错的根又导入了书，原判据把「两边都有」一律当迁移中断、沿用锚点，永不自愈。现在：
    1. 两边都有书库文件时让主库作证（`fushi/lib/src/storage/android_library_db_witness.dart` `AndroidLibraryDbWitness`）：`AppPaths.resolve` 早于开库，所以这里另开一条 **SQLite 只读连接**（读库与计票都在后台 isolate，读完即关，不跑迁移、不建表），**全表**读 `epub_books.extract_dir` / `audiobooks.audio_root` / `srt_books.srt_path` / `video_books.video_path|cover_path`，取数据根内尾段，看它「只在哪个根」存在；另一个根严格多数才改锚点，平局（中断迁移的完整副本）或读不到主库沿用锚点。按尾段计票，与库里记的是哪个根的前缀无关，前后启动结论稳定。不抽样（审查 #4379）：错根里的正是最新导入的那批，只取最新 N 行会在书多于 N 本时让新书占满样本、把真书库判成落选根再整库往错根搬。
    2. 开库后、台账重基前把落选根里的散书并回书库根（`android_stray_library_merge.dart` `AndroidStrayLibraryMerge`，`app_model.dart` 启动期调用）：先把要搬的文件复制成书库根里的 `*.fushi-part` 暂存件，全部成功才改写库内落选根前缀的路径（`DataRootMigrator.rebaseOpenDatabasePaths` + fast-resume），再改名提交、删源；复制失败（空间不够等）撤掉暂存件、回滚 fast-resume，主库与落选根原样（审查 #4379 修正：原顺序先改库再搬，搬到一半失败会让未搬的书在库里指向书库根里不存在的路径）。规划放后台 isolate，同名文件先比长度、遇到第一处冲突即收手（冲突会让落选根常驻，每次启动都要重新规划）；书库根里有**逐字节相同**副本的才删落选那边，半截 `*.fushi-part` 直接删；只要有一个同名文件内容不同就整次放弃、什么都不动，只写诊断（`AppPaths.androidStrayLibrary`）。半途崩溃下次启动会再作证、再合并（改写已是空操作）。
    3. `hasLibraryFiles` / 迁移前子集核实不再把 `*.fushi-part` 当书库文件。
    4. 不做「我确认目标可删」的强制清理按钮（拍板）：那种情形（上次迁移已提交但删源中断、之后又删了书再往回迁）很少见，而强制清理一旦判断错就是整树删掉真书库，代价不可逆；现在的合并只删逐字节相同的副本，覆盖了「中断迁移残留」这一常见来源。
    5. 测试：`fushi/test/storage/android_library_db_witness_test.dart`（作证判定、尾段、真主库只读取样、合并 / 冲突放弃 / 半途崩溃后结论不变）。
