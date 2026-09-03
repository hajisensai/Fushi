## BUG-1754 · 视频页拖入文件夹完全静默
- **报告**：2026-08-20（用户：「导入文件夹应该直接添加文件夹到来源」；截图里拖入的正是一个剧集文件夹）
- **真实性**：✅ 真 bug。两处叠加：
  1. `fushi/lib/src/pages/implementations/home_video_page.dart` 的 `_handleVideoDrop` 调 `classifyDroppedFiles(paths)` 时**没传** `isDirectory` 谓词。该谓词是分类器唯一的外注入判据（目录没有扩展名，纯扩展名分类分不出「目录」与「无扩展名文件」，而分类器不碰文件系统）。不传 → 目录落 `unknown` → `decideDropIntent` 走到 `files.hasAny` 之前的分支全不命中 → `DropIntent.ignore` → **什么都不做、什么都不说**。
  2. `fushi/lib/src/media/drag_drop/drop_classification.dart` 把「这是目录」这个**事实**就地编码成「这是漫画」这个**判断**（`isDirectory(path) → mangas.add(path)`）。判断做早了，别的表面再也拿不到原始事实——即使视频页传了谓词，也只会拿到一个「漫画」。
  「以打开的页面为准」的另一半（拖放同时命中隐藏 tab）是 BUG-1752。
- **[x] ① 已修复** — 三步，分别对应上面的两处：
  - 分类器新增 `DroppedFiles.directories`，**只记录事实**；目录仍同时进 `mangas`，书架/漫画库的「整目录页图导入一本漫画」逐字节不变。
  - `decideDropIntent` 的 video 分支新增 `if (files.directories.isNotEmpty) return DropIntent.addFolderAsSource;`，**排在 videos/playlists 之前**——拖一整个剧集目录进来要的是加来源，不是导入恰好也选中的那一个 mp4。books/manga 分支不变。
  - 视频页补上 `isDirectory: (path) => Directory(path).existsSync()`，并新增 `_addDroppedFoldersAsSources`：媒体类型取自**当前页面**（恒 `SourceLibraryKind.video`），不从目录内容猜。
  落地走**新抽的共享函数** `fushi/lib/src/media/source_library/add_local_folder_source.dart` 的 `addLocalFolderAsSource`（归一化路径 → 同 transport+路径去重 → 插入 → 立即扫描），与来源页「添加本地文件夹」按钮产出完全相同的来源行；两条入口不会漂成两套语义。结果给 toast（新增 / 已存在两种）。
- **[x] ② 已加自动化测试** — `fushi/test/media/drag_drop/drop_surface_routing_test.dart`：
  - `目录是事实，不是判断`：传 `isDirectory` 时目录同时进 `directories` 与 `mangas`；不传时两者都空（历史行为逐字节不变）。
  - `decideDropIntent：文件夹按落点表面解释`：视频页 → `addFolderAsSource`；视频页**混合**拖入（目录 + mkv）仍 → `addFolderAsSource`；books 与 manga 两个表面 → 仍是 `importNewManga`（既有能力不许被拿掉）。
- **备注**：
  - 用户原话是「直接添加文件夹到来源」，故实现为**直接加为常驻来源**，没有再弹「设为常驻来源 / 仅导入这一次」二选一。来源页那个二选一对话框（`media_sources_view.dart` 的 `importFolder`）仍只挂在文件选择器上。若之后希望拖放也先问一句，改 `_addDroppedFoldersAsSources` 一处即可。
  - `addLocalFolderAsSource` 目前只有拖放路径在用；把 `MediaSourcesViewState.addLocalFolder` 也改成调它（消除那 15 行重复）留待后续，本轮不动那个 State 以控爆炸半径。
  - 书架/漫画库拖文件夹仍是「一本漫画」。若用户之后也希望那两个表面按来源处理，改的是 `decideDropIntent` 的对应分支，事实字段已经就位。
