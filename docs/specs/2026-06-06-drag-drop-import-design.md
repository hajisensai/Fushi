# 拖拽导入字幕 / 书籍 / 视频 — 设计文档

- 日期：2026-06-06
- 分支：`worktree-drag-drop-import`
- 状态：设计待用户确认

## 1. 目标

桌面端支持把文件**拖入应用窗口**完成导入：

- 拖**书籍**（EPUB / 纯文本）→ 新建书。
- 拖**视频**（mp4/mkv…）→ 新建视频。
- 拖**字幕 / 音频**到某本书或某个视频的**卡片上** → 附加到该媒体（有声书对齐 / 视频外挂字幕）。

平台范围：**仅桌面三端**（Windows / macOS / Linux）。移动端（iOS/Android）操作系统无「从文件管理器拖文件进 app」交互；Android 已有 `receive_intent` 分享入口，本功能不涉及。

## 2. 约束与既有事实

- 拖拽是**全新能力**：`hibiki/lib` 与 `pubspec.yaml` 当前对 `desktop_drop` / `DropTarget` 零命中。
- **字幕不能独立存在**，必须挂在某本书或某个视频上（现架构）。
- 落库原语全部现成，拖拽层**不重写导入逻辑**，只负责分类 + 预填路径后复用：
  - 书：`EpubImporter.importFromPath(...)`（`hibiki/lib/src/epub/epub_importer.dart:65`）。
  - 视频：`VideoBookRepository.saveVideoBook(...)` + `saveCues(bookUid, cues)`（`hibiki/lib/src/media/video/video_book_repository.dart:10,41`，`saveCues` 按 uid 整体替换、幂等）。
  - 给**已有书**追加音频+字幕：`AudiobookImportDialog(bookKey, extractDir, repo)`（`hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart:19`），接受 `FileType.audio` + 字幕 `srt/lrc/vtt/ass/ssa/json`，有 `audioOnly` 旗；落库 `AudiobookRepository.saveCues/saveAudiobook`（`packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart:51,59`）。
- 向后兼容铁律：现有「点按钮选文件导入」的所有路径行为**完全不变**，拖拽只是叠加入口。

## 3. 数据模型 — 一个纯函数消除特殊情况

拖入文件按扩展名分类，**由落点决定语义**（不设全局歧义分支）：

```text
classifyDroppedFiles(List<String> paths) → {
  books:     List<String>,   // .epub + TextToEpub.supportedExtensions
  videos:    List<String>,   // .mp4 .mkv .avi .mov .webm .m4v .flv .ts ...
  subtitles: List<String>,   // .srt .vtt .ass .ssa .lrc
  audios:    List<String>,   // audiobook_storage.audioExtensions
  unknown:   List<String>,
}
```

`.mp4` 同时属于「视频」与「有声书音频」两个集合。**不在分类函数里消歧**，而是由**落点上下文**决定：

- 落在视频页 / 书架页（页面层）→ 当作**视频**。
- 落在书卡（卡片层）→ 当作**有声书音频**。

落点即上下文，分类函数保持无状态、可单测。

类型签名（Dart）：

```dart
class DroppedFiles {
  final List<String> books;
  final List<String> videos;
  final List<String> subtitles;
  final List<String> audios;
  final List<String> unknown;
  const DroppedFiles({...});
}

DroppedFiles classifyDroppedFiles(List<String> paths);
```

## 4. 两层拖拽目标

拖拽落点**只挂在「书架 tab」和「视频 tab」的 body**；词典 / 设置 tab 不接收拖放。

### 页面层（新建媒体）

包在 `HomeReaderPage`（书架 body）与 `HomeVideoPage`（视频 body）外层：

- 拖入**书文件** → 打开 `BookImportDialog`，预填 EPUB 路径。
- 拖入**视频文件** → 打开 `VideoImportDialog`，预填视频路径。
- 拖入**字幕 / 音频但没落在任何卡片上** → SnackBar 提示「字幕 / 音频请拖到某本书或某个视频上」。

### 卡片层（附加到已有媒体）

每个书卡 / 视频卡各包一层 DropTarget：

