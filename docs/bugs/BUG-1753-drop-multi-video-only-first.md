## BUG-1753 · 拖入多个视频只导入第一个
- **报告**：2026-08-20（用户：「手动将多个影片拖拽进去的时候，只会导入第一个，而不是导入所有」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/home_video_page.dart` 的 `_handleVideoDrop`：`case DropIntent.importNewVideo:` 只消费 `files.videos.first`，其余被静默丢弃。
  这不是一处漏改——`DropIntent` 是**标量**（一次拖放 = 一个意图），整条链路的数据模型里没有「多个」这个概念：`home_video_page.dart` / `reader_history/books.part.dart` / `media/drag_drop/import_dialog_drop.dart` / `media/manga/manga_import_dialog.dart` 共 20 余处 `.first`，而 `VideoDialogDropResult.videoPath` 本身就是 `String?` 而非 `List<String>`。唯一的批量字段是 `audioPaths`。
- **[x] ① 已修复** — 新增 `_openVideoImportQueue(videos, subtitles)`：拖入的**每个**视频排成队列逐个预填 `VideoImportDialog`。没有硬塞一个批量模式进对话框——该对话框结构上是单条目的（每条视频各有标题/字幕/元数据要确认）。两条语义写进了实现：
  - **字幕配对**：只有一个视频时沿用历史行为（第一条字幕给它）；多个视频时按**文件名主干**大小写不敏感配对（`EP01.mkv` ↔ `ep01.srt`），配不上就不给——多集拖入时把同一条字幕挂到每一集比不挂更糟。
  - **取消只跳过该条，队列继续**：拖 5 个进来、其中 1 个不想要，不该连带取消另外 4 个。
- **[x] ② 已加自动化测试** — 配对判据抽成纯函数 `subtitleForVideoByStem`（`fushi/lib/src/media/drag_drop/drop_classification.dart`，原先是页面里的私有静态方法、测不到），`fushi/test/media/drag_drop/drop_surface_routing_test.dart` 的 `多文件拖入：字幕按文件名主干配对` 两条：主干相同即配对（大小写不敏感、且不受列表顺序影响——故意把不匹配的 `EP02.srt` 排在前面）；配不上返回 null。
- **备注**：
  - 只修了**视频**表面（用户报的就是这条）。书架 `books.part.dart` 的 `.first` 仍在，拖多本 epub 同样只导第一本——同源不同表面，单独立项。
  - 未做：把 `DropIntent` 从标量改成 `List<DropAction>`、`import_dialog_drop.dart` 的 `String? videoPath` 改成列表。那是根治「模型里没有『多个』」的改法，爆炸半径覆盖全部拖放落点，不在本轮。
