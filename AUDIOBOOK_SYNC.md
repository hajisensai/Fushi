# Hoshi Reader Android — 有声书同步朗读（Audiobook Sync）设计

## 目标
打开一本 EPUB 小说时，同时加载对应的有声书音频；播放时自动高亮当前朗读到的句子；翻页后继续跟踪；用户点击句子可跳转音频播放位置，点击播放位置可跳转到对应文本。

## 总体策略
核心问题是 **文本 ↔ 音频时间轴的对齐**。三种可行路径，按实现成本递增：

1. **预对齐文件（首选）**：使用 [EPUB 3 Media Overlays](https://www.w3.org/publishing/epub3/epub-mediaoverlays.html) / SMIL 文件，声明 `<text src="chapter1.xhtml#s1"/>` ↔ `<audio clipBegin clipEnd/>`。这是业界标准（DAISY / EPUB3 有声书）。
2. **外部时间戳文件**：用户提供 `book.json`（或 LRC/SRT），每条含 `{chapterId, sentenceIndex, text, start, end}`。最灵活，适配网上流传的"文本+MP3"资源。
3. **强制对齐（后续可选）**：用 [aeneas](https://github.com/readbeyond/aeneas) / WhisperX 把纯音频自动对齐到文本，离线一次性生成上面的 JSON。放到桌面工具链，App 不做。

Phase 1 实现 1 + 2，Phase 2 考虑 3。

## 数据模型（Isar）

```dart
// 有声书元数据，一本 EPUB 可挂载 0..1 个
@collection
class Audiobook {
  Id id = Isar.autoIncrement;
  @Index(unique: true) late String bookUid;     // 对应 MediaItem.uniqueKey
  late String audioRoot;                        // 音频文件目录（本地）或 base URL
  late String alignmentFormat;                  // 'smil' | 'json' | 'lrc'
  late String alignmentPath;                    // 对齐文件路径
}

// 对齐片段，按句粒度
@collection
class AudioCue {
  Id id = Isar.autoIncrement;
  @Index() late String bookUid;
  @Index() late String chapterHref;             // EPUB spine item，如 'OEBPS/ch01.xhtml'
  late int sentenceIndex;                       // 章节内句序
  late String textFragmentId;                   // DOM id 或 CSS selector/XPath
  late int startMs;
  late int endMs;
  late int audioFileIndex;                      // 多段音频时用
}
```

对齐文件解析一次，批量写入 `AudioCue`；运行时只按 `(bookUid, chapterHref)` 查询当前章的 cue 列表并缓存到内存。

## 对齐文件格式

### Media Overlays（SMIL）
EPUB3 标准，`content.opf` 里 spine item 带 `media-overlay="ch01_smil"`，SMIL 文件：

```xml
<par id="s1">
  <text src="ch01.xhtml#s1"/>
  <audio src="audio/ch01.mp3" clipBegin="0:00:00.000" clipEnd="0:00:04.230"/>
</par>
```

解析器：`lib/src/media/audiobook/smil_parser.dart`，用 `xml` 包遍历 `<par>`，产出 `AudioCue`。XHTML 里对应的 `<span id="s1">…</span>` 就是高亮目标。

### 自定义 JSON（无 Media Overlays 时的 fallback）

```json
{
  "bookUid": "...",
  "audio": ["audio/ch01.mp3", "audio/ch02.mp3"],
  "cues": [
    {"chapter": "ch01.xhtml", "i": 0, "selector": "#p1 > span:nth-child(1)",
     "start": 0, "end": 4230, "file": 0, "text": "吾輩は猫である。"}
  ]
}
```

`selector` 优先用 DOM id，回退到 CSS selector，再回退到文本匹配（normalize 后 indexOf）。

## 音频播放

使用 **`just_audio`** + **`audio_service`**（后台播放 + 锁屏控制）。不再引入 VLC（Phase 1 已被移除）。

- `AudiobookPlayerController`（ChangeNotifier），持有 `AudioPlayer`，暴露 `play/pause/seek/skipToCue(cue)`；
- 订阅 `player.positionStream`（约 200ms 粒度），在当前章节的 cue 数组里做 **二分查找** 定位当前句，发出 `currentCue` 通知；
- 切章节时加载对应音频文件（若分章）或 seek 到章节起点（若整本一个文件）。

## WebView ↔ Flutter 桥

ッツ Ebook Reader 的阅读器是 WebView。需要双向通道：

### Flutter → WebView：高亮当前句
注入全局函数：

```js
window.__hoshiHighlight = function (selector) {
  document.querySelectorAll('.hoshi-active').forEach(e => e.classList.remove('hoshi-active'));
  const el = document.querySelector(selector);
  if (!el) return;
  el.classList.add('hoshi-active');
  // 翻页跟踪：横书用 scrollLeft，纵书用 scrollTop/Left（ッツ 是 column-based）
  el.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'smooth'});
};
```

CSS（注入 `user_stylesheet`）：

```css
.hoshi-active { background: rgba(255,220,0,.45); border-radius:2px; }
```

Flutter 侧每次 `currentCue` 变化时：`webView.evaluateJavascript(source: "__hoshiHighlight(${jsonEncode(cue.textFragmentId)})")`。

### WebView → Flutter：点击句子跳转播放

```js
document.addEventListener('click', (e) => {
  const span = e.target.closest('[data-hoshi-sid]');
  if (span) window.hoshiBridge.postMessage(JSON.stringify({
    type: 'seekToSentence', chapter: __currentChapter, sid: span.dataset.hoshiSid
  }));
}, true);
```

若原始 XHTML 没有句子级 span，在章节加载后做一次 **DOM 标注**：按 `。！？」` 分句，包裹 `<span data-hoshi-sid="n">`。用 TreeWalker 避免打破既有标签结构（跳过 `<ruby>` 内部）。

## 翻页跟踪
ッツ 用 CSS columns 分页，`scrollIntoView` 足以把高亮句带入视口；另外监听 ッツ 自身的页变事件（如 `ttsu:pagechange`），确保高亮仍在当前页内，否则暂停自动滚动（防止播放抢走用户手动翻页位置）。

## UI

- 阅读器底部呼出条新增 **播放控件**：播放/暂停、±15s、倍速（0.75/1.0/1.25/1.5）、当前句文本、总进度。
- 长按句子 → 菜单「从此处播放」。
- 书架书卡角标显示是否已挂载有声书。
- 设置页新增「导入有声书」：选 EPUB → 选音频目录 / zip → 选对齐文件（或自动检测 SMIL）。

## 关键文件（新增）

- `lib/src/media/audiobook/audiobook_model.dart` — Isar schemas
- `lib/src/media/audiobook/smil_parser.dart`
- `lib/src/media/audiobook/json_alignment_parser.dart`
- `lib/src/media/audiobook/audiobook_controller.dart` — 播放 + cue 跟踪
- `lib/src/media/audiobook/audiobook_importer.dart` — 导入流程
- `assets/ttu-ebook-reader/hoshi_audio_bridge.js` — 注入脚本
- `lib/src/pages/implementations/reader_page.dart` — 集成点（已存在，需改）

## 实现顺序（PR 粒度）

1. **PR1 数据层**：Isar schemas + SMIL/JSON 解析器 + 单元测试（用 epub3-samples 里的 moby-dick-mo）。
2. **PR2 播放器**：接入 just_audio + audio_service，`AudiobookPlayerController`，不接 WebView，先跑命令行/简单页面验证 cue 跟踪。
3. **PR3 WebView 桥**：注入 JS、句子自动分割与标注、高亮 CSS、点击回传。
4. **PR4 阅读器集成**：底部播放条、翻页兼容、长按「从此处播放」。
5. **PR5 导入 UI**：设置页导入流程、书架角标。
6. **PR6 打磨**：倍速、锁屏控制、断点续播（记录最后 cue）、错误恢复（音频缺失提示）。

## 已知坑

- **纵书高亮**：ッツ 纵书模式 `writing-mode: vertical-rl`，`scrollIntoView` 的 `inline` 轴意义会翻转，需实测；必要时自行计算 `scrollLeft`。
- **Ruby 标签**：分句时若切断 `<ruby>…<rt>…</rt></ruby>` 会破坏振假名，TreeWalker 遇到 ruby 整体跳过。
- **句子偏移漂移**：对齐文件常以「段落+句序」而非 DOM id 锚定，不同渲染器产生的 DOM 不稳定；首选要求 alignment 携带原文 `text`，运行时做 normalize 后的模糊匹配兜底。
- **多音频文件无缝衔接**：`just_audio` 用 `ConcatenatingAudioSource`，每段记录累计偏移，cue 的 `audioFileIndex` 换算成全局 position。
- **音频格式**：优先 MP3/M4A/OGG（just_audio 原生支持）；用户上传前提示转码。
- **Isar 已停维**：Phase 1 已决定暂留 Isar，新 collections 跟随现有策略，未来统一迁移。
