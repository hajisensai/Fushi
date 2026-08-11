## BUG-1504 · 拖放字幕到视频卡失败无任何提示

- **报告**：2026-08-11（用户：BUG-1490 修复过程中被点名、当时刻意未纳入范围，本轮用户拍板修）
- **真实性**：✅ 真 bug。同一个坏字幕，拖到播放页给「无法加载该字幕」，拖到主页视频卡上**什么都没有**。
- **[x] ① 已修复** — 见「修法」，commit 见文末。
- **[x] ② 已加自动化测试** — 见「测试」。

### 根因（不是「少写了一个 try」）

真因是**这条链路没有结果所有者**，导致 helper 的「结果分类」契约被异常通道绕过：

1. `fushi/lib/src/pages/implementations/home_video_page.dart:1133`（修前）
   `_attachSubtitleToVideoCard(hit!, files.subtitles.first);` —— 裸调用，无 `await` 也无
   `unawaited`。外层 `_handleVideoDrop` 是 `void`，`FileDropCallback` 本身也是
   `void Function(...)`（`fushi/lib/src/media/drag_drop/fushi_file_drop_target.dart:9`），
   **Future 在类型协变处就被丢掉**。异步失败没有任何调用栈能承接。
2. `fushi/lib/src/media/video/video_subtitle_attach.dart:88-123`（修前）
   `attachSubtitleToVideoBook` 返回一个分类结果枚举，却**不是全函数**：只有 `File.copy`
   包了 try，而 `Directory.create`(:89)、`readTextWithEncoding`(:104)、
   `parseSubtitleContentAsync`(:105)、`repo.saveSubtitleSelection`(:119) 全裸。
   这四处任一抛出，Future 就以错误完成 → 结合 ①，直接变成 unhandled async error。
3. 后果：`home_video_page.dart:1258`（修前）那句 `messenger.showSnackBar` 是**死代码**——
   作者明明写全了五分支反馈，却被 fire-and-forget 的结构整条废掉。

所以「加个 try」只是把异常吞在更里面一层：真正要定的是**谁发起、谁等待、谁呈现**。

同一入口族的第二个洞：`fushi/lib/src/pages/implementations/home_page.dart:1477`（修前），
字幕搜索页安装到「已存在视频」的 `onInstalled` 回调 **只在 `attached` 时做事**，
`playlistNeedsPlayer` / `unsupported` / `copyFailed` / `emptyCues` 四种失败与「视频不在库」
一律静默，弹窗照样 `Navigator.pop` 报喜——「字幕下载成功但没挂上」与「挂上了」在 UI 上无法区分。

### 修法

**所有权**：结果所有者定为 `_attachSubtitleToVideoCard`（它 await 落库、把每种结果变成
SnackBar）；drop 回调只负责发起，改成显式 `unawaited(...)`。要让这个所有权成立，
`attachSubtitleToVideoBook` 必须是**全函数**——所以：

- `video_subtitle_attach.dart`：拷盘（含 `AppPaths` 取目录 + `Directory.create`）与
  `saveSubtitleSelection` 各自包 try → `SubtitleAttachOutcome.persistFailed`；
  读+解析不再自己做，转调新公开入口 `loadExternalSubtitleCueResult`（不抛）。
- `video_subtitle_source.dart`：把原私有 `_loadExternalCues` 提成公开
  `loadExternalSubtitleCueResult(path, bookUid, {contentReader})`，成为「本地字幕文件 → cue」
  的唯一入口；`_readAndParse` 加可选 `contentReader`（仅测试注入）。
  播放页选外挂源与主页挂载从此共用同一份失败分类。
- **失败分类复用 BUG-1490 的 `SubtitleCueLoadFailure` 四态**，不在主页再造一套语义：
  `SubtitleAttachOutcome` 从 5 态收敛到 4 态
  （`attached` / `playlistNeedsPlayer` / `persistFailed` / `cueLoadFailed`），
  `unsupported` 与 `emptyCues` 并入 `cueLoadFailed` + `cueFailure`
  （`unsupportedFormat` / `parseFailed`），并新增了原本根本没有的 `fileUnreadable`。
- 新增 `fushi/lib/src/media/video/video_subtitle_attach_messages.dart`：
  `subtitleAttachMessage()` 是唯一的「结果 → 文案」纯映射，两个入口同源派生。
- `home_page.dart` 的 `onInstalled`：`book == null` 与所有非 `attached` 结果都经
  `_showVideoDiscoveryMessage` 呈现（新 i18n key `video_subtitle_attach_book_missing`）。

**成功路径零变化**（cue 数、落库内容、`video_subtitle_attached_to_video` 文案均不变）。
唯一有意的文案变更：`parseFailed`（原 `emptyCues`）从「可能是图形或不支持的字幕轨」改为
「无法读取该字幕文件（内容损坏或为空）」——扩展名已过 srt/ass/ssa/vtt 校验，说「图形轨」
必然是错的，与 BUG-1490 同一条理由。

