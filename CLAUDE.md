# hibiki（Hoshi Reader Android）

基于 jidoujisho fork 的日语沉浸式阅读器，对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)、https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md 。核心：EPUB + Yomitan 词典 + Anki 制卡 + 有声书同步。

## 仓库结构

- 仓库根：`d:\APP\vs_claude_code\hibiki\`
- Flutter app：`hibiki/hibiki/`（子目录，非根）
- 计划文档：根目录下 `AUDIOBOOK_SYNC.md`、`SUBTITLE_TO_EPUB_PLAN.md` 等
- 遗留 / 参考：`legacy/`、`chisa/`

## 当前状态

**Phase 1 已完成**：剥离 YouTube / VLC / 浏览器 / ChatGPT / 歌词 / Mokuro，保留 Reader + Dictionary + Anki。debug APK 可编译。

**Phase 2 进行中**：
- UI 精简：HomePage 已去掉 BottomNavigationBar，直接显示书架
- 有声书同步（SMIL + JSON 对齐）：已完成全链路（Isar schema → 播放器 → WebView 桥 → 阅读器集成 → 导入 UI）
- 字幕独立导入：SRT / LRC / VTT / ASS 四种 parser 齐全，导入对话框统一接入
- 字幕 → EPUB 渲染改造进度（见 `SUBTITLE_TO_EPUB_PLAN.md`）：
  - PR-A 完成：`CuesToEpub`（EPUB 生成器 + `TtuIdbPayload`/`TtuSection` 数据类）
  - PR-B 完成：导入时注入 ttu IndexedDB（`ttuBookId` 字段），打开走 `ReaderTtuSourcePage`
  - PR-C 完成：AudiobookBridge 接字幕 EPUB（`data-cue-id` 高亮/点击跳转），后续一路修 cue 滚动/翻页/章节切换的细节 bug
  - PR-D 完成：删除旧的 `SrtReaderPage` 字幕列表渲染，字幕书统一走 ttu reader

**Phase 3 已完成**：Material 3 UI 打磨 7 个 PR 全部落地（主题基座 / 词典弹窗 / 书架卡片 / 搜索栏 / 对话框 / 播放条 / FollowPill），详见 `UI_POLISH_PLAN.md`。

## 核心技术栈

- Flutter **3.41.6** / Dart 3.11.4（固定，见 `project_build_env` 记忆）
- WebView：ッツ (ttu) Ebook Reader 渲染 EPUB
- 存储：Isar（词典、阅读进度、SrtBook / Audiobook / AudioCue 等）+ Hive（部分偏好）
- NLP：MeCab + Ve（分词 + deinflection）
- 制卡：AnkiDroid API（AnkiConnect 为后续可选）
- 平台最低：Android 8.0（API 26）

## 关键文件（当前仓库，非 jidoujisho 原位置）

- 阅读器入口：`hibiki/hibiki/lib/src/pages/implementations/reader_ttu_source_page.dart`
- 书架：`reader_ttu_source_history_page.dart`
- 有声书桥：`lib/src/media/audiobook/audiobook_bridge.dart`
- 字幕 parser：`lib/src/media/audiobook/{srt,lrc,vtt,ass}_parser.dart`
- 字幕导入 UI：`lib/src/media/audiobook/srt_import_dialog.dart`（命名沿用 srt，实际四格式通用）

## 开发原则

- 不从零重写，在现有代码上删减 / 重构
- 遇到问题先定位，不回退到简化版
- 每个 PR 聚焦单一模块，commit 信息说明"为什么"
- 修改流程三步缺一不可：**analyze → 编译 APK → commit**（见 feedback 记忆）
- 字幕相关工作遵循 `SUBTITLE_TO_EPUB_PLAN.md`：所有字幕格式统一走 EPUB 渲染，不做字幕列表 UI

## 已知坑

- Isar 已停止维护，暂继续使用；`build_runner 2.4.4` 与当前 Flutter / Dart 不兼容，`.g.dart` 需手写或用独立脚本生成
- 11 个 pub cache 包需打 v1 embedding 补丁（见 `project_build_env` 记忆）
- MeCab 字典打包走 Android NDK
- ッツ reader 运行在 WebView，需验证 Android WebView 版本兼容
