## BUG-456 · SRT书绕过openMedia致currentMediaSource为null收藏制卡无句子

- **报告**：2026-06-29（用户：Windows 11，左键查词）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/pages/implementations/reader_history/books.part.dart:107`（`_openSrtBook` 直接 `Navigator.push` ReaderHibikiPage，绕过 `appModel.openMedia`）。
- **现象**：SRT/有声书（如「安達としまむら」）里左键查词后，点弹窗顶栏 ☆ 收藏句子报「未选择句子」，点「+」制卡卡片无句子。普通 EPUB 正常。

### 根因（真机日志实证）

收藏句子（`chrome.part.dart:1478`）、制卡句子（`mining.part.dart:22`）、句子音频（`audiobook.part.dart:743`）、tap 查词写句（`lookup.part.dart:166`）全部读写 `appModel.currentMediaSource?.currentSentence`。`appModel.currentMediaSource` 只在 `appModel.openMedia()`（`app_model.dart:2857`）里被赋值。

书架普通 EPUB 经 `openMedia` 打开（`reader_hibiki_history_page.dart:974`）→ currentMediaSource = ReaderHibikiSource，正常。但 **SRT 书经 `_openSrtBook` 直接 `Navigator.push(ReaderHibikiPage(...))`**，从不调 `openMedia` → `currentMediaSource` 恒为 **null** → 上述所有 `currentMediaSource?.xxx` 全是空操作（`?.` 落空）：`setCurrentSentence` 写不进、`currentSentence` 读出空。

真机插桩日志（修复前 / 修复后）铁证：
```
修复前: handleTextSelected: src=null              wrote="null"
        toggleFavorite read:  src=null              currentSentence=""
修复后: handleTextSelected: src=ReaderHibikiSource wrote="しまむら（母）は…ごっつい。"
        toggleFavorite read:  src=ReaderHibikiSource currentSentence="しまむら（母）は…ごっつい。"
```
注意修复前 JS 取句完全正确（`dataSentence="しまむら（父）は…雰囲気が漂う。"`）——历次 TODO-956 都在打磨「句子值/兜底」，但真正丢的是**写入目标 currentMediaSource 为 null**，所以再好的句子也被丢弃。这是同症状反复未愈的真因。

### 修复

`_openSrtBook` 改为经 `appModel.openMedia(ref, mediaSource: ReaderHibikiSource.instance, item: _srtBookMediaItem(book))` 打开（与书架普通 EPUB 同路径）。`openMedia` 内部用 `ReaderHibikiSource.buildLaunchPage` 构建**完全相同**的 `HibikiAppUiScaleNeutralizer(ReaderHibikiPage(...))`（`_extractBookKey` 从 item.mediaIdentifier 还原同一 bookKey），等价但补齐 `currentMediaSource` 注册 + 与普通书一致的 wakelock/沉浸/历史，消除「SRT 书特例打开路径」。

### 影响范围 / 兼容

- 普通 EPUB 打开路径不变。
- SRT 书现在与普通书行为一致（含收藏/制卡/句子音频/历史/沉浸），均依赖 currentMediaSource。
- 退出经 base_source_page.onWillPop → closeMedia（currentMediaSource 现非 null，生命周期对称）。
- 真机已验：src=ReaderHibikiSource、currentSentence 取到完整句、收藏不再报空。

- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/reader_history/books.part.dart`（`_openSrtBook` → `openMedia`）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/srt_book_open_media_guard_test.dart`（源码守卫：`_openSrtBook` 经 `appModel.openMedia` 打开、不再直接 `Navigator.push(ReaderHibikiPage(`）。
- **备注**：与 BUG-455（右键/原生菜单「查词」绕过 currentSentence 写入）同症状不同根因——455 是写句路径缺失，456 是写入目标 source 为 null；两者都已修。整页历史 WebView 不便 mount，故用源码守卫锁接线。