- **书卡**：字幕和/或音频 → `AudiobookImportDialog(bookKey, extractDir, repo)`，预填音频槽 + 字幕槽（用户再确认对齐 / 补音频）。
- **视频卡**：字幕 → 复用 `VideoImportDialog` 的外挂字幕路径，目标 VideoBook 锁定该卡。
- 其余类型在卡片层忽略，冒泡交给页面层处理。

两层消歧：卡片层只处理「字幕/音频」；页面层只处理「书/视频」。按类别分流，不靠坐标 hit-test，避免 `desktop_drop` 嵌套事件语义的不确定性（实现阶段需用 context7 核实 `desktop_drop` 嵌套 `DropTarget` 的触发语义，必要时退回「单页面 DropTarget + 卡片矩形登记」方案）。

## 5. 复用点 — 零重写，只加「预填」入口

三个对话框各加一个**可选**构造参数承接拖入路径，不传时行为与现状完全一致：

- `BookImportDialog({..., List<String>? initialBookPaths})`
- `VideoImportDialog({..., String? initialVideoPath, String? initialSubtitlePath})`
- `AudiobookImportDialog({..., List<String>? initialAudioPaths, List<String>? initialAlignmentPaths})`

对话框 `initState` 时若 `initial*` 非空，等价于「用户已经在选择器里选了这些文件」，直接填进对应状态槽。落库路径不动。

## 6. 平台隔离

新增薄封装 widget `HibikiFileDropTarget`：

```dart
class HibikiFileDropTarget extends StatelessWidget {
  final Widget child;
  final void Function(List<String> paths) onDrop;
  // 非桌面平台：直接返回 child，零开销，不引用 desktop_drop 的运行期对象。
}
```

`desktop_drop` 仅在桌面平台代码路径被调用；移动端透传 `child`。

## 7. 测试策略

桌面拖拽事件经平台通道，无法在 widget test 里模拟，因此测试落在**可落地的最强层**：

1. **纯函数 `classifyDroppedFiles` 单测**：各扩展名归类、大小写、`.mp4` 落两类、未知扩展名进 `unknown`。
2. **路由决策单测**：给定 `(DroppedFiles, 落点=页面/书卡/视频卡)` → 期望动作（开哪个对话框 / 提示 / 忽略）。把路由逻辑抽成纯函数 `decideDropAction(...)` 便于断言。
3. **对话框 `initial*` 预填 widget 行为测试**：构造时传入路径 → 断言对应状态槽已填、UI 显示已选文件。
4. **源码守卫**：扫描 `desktop_drop` 的调用必须在桌面平台门控内（`kIsDesktop` / `Platform.isWindows||isMacOS||isLinux`），防止移动端误引入。
5. **真机三端实际拖放验证 = 用户**（焦点驱动测试无法覆盖 OS 拖放）。

## 8. 影响范围与风险

- 改动文件（预计）：
  - 新增 `hibiki/lib/src/media/drag_drop/`（`classify.dart` 分类 + 路由纯函数、`hibiki_file_drop_target.dart` widget）。
  - `home_page.dart` / `reader_hibiki_history_page.dart` / `home_video_page.dart`：挂载两层 DropTarget。
  - 三个对话框：加可选 `initial*` 参数。
  - `pubspec.yaml`：加 `desktop_drop`。
- 风险点：
  - `desktop_drop` 嵌套 `DropTarget` 触发语义（页面层 vs 卡片层是否会双触发）——实现阶段用 context7 核实 + 写最小验证；不确定就退回「单 DropTarget + 卡片矩形登记」。
  - 卡片层要拿到被拖中卡片对应的 `bookKey`/`extractDir`/`VideoBook`——需卡片 item builder 暴露这些（书架/视频列表已持有数据，传入即可）。
  - 向后兼容：`initial*` 必须可选且默认 null，旧调用方零改动。

## 9. 不做（YAGNI）

- 不做移动端拖放（OS 不支持）。
- 不把 Android 分享 intent 接到导入（独立工作，超范围）。
- 不支持「单独一个字幕文件不挂任何媒体」导入（架构不允许）。
- 不做拖入时的实时高亮预览动画（先打通功能；可后续叠加 DropTarget 的 onDragEntered 高亮）。