### 同类入口普查（拖放 / 落库，2026-08-11）

| 入口 | `file:line` | fire-and-forget | 失败可见 | 本轮 |
|---|---|---|---|---|
| 主页视频卡拖字幕 `_attachSubtitleToVideoCard` | `home_video_page.dart:1133` / 实现 `:1210` | 是（裸调用） | 否（异常绕过全部 SnackBar） | ✅ 修 |
| 字幕搜索页安装到已存在视频 `onInstalled` | `home_page.dart:1477` | 是（外层 `unawaited(_install())`） | 否（只在成功时做事） | ✅ 修 |
| 游戏库拖 exe 落库 `_handleDrop` | `games_library_page.dart:192` | 形式 `unawaited`，等价 f&f | 否（`_repo.addAll` 抛则无 toast） | ❌ 未修 |
| 书架/漫画拖放 `_handleShelfDrop` | `reader_history/books.part.dart:1071` | 是（6 个 Future 全裸调） | 部分（开框前的 DB/开包异常不可见；`:1082` 还在 drop 栈里**同步**解 zip） | ❌ 未修 |
| 视频卡/合集拖标签 `_addTagToVideoBook` / `_addTagToVideoCollection` | `home_video_page.dart:1957` / `:1986` | 是 | 否（只有「已有该标签」和成功两条 toast） | ❌ 未修 |
| 书卡/SRT 卡拖标签 `_addTagToBook` / `_addTagToSrtBook` / `_addTagToCollection` | `reader_fushi_history_page.dart:2049` / `:1614`；`books.part.dart:77` | 是 | 否（同上形态，共 5 份复制） | ❌ 未修 |
| 卡片落进合集 `_addMediaToCollection` | `home_video_page.dart:1929`；`games_library_page.dart:498`；`reader_fushi_history_page.dart:1048` | 是 | 落库可见（`collection_drag.dart:50` 已全 catch + 提示），后续刷新失败不可见 | ⚪ 已合规 |
| 播放页拖字幕 `_handlePlaybackDrop` | `video_fushi_page.dart:6353`（`unawaited` :6366） | 显式 unawaited | 部分（目录创建 / cue 解析异常不可见） | ❌ 未修 |
| 视频/书籍/有声书/漫画导入对话框拖放 | `video_import_dialog.dart:712`；`book_import_dialog.dart:269`；`audiobook_import_dialog.dart:187`；`manga_import_dialog.dart:248` | 是 | 落库走 `runImport`（全 catch + toast），可见；`book_import_dialog` 的 sidecar/封面预填 IO 不可见（不落库） | ⚪ 基本合规 |
| 词典拖放导入 | `dictionary_dialog_page.dart:567`；`home_dictionary_page.dart:399` | 混（后者 `unawaited`） | 可见（逐文件 try/catch + 汇总 toast） | ⚪ 已合规 |

未修的三族里最值得下一轮做的是「拖标签」：同一份「成功才提示、失败静默」模板复制了 5 份，
而修复范式现成（`collection_drag.dart:50` 的永不抛出收口函数），照抄即可。

### 测试

- `fushi/test/media/video/video_subtitle_attach_test.dart`（行为层，真 Drift DB）
  - 源文件不存在 → `persistFailed`，不抛、不落库；
  - 读文件抛异常（注入 `contentReader`）→ `cueLoadFailed(fileUnreadable)`，不逃逸；
  - DB 关闭后落库 → `persistFailed`，不逃逸；
  - 坏字幕 → `cueLoadFailed(parseFailed)`；不支持扩展名 → `cueLoadFailed(unsupportedFormat)`；
  - 四种失败文案非空且互不相同；成功路径（同 bookUid、2 条 cue、拷盘）原样保留。
- `fushi/test/pages/home_video_subtitle_drop_guard_test.dart`（源码守卫）
  - helper 是全函数（两处 catch + 两个 outcome + 复用 `SubtitleCueLoadFailure`）；
  - drop 回调必须 `unawaited(_attachSubtitleToVideoCard(`；
  - 两个入口都经 `subtitleAttachMessage(` 呈现失败。
  - **为什么只能到源码层**：真实拖放需要 OS 拖放事件 + 卡片屏幕矩形命中，headless 测不到。
  - 变异实测：4 处改坏源码逐条确认对应测试变红（去 `unawaited` / 换掉 `subtitleAttachMessage` /
    `catch` 改 `on Never catch` / 删掉落库 try-catch），再反向替换还原。
- `fushi/test/media/video/video_subtitle_source_test.dart`：`_functionBody` 原来会把命名可选
  参数的 `{...}` 当函数体截走（守卫会变成永远看不到函数体的**假绿**），一并修正为先跳过参数表。

### 备注

改动文件：`video_subtitle_attach.dart`、`video_subtitle_attach_messages.dart`（新）、
`video_subtitle_source.dart`、`home_video_page.dart`、`home_page.dart` + 17 语言 i18n。
