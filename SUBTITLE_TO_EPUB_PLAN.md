# 字幕 → 电子书渲染改造计划

**目标**：导入 SRT / LRC / VTT / ASS 后，以 EPUB 书本形式阅读（段落连续文本），时间戳仅作音频对齐元数据，不再显示为字幕列表。

## 背景

- iOS Hoshi Reader（[Manhhao/Hoshi-Reader](https://github.com/Manhhao/Hoshi-Reader)）本身**不处理字幕文件**，只是纯 EPUB 阅读器。本方案为 hibiki 独有扩展，无上游可抄。
- 核心思路：字幕 parser 已统一产出 `AudioCue`，将其转为 EPUB 后复用现有 ッツ (ttu) reader + `AudiobookBridge`，获得阅读/查词/Anki/音频高亮全套能力。

## 现状

| 模块 | 文件 | 状态 |
| --- | --- | --- |
| SRT parser | `lib/src/media/audiobook/srt_parser.dart` | ✅ |
| LRC parser | `lib/src/media/audiobook/lrc_parser.dart` | ✅ |
| VTT parser | `lib/src/media/audiobook/vtt_parser.dart` | ✅ |
| ASS parser | `lib/src/media/audiobook/ass_parser.dart` | ✅ |
| 导入对话框（四格式） | `lib/src/media/audiobook/srt_import_dialog.dart` | ✅ |
| 当前渲染（**字幕列表式**，待替换） | `lib/src/pages/implementations/srt_reader_page.dart` | ⚠️ |
| EPUB 阅读器 | `lib/src/pages/implementations/reader_ttu_source_page.dart` | ✅ |
| 音频桥 | `lib/src/media/audiobook/audiobook_bridge.dart` | ✅ |

## PR 拆分

### PR-A　Cues → EPUB 转换器

新增 `lib/src/media/audiobook/cues_to_epub.dart`：

- 输入 `List<AudioCue> + title + author`，输出 EPUB 文件路径（写入临时/缓存目录）
- 每条 cue 包裹 `<span data-cue-id="N" data-start="X.XX" data-end="Y.YY">text</span>`
- 段落策略：连续 cue 合并为 `<p>`，遇长停顿（> 2s）或显式段落标记时分段
- 章节策略：默认阈值 **每章 ≤ 500 条 cue 或 ≤ 10 分钟**（先到者优先），阈值走常量便于调整
- 生成最小占位封面（纯色 + 标题），避免 ttu reader 因缺封面报错
- 使用 `archive` 包写 `mimetype` / `META-INF/container.xml` / `content.opf` / `toc.ncx` / `chapter-N.xhtml`

**风险缓解（必须包含在 PR）：**
- 端到端单测：生成后用 `epubx` 回读，断言 mimetype / OPF manifest / spine 顺序 / 章节文本完整性
- 单测覆盖：段落合并、章节切分、XML 特殊字符转义、BOM 处理

### PR-B　导入流程改接 ttu 阅读器

- `SrtImportDialog` 导入完成后调用 PR-A 生成 EPUB，写入 ッツ 书库目录
- `SrtBook` 模型新增字段 `generatedEpubPath`
- 阅读入口改为 ttu reader，不再走 `SrtReaderPage`
- 书架入口（`reader_ttu_source_history_page`）自然列出

**风险缓解：**
- 写入前立即用 `epubx` 打开一次 smoke test，失败则回滚并 Toast 提示
- `generatedEpubPath` 写入前先验证文件存在且 `size > 0`

### PR-C　AudiobookBridge 接字幕 EPUB

- 复用现有 bridge，`AudioCue.chapterHref` 指向生成的 EPUB 章节
- 确认 `data-cue-id` 选择器在注入 CSS 里命中
- 点击 span → 跳转该 cue 的音频时间
- 播放中 `positionStream` → 高亮对应 span + 自动滚动（现有逻辑，换 DOM 源）

**风险缓解：**
- 实机验证清单（写入 PR 描述 Test Plan）：SRT/LRC/VTT/ASS 各一本 → 章节打开 → 点击 span 跳转 → 播放高亮 → 跨章节切换
- bridge 注入前检查 `data-cue-id` 选择器命中数 > 0，否则 log 警告

### PR-D　删除旧列表渲染

- 移除 `SrtReaderPage` 及其路由
- 书架 tap 一律进 ttu reader

**风险缓解：**
- 回归矩阵：**4 格式 × (查词 / Anki 制卡 / 音频对齐 / 纵书切换)** 全绿才合并
- `SrtReaderPage` 保留一个 PR 周期（标 `@Deprecated`），确认无回退需求再删

## 验收标准（全局）

- 四种字幕格式导入后均呈 EPUB 段落视图，无时间戳前缀污染阅读
- 音频播放时当前 cue 高亮、自动滚动
- MeCab 分词 + 词典弹窗 + Anki 制卡在字幕来源 EPUB 上与真实 EPUB 行为一致
- 纵书 / 横书切换正常

## 备注

- 每个 PR 完成后：analyze → 编译 APK → commit（项目既定流程，见根 `CLAUDE.md`）
- 本文档随 PR 推进更新状态；全部合并并经线上验证后可归档或删除
