# 视频长按菜单 + 标签系统（共用书架标签池）实现计划

## 背景与根因

- **视频长按没菜单**：`home_video_page.dart` 的视频卡 `onLongPress: () => _open(book)`（与 `onTap` 同），书架 `_buildVideoCard` 的 `onLongPress: () => _openVideoBook(book)` 同病——长按只是打开播放页，从不弹菜单。
- **视频没标签**：标签系统由共享标签池 `BookTags` + 每类媒体一张映射表组成（EPUB→`BookTagMappings`、SRT→`SrtBookTagMappings`），视频**没有**映射表，卡片也不渲染标签。
- 实验视频 tab 开启时书架不显示视频（`reader_hibiki_history_page.dart:432`），视频归 `HomeVideoPage` 独占，所以视频 tab 是长按主战场，两处都要修。

## 设计：共用一套标签系统

视频书主键是 `bookUid`（String）。镜像 SRT 的做法，新增 `VideoBookTagMappings(videoBookUid TEXT FK→VideoBooks.bookUid, tagId INT FK→BookTags.id, unique{videoBookUid,tagId})`。标签定义仍用共享的 `BookTags` 表——这就是「共用一套标签系统」（同一标签池，跨 EPUB/SRT/视频）。

## 改动清单

### 1. DB 层（hibiki_core）
- `tables.dart`：新增 `VideoBookTagMappings` 表（镜像 `SrtBookTagMappings`）。
- `database.dart`：
  - `@DriftDatabase(tables:[...])` 注册 `VideoBookTagMappings`。
  - `schemaVersion` 20→21。
  - 迁移：`if (from < 21) { if(!await _tableExists('video_book_tag_mappings')) await m.createTable(videoBookTagMappings); }`（video_books 在 from<17/from<20 已建，FK 可用）。
  - 新 CRUD（镜像 SRT）：`getTagsForVideoBook` / `addTagToVideoBook` / `removeTagFromVideoBook` / `setTagsForVideoBook` / `getAllVideoBookTagMappings` / `getVideoBookUidsForAllTags`。
  - 删除/封面：`deleteVideoBook(bookUid)`（FK cascade 自动清映射）/ `updateVideoBookCover(bookUid, path)`。
- `dart run build_runner build` 重生成 `database.g.dart`。

### 2. VideoBookRepository
- `deleteVideoBook(bookUid)` / `updateCover(bookUid, path)` 透传。标签操作 UI 直接走 `appModel.database`。

### 3. Providers（tag_filter_sheet.dart）
- `videoBookTagMapProvider: FutureProvider<Map<String,List<BookTagRow>>>`（keyed by bookUid）。
- `filteredVideoBookUidsProvider: FutureProvider<Set<String>?>`（watch 共享 `selectedTagIdsProvider`）。

### 4. TagPickerPage
- 加 `videoBookUid` 参数（与 bookKey/srtBookId 三选一），按之分派到视频 db 方法。

### 5. HomeVideoPage（主表面）
- 顶部加标签筛选栏（`allTagsProvider` 出 chip，toggle 共享 `selectedTagIdsProvider`）。
- 网格按 `filteredVideoBookUidsProvider` 过滤。
- 卡片：标签标签层 + 长按 → 菜单（编辑标签 / 设置封面 / 删除）。
- 编辑后 invalidate 相关 provider + 刷新列表。

### 6. 书架 history page
- `_buildVideoCard`：加标签层 + `onTagDropped`（拖标签到卡）+ 长按弹视频 dialog（标签/封面/删除）。
- 视频过滤：filter 激活时不再整组隐藏，改按 `filteredVideoBookUidsProvider` 过滤显示命中的视频。
- helpers：`_addTagToVideoBook` / `_openVideoTagPicker` / `_confirmDeleteVideoBook` / `_pickVideoCover` / `_showVideoBookDialog`。

### 7. i18n（经 i18n_sync.dart，17 语言）
- 复用：`tag_label`（标签）、`dialog_delete`（删除）、`srt_import_pick_cover`（设置封面）。
- 新增：`video_delete_confirm_title` / `video_delete_confirm_message`。

### 8. 测试（最强可落地层）
- DB：`video_book_tags_test.dart`——CRUD、删视频 cascade 清映射、删标签 cascade、AllTags 过滤。
- 迁移：`migration_test.dart` 期望版本→21 + `video_book_tag_mappings` 表存在。
- widget：HomeVideoPage 长按弹菜单（含标签项）、卡片渲染标签 chip；TagPickerPage 视频分派。
- 源码守卫：视频卡 `onLongPress` 不等于 `onTap`/`_open`（防回归）。

## 验证
- `dart format .` + `flutter test`（DB/widget/migration/i18n）。
- 真机/模拟器复测长按弹菜单、加标签后封面显示、按标签筛选——留给用户（阅读器/导入类设备验证纪律）。

## 风险点
- `database.g.dart` 重生成是最重步骤，必须 build_runner 跑通、schema 一致。
- 共享 `selectedTagIdsProvider` 会让视频 tab 与书架的标签筛选状态联动——这是「共用一套系统」的合理表现。
- 迁移在真实多血缘 DB（video 线 fork 的 v16-v19）上要幂等：v21 仅 `createTable`，video_books 已由 from<20 收敛建好。
