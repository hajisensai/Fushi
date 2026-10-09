import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'anki_compact_glossaries.dart';
import 'anki_models.dart';
import 'lapis_note_type.dart';
import 'lapis_preset.dart';

/// TODO-779：单词远程音频获取的结果载体。两 backend 的远程音频路径
/// （`_storeRemoteAudio` / `_addRemoteAudio`）共用，把过去只能返回的裸 ref
/// （`String?`，失败时静默 `null`）升级成「ref + 可见失败原因」二元组。
///
/// - [ref] 非空 = 成功：裸媒体引用（AnkiConnect 的裸文件名 / AnkiDroid `addFileToMedia`
///   返回的文件名），调用方包成 `[sound:ref]` 写进卡片。
/// - [failureReason] 非空 = **可见失败**：卡片仍会建好但音频落空，原因（含 HTTP 码/URL）
///   冒泡到 [MineOutcome.audioWarning]，让用户看到「音频获取失败」而非盲猜。
/// - 两者皆 `null` = 本就没有音频要取（[AnkiAudioRefKind.empty]）或本地文件缺失，
///   不是错误、无需提示（与旧版静默 `null` 行为一致，Never break userspace）。
///
/// **关键不变式**：[failureReason] 非空时 [ref] 必须为 `null`——绝不把非 200 的错误
/// 响应体当 .mp3 字节写入媒体（HBK-AUDIT-019：会嵌坏文件）。
@immutable
class AudioFetchOutcome {
  const AudioFetchOutcome._({this.ref, this.failureReason})
    : assert(
        ref == null || failureReason == null,
        'A successful audio fetch (ref) cannot also carry a failure reason.',
      );

  /// 成功：拿到裸媒体引用 [ref]。
  const AudioFetchOutcome.stored(String ref) : this._(ref: ref);

  /// 没有音频要取 / 本地文件缺失：既非成功也非可见失败（不提示）。
  const AudioFetchOutcome.none() : this._();

  /// 可见失败：[reason] 含 HTTP 码/URL 或异常摘要，冒泡到 [MineOutcome.audioWarning]。
  const AudioFetchOutcome.failed(String reason) : this._(failureReason: reason);

  /// 非空 = 成功取得的裸媒体引用（包成 `[sound:ref]`）。
  final String? ref;

  /// 非空 = 可见失败原因（卡片仍建好，音频落空）。
  final String? failureReason;
}

/// TODO-779：字段渲染的结果载体。把渲染出的卡片字段 [fields] 与**部分成功**信号
/// [audioWarning]（单词远程音频下载失败原因）一起回传，让 `_mineEntryInner` /
/// `updateMinedNote` 的成功分支能把警告带进 [MineOutcome.success]。
@immutable
class RenderedMinedFields {
  const RenderedMinedFields(this.fields, {this.audioWarning});

  /// 渲染出的卡片字段（字段名 → 值，仅含非空值）。
  final Map<String, String> fields;

  /// 非空 = 单词远程音频下载失败的简短原因（含 HTTP 码/URL），来自
  /// [AudioFetchOutcome.failureReason]。
  final String? audioWarning;
}

/// 封面媒体扩展名里属于**视频片段**的那几种（不渲染成 `<img>`）。
const Set<String> kAnkiVideoCoverExtensions = <String>{'mp4', 'webm'};

/// 视频片段里在卡片内 `<video>` **内嵌**播放的扩展名（其余视频走 `[sound:]`）。
///
/// 只有 WebM：Anki 桌面的 Qt WebEngine 不带专利编解码器，**没有 H.264 也没有 AAC**，
/// `<video>` 放 MP4 会失败；VP9/AV1 + Opus 的 WebM 在 Anki 桌面与 AnkiDroid WebView 都
/// 能内嵌解码。Anki 的媒体检查认 `<video src>`（rslib `text.rs` 的媒体标签正则含
/// `video`），不会把片段当成未使用媒体删掉。
const Set<String> kAnkiInlineVideoCoverExtensions = <String>{'webm'};

String _lowerExtension(String name) {
  final int dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// 路径 / 文件名是否为卡片内嵌播放的视频片段（见 [kAnkiInlineVideoCoverExtensions]）。
bool isAnkiInlineVideoCover(String? pathOrName) =>
    pathOrName != null &&
    kAnkiInlineVideoCoverExtensions.contains(_lowerExtension(pathOrName));

/// 纯函数：把已写入 Anki 媒体库的封面文件名 [mediaName] 渲染成卡片字段里的引用串。
///
/// - 图片（jpg / png / gif / webp / avif…）→ `<img src="name">`（`src` 做 HTML 转义；
///   文件名由内容哈希定，实际不含特殊字符，转义只是守底线）；
/// - 内嵌视频（[kAnkiInlineVideoCoverExtensions]：WebM 音画同步片段）→
///   [inlineVideoCoverHtml]，翻面自动播放一次、带播放条；
/// - 其余视频（MP4）→ `[sound:name]`——Anki 桌面用 mpv 弹窗播放，AnkiDroid 用内置
///   VideoView（`<video>` 在 Anki 桌面没有 H.264 解码器，见上）。
///
/// AnkiConnect 与 AnkiDroid 两个 backend 必须都经这里出引用串，杜绝一边会播视频、
/// 另一边把视频塞进 `<img>` 变成坏图。
String coverMediaRef(String mediaName) {
  final String extension = _lowerExtension(mediaName);
  if (kAnkiInlineVideoCoverExtensions.contains(extension)) {
    return inlineVideoCoverHtml(mediaName);
  }
  if (kAnkiVideoCoverExtensions.contains(extension)) {
    return '[sound:$mediaName]';
  }
  return '<img src="${const HtmlEscape().convert(mediaName)}">';
}

/// 在所有内嵌片段里挑**可见**的那一个从头播放、其余暂停的 JS（单行、无反斜杠 /
/// 反引号 / `${`）。
///
/// 为什么要挑：Lapis 背面把 `{{Picture}}` 渲染三次，由 CSS 按布局只显示一处——三个
/// `<video>` 都在 DOM 里，写 `autoplay` 属性会让隐藏的两个也出声（三重叠音）。
///
/// 为什么禁那三种字符：句子音频字段里的重播按钮会被 Lapis 插进一个 JS 模板字面量
/// （`addAudioButtons` 里的 `` `{{ExpressionAudio}}…{{SentenceAudio}}` ``），反引号 /
/// `${` / 反斜杠都会改写或截断那段字面量。守卫见 `inline_video_cover_test.dart`。
const String _inlineVideoPlayVisibleJs =
    "var vs=Array.prototype.slice.call(document.querySelectorAll('video.fushi-inline-video'));"
    'var v=vs.filter(function(e){return e.offsetParent!==null;})[0]||vs[0];'
    'vs.forEach(function(e){if(e!==v){e.pause();}});'
    'if(v){v.currentTime=0;var p=v.play();if(p&&p.catch){p.catch(function(){});}}';

/// 内嵌片段的卡片 HTML：`<video>`（无 `autoplay` 属性，理由见
/// [_inlineVideoPlayVisibleJs]），翻面时由它自己的 `oncanplay` 只播可见那一个。
///
/// BUG-2837：必须是内联事件属性，不能是 `<script>`——Anki 编辑器回写字段时用
/// DOMParser 删掉所有 `script` / `link` 标签（25.9 `editor.js`），卡片在编辑器里被
/// 改过一次，翻面自动播放就永久消失。事件属性原样保留（同卡句子音频字段的
/// `onclick` / `oncanplay` 实测完好）。
///
/// 每份副本都会触发 `canplay`，重播 seek 回 0 也会再触发；第一次触发把所有副本标上
/// `data-fushi-started`，其余一律直接返回。`canplay` 在媒体载入后才来，此时整张卡
/// 已插入 DOM、CSS 已生效，可见性判得准。`play()` 被拒（卡组关了自动播放 → Anki 恢复
/// 「播放需要用户手势」）时静默吞掉，留播放条给用户手动点。
String inlineVideoCoverHtml(String mediaName) =>
    '<video class="fushi-inline-video" '
    'src="${const HtmlEscape().convert(mediaName)}" '
    'preload="auto" playsinline controls style="max-width:100%" '
    'oncanplay="'
    "if(this.getAttribute('data-fushi-started'))return;"
    "Array.prototype.forEach.call(document.querySelectorAll('video.fushi-inline-video'),"
    "function(e){e.setAttribute('data-fushi-started','1');});"
    '$_inlineVideoPlayVisibleJs'
    '"></video>';

/// 页面上**没有**内嵌片段时，改用句子音频字段里的隐藏 `<audio>` 播放同一个片段文件的
/// 声音（单行、无反斜杠 / 反引号 / `${`）。
const String _inlineAudioPlayJs =
    "var a=document.querySelector('audio.fushi-inline-audio');"
    'if(a){a.currentTime=0;var q=a.play();if(q&&q.catch){q.catch(function(){});}}';

/// 内嵌片段的句子音频字段：重播按钮 + 一个隐藏 `<audio>`（同一个片段文件）。
///
/// - 按钮：页面上有内嵌片段 → 片段回到开头音画一起重播；没有（Lapis「音频卡」正面只
///   渲染 `{{SentenceAudio}}`、自定义模板把 Picture 放在另一面）→ 播隐藏 `<audio>`。
/// - `<audio>` 的 `oncanplay`：页面上**没有**内嵌片段时自动播放一次（音频卡正面照旧
///   自动出声）；有片段时什么都不做（画面那边的脚本负责播，不能叠音）。
///
/// 为什么用内联事件属性而不是 `<script>`：Lapis 背面把 `{{SentenceAudio}}` 插进一个
/// `<script>` 块里的 JS 模板字面量，字段里出现 `</script>` 会让 HTML 解析器提前结束那个
/// 脚本块，整张卡背面脚本失效。守卫见 `inline_video_cover_test.dart`。
///
/// 带 `replay-button` 类：内置 Lapis 的「点例句重播」逻辑查找
/// `.fushi-sentence-audio .replay-button` 并 `click()`，于是点例句同样重播，不必改模板；
/// 带 `fushi-synced-video-replay` 类：Lapis 靠它判断这张卡是同步片段卡。
String inlineVideoSentenceAudioHtml(String mediaName) =>
    '<button type="button" class="replay-button fushi-synced-video-replay '
    'fushi-inline-video-replay" aria-label="Replay video" '
    'onclick="event.stopPropagation();'
    "if(document.querySelector('video.fushi-inline-video')){"
    '$_inlineVideoPlayVisibleJs}else{$_inlineAudioPlayJs}'
    'return false;">&#9654;</button>'
    '<audio class="fushi-inline-audio" '
    'src="${const HtmlEscape().convert(mediaName)}" preload="auto" '
    'oncanplay="'
    "if(document.querySelector('video.fushi-inline-video')||"
    "document.querySelector('audio.fushi-inline-audio[data-fushi-started]'))"
    'return;'
    "this.setAttribute('data-fushi-started','1');"
    'var q=this.play();if(q&&q.catch){q.catch(function(){});}'
    '"></audio>';

/// Replay the native sentence video without adding a second autoplay entry.
/// Uses client-created buttons instead of undocumented client URL schemes.
const String synchronizedVideoReplayHtml =
    '<button type="button" class="fushi-synced-video-replay" '
    'aria-label="Replay video" onclick="event.stopPropagation();'
    "var p=document.querySelector('.fushi-synced-sentence-media "
    ".replay-button, .fushi-synced-sentence-media .replaybutton, "
    ".fushi-synced-sentence-media .soundLink, "
    ".fushi-sentence-audio .replay-button, .fushi-sentence-audio .replaybutton, "
    ".fushi-sentence-audio .soundLink');"
    'if(p){p.click();}return false;">&#9654;</button>';

/// 制卡字段的纯渲染逻辑：牌组 / 笔记类型解析、标签、字段映射、媒体引用、预检。
///
/// 不依赖 Flutter：app 的各 Anki 后端经 [BaseAnkiRepository] 混入，无头服务端的
/// 落地后端也直接混入同一份，两边渲染出的卡一字不差。
mixin AnkiNoteComposer {
  /// BUG-1549：按设置解析**当前制卡目标牌组**（id 优先、name 兜底）的单一真相。
  /// 此前这段两级 firstWhereOrNull 在 AnkiConnect / AnkiDroid / AnkiMobile 三个
  /// mine 路径各复制一份；解析结果的 `name` 现在还要随 [MineOutcome.success] 带回
  /// 成功 toast（toast 不再从 `selectedDeckName` 字段猜——旧存档只有 id 时它是
  /// null，但按 id 照样落卡成功，表现为「已添加到『』」空引号）。
  @protected
  AnkiDeck? resolveSelectedDeck(AnkiSettings settings) =>
      settings.availableDecks.firstWhereOrNull(
        (AnkiDeck d) => d.id == settings.selectedDeckId,
      ) ??
      (settings.selectedDeckName != null
          ? settings.availableDecks.firstWhereOrNull(
              (AnkiDeck d) => d.name == settings.selectedDeckName,
            )
          : null);

  @protected
  AnkiDeck selectDeckAfterFetch(List<AnkiDeck> decks, AnkiSettings current) =>
      decks.firstWhereOrNull((d) => d.id == current.selectedDeckId) ??
      (current.selectedDeckName != null
          ? decks.firstWhereOrNull((d) => d.name == current.selectedDeckName)
          : null) ??
      decks.firstWhereOrNull(
        (d) => !d.name.toLowerCase().startsWith('default'),
      ) ??
      decks.first;

  @protected
  AnkiNoteType selectNoteTypeAfterFetch(
    List<AnkiNoteType> noteTypes,
    AnkiSettings current,
  ) =>
      noteTypes.firstWhereOrNull((t) => t.id == current.selectedNoteTypeId) ??
      (current.selectedNoteTypeName != null
          ? noteTypes.firstWhereOrNull(
              (t) => t.name == current.selectedNoteTypeName,
            )
          : null) ??
      noteTypes.firstWhereOrNull(LapisPreset.matches) ??
      noteTypes.first;

  @protected
  Map<String, String> fieldMappingsAfterFetch(
    AnkiNoteType selectedNoteType,
    AnkiSettings current,
  ) {
    if (LapisPreset.matches(selectedNoteType) &&
        !_currentSelectionMatchesLapis(current)) {
      return LapisPreset.applyDefaults(selectedNoteType, {});
    }
    return current.fieldMappings;
  }

  bool _currentSelectionMatchesLapis(AnkiSettings current) {
    final matched = current.availableNoteTypes.firstWhereOrNull(
      (t) =>
          t.id == current.selectedNoteTypeId ||
          t.name == current.selectedNoteTypeName,
    );
    if (matched != null) return LapisPreset.matches(matched);
    return current.selectedNoteTypeName?.toLowerCase().contains('lapis') ??
        false;
  }

  // ── note tags：两 backend 共用（杜绝两份漂移） ──────────────────

  /// 标记每张经 Fushi 制出的卡片的固定 tag。所有 Fushi 制卡都会带上它，
  /// 便于用户在 Anki 里按来源筛选/统计。改名前的旧卡带的是字面 tag `hibiki`
  /// ——那是用户 Anki 库里的外部数据，只决定新卡默认值、不迁移不重写（W7）。
  static const String fushiTag = 'fushi';

  /// 书籍来源（EPUB 阅读、独立查词、有声书）的分类标签。
  static const String bookTag = 'book';

  /// 视频来源的分类标签。旧版本曾写入 `anime`；这里仅决定新制卡默认标签，不迁移
  /// 或重写用户 Anki 中的既有卡片，避免碰旧数据。
  static const String videoTag = 'video';

  /// galgame Hook 来源的分类标签（BUG-1137）。仅决定新制卡默认标签，既有误标
  /// `video` 的旧卡不迁移不重写。
  static const String gameTag = 'game';

  /// 「制卡所在字符数」标签的前缀（`chars_12345`）。下划线而非 `::`：Anki 里
  /// `chars::12345` 会在标签树下堆出成千上万个一次性子节点，而扁平 `chars_12345`
  /// 既能被 `tag:chars_*` 整体检索，也能按字面量排序看出制卡是在书的哪一段。
  static const String charPositionTagPrefix = 'chars_';

  /// 把制卡时的**全书绝对学习字数位置**格式化成单个 Anki tag（`chars_12345`）。
  ///
  /// 口径是 `countStudyChars`（全仓唯一计字口径，见 `stats/study_char_count.dart`），
  /// 与阅读进度条分子、`study_segments.chars` 同一根数轴——所以卡片上的数字和用户在
  /// 状态行看到的「已读字数」是同一个数，能直接对上。
  ///
  /// [absoluteChars] 为 `null` / 负数时返回 `null`：那是「锚点没取到」（章字数还没算完、
  /// JS 拿不到 caret），不是「在第 0 字」。宁可不打标签，也不打一个 `chars_0` 冒充书首。
  static String? formatCharPositionTag(int? absoluteChars) {
    if (absoluteChars == null || absoluteChars < 0) return null;
    return '$charPositionTagPrefix$absoluteChars';
  }

  /// 把制卡来源类别映射成分类标签；`null`（未指定来源）时返回 `null`（不追加）。
  static String? _categoryTagForSource(AnkiMiningSource? source) {
    switch (source) {
      case AnkiMiningSource.book:
        return bookTag;
      case AnkiMiningSource.video:
        return videoTag;
      case AnkiMiningSource.game:
        return gameTag;
      case null:
        return null;
    }
  }

  /// 解析用户配置的 [userTags]（空白分隔，即用户自定义 DIY 标签），按开关
  /// **追加** [fushiTag] 与 [source] 对应的分类标签后去重（保序）。
  ///
  /// - 追加而非覆盖：用户已配置的 tag 全部保留，只是按开关额外多 `fushi` + 分类标签。
  /// - 顺序：用户 tag → `fushi` → 分类标签（`book`/`video`/`game`）。
  /// - 去重：用户若已手动配置了 `fushi`/`book`/`video`/`game`，不会出现两个。
  /// - [includeHibiki]（TODO-117 开关）为 `false` 时不追加 `fushi`。
  /// - [includeCategory]（TODO-117 开关）为 `false` 时不追加分类标签；为 `true` 但
  ///   [source] 为 `null`（未指定来源，如独立查词/悬浮窗）时本就没有分类标签可加。
  /// - 两个开关默认 `true`，等价 TODO-115/062 的固定行为（Never break userspace）。
  /// - [titleTag]（TODO-681 开关，「自动添加书名到标签」）非空时追加**已清洗的书名/番名
  ///   标签**（去重后），书籍/视频同语义。
  /// - [collectionTag]（同「自动添加书名到标签」开关）非空时追加**已清洗的合集/系列名
  ///   标签**（去重后）：视频=播放列表系列名，书籍=所属合集名。与 [titleTag] 并列，二者
  ///   字面量不同则各成一个 tag，相同时由 [seen] 去重合并。
  /// - [charPositionTag]（「自动添加制卡位置到标签」开关）非空时追加**制卡所在字符数
  ///   标签**（`chars_12345`，由 [formatCharPositionTag] 产出）：小说阅读器制卡时这张
  ///   卡在全书第几个学习字处制的。只有书籍来源会注入；开关关闭或锚点取不到时为 `null`。
  /// - 两 backend（AnkiConnect / AnkiDroid）共用同一逻辑，避免一端漏加或漂移。
  @protected
  List<String> buildNoteTags(
    String userTags, {
    AnkiMiningSource? source,
    bool includeHibiki = true,
    bool includeCategory = true,
    String? titleTag,
    String? collectionTag,
    String? charPositionTag,
  }) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in userTags.split(RegExp(r'\s+'))) {
      if (tag.isEmpty || !seen.add(tag)) continue;
      result.add(tag);
    }
    if (includeHibiki && seen.add(fushiTag)) result.add(fushiTag);
    if (includeCategory) {
      final categoryTag = _categoryTagForSource(source);
      if (categoryTag != null && seen.add(categoryTag)) result.add(categoryTag);
    }
    // TODO-681 / BUG-393：「自动添加书名到标签」开启时调用方注入已清洗书名/番名标签
    // （书籍/视频同语义）。去重 [seen] 保证：经卡片创建器 `TagsField` 走 [userTags] 已带过
    // 同一标题标签时不会重复追加（两处清洗规则同源故字面量相同）。
    final clean = sanitizeTitleTag(titleTag);
    if (clean != null && seen.add(clean)) result.add(clean);
    // 合集/系列名标签（与 titleTag 同「自动添加书名到标签」开关）：视频=播放列表系列名、
    // 书籍=所属合集名。调用方读开关 + 取合集名 + 清洗后注入；与书名标签并列，字面量相同时
    // 由 [seen] 去重合并（如单视频合集名==剧集名时不重复追加）。
    final cleanCollection = sanitizeTitleTag(collectionTag);
    if (cleanCollection != null && seen.add(cleanCollection)) {
      result.add(cleanCollection);
    }
    // 制卡所在字符数标签（`chars_12345`）：排在最后，因为它是这批 tag 里唯一**每张卡
    // 都不同**的——放前面会把 Anki 标签列表里稳定的那几个挤到看不见的地方。同样过
    // [sanitizeTitleTag]：字面量本该由 [formatCharPositionTag] 产出（无空白），但互联
    // 转发端送来的值是外部输入，带空格会被 Anki 拆成两个垃圾 tag。
    final cleanCharPosition = sanitizeTitleTag(charPositionTag);
    if (cleanCharPosition != null && seen.add(cleanCharPosition)) {
      result.add(cleanCharPosition);
    }
    return result;
  }

  /// 把任意标题字符串清洗成**单个合法 Anki tag**：Anki tag 以空白分隔，故空格 / Tab
  /// 全替换成下划线（与卡片创建器 `TagsField` 的清洗规则一致，保证两条路径产出同一字面量，
  /// 从而被 [buildNoteTags] 的去重正确合并、不重复追加）。空/全空白返回 `null`。
  /// TODO-1007/1008：把一个卡片字段值（可能含 HTML）压成给用户看的**一行纯文本预览**：
  /// 去标签、折叠空白、截断到 [maxLen]。供 note viewer / 多张命中选择列表区分卡片用。
  /// 纯函数、可单测。
  static String previewFromFieldValue(String value, {int maxLen = 60}) {
    // 标签替换成**空格**（随后统一折叠），与 hibiki_audio 字幕解析的
    // `stripHtmlTags`（替换成空串）**故意不同**：Anki 字段 HTML 里 `<br>` /
    // 块级标签承担换行分词，直接删空会把相邻词粘连成一个词；字幕行内标签则
    // 紧贴正文、删空才不会在日文句中引入假空格。两份实现不强并（G11）。
    final String noTags = value.replaceAll(RegExp(r'<[^>]*>'), ' ');
    final String collapsed = noTags
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (collapsed.length <= maxLen) return collapsed;
    return '${collapsed.substring(0, maxLen)}…';
  }

  static String? sanitizeTitleTag(String? title) {
    if (title == null) return null;
    // 先 trim 再替换内部空白：纯空白标题 → 空 → null（不产出 `___` 之类垃圾标签）；
    // 标题内部空格/Tab → 下划线，整体当一个 Anki tag。
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.replaceAll(' ', '_').replaceAll('	', '_');
  }

  // ── 词典媒体（gaiji 外字）嵌入：两 backend 共用，杜绝两份实现漂移 ──────────────

  /// 把每条词典媒体（gaiji 外字等）存进 Anki，返回「占位符 → **裸媒体引用**」映射。
  ///
  /// - 键 = popup.js 注入到义项 HTML 里的占位符文件名（`fushi_dict_N.ext`，即
  ///   [DictionaryMedia.filename]）。
  /// - 值 = [storeBareRef] 返回的**裸文件名**（如 `real.svg`），**不是** `<img src>` 标签。
  ///
  /// 关键不变式：值必须是裸文件名。导出的义项 HTML 已经是
  /// `<img class="gloss-image" src="fushi_dict_N.ext">`，[buildMinedFields] 用
  /// `replaceAll` 把 `src` 里的占位符替换成真实文件名。若值是完整 `<img src="real.svg">`
  /// 标签，会被塞进 `src="..."` 里变成 `<img src="<img src="real.svg">">` 的嵌套坏图，
  /// Anki 卡片上外字不显示（AnkiConnect 旧实现的 BUG，AnkiDroid 经
  /// [ankiInlineMediaReference] 裸化故正常；本统一令两端同契约）。
  @protected
  Future<Map<String, String>> buildDictionaryMediaTags(
    List<DictionaryMedia> media,
    Future<String?> Function(DictionaryMedia media) storeBareRef,
  ) async {
    final tags = <String, String>{};
    for (final m in media) {
      final ref = await storeBareRef(m);
      if (ref != null && ref.isNotEmpty) {
        tags[m.filename] = ref;
      }
    }
    return tags;
  }

  /// 按 [fieldMappings] 渲染卡片字段：模板渲染 → 替换词典媒体占位符 → HTML 规范化。
  /// 两 backend 共用同一逻辑（原先在两个 repo 各有一份 byte 级重复实现）。
  ///
  /// BUG-858：[keepEmpty] 区分「新建」与「覆盖」语义。
  /// - 新建（默认 false）：渲染为空的字段直接跳过——新卡该字段本就空白，无意义。
  /// - 覆盖（true）：**保留所有映射字段**（含渲染为空的），使 `updateNoteFields`
  ///   按 id 真正整体替换。否则句子（`{sentence}` 取瞬时选区状态，覆盖那刻可能已空）
  ///   会被这里过滤掉、字段名不进 map，两后端 native 都「未给出的字段保留旧值」，
  ///   表现为「只覆盖图片和语音、原文句子不更新」。用户选定语义：覆盖=整体替换，
  ///   句子为空则随之清空（`updateMinedNote` 另有「全部字段皆空 → 拒绝清整卡」总守卫）。
  /// 选中的释义段已经作为 `<mark>` 进了释义字段时，`{popup-selection-text}` 要不要
  /// 让位（渲染成空）。
  ///
  /// 让位的**唯一理由**是 Lapis 的卡背轮播（`updateDefDisplay`）：非空 SelectionText
  /// 会把默认页占成一段脱离上下文的裸文本，用户反而要翻页才看得到带高亮的释义。
  /// 这个理由只对 Lapis 成立，而且只在高亮**确实进了卡**时成立，所以三条缺一不可：
  ///
  /// 1. 高亮真的落进了导出的释义树（[AnkiMiningPayload.glossarySelectionHighlighted]）；
  /// 2. 笔记类型是 Lapis——别的笔记类型没有那个轮播，凭什么替用户丢内容；
  /// 3. 用户确实把某个 glossary 类占位符映射到了某个字段——没映的话高亮根本没进卡，
  ///    这时候清空 SelectionText 就是让用户选中的内容**凭空消失**。
  ///
  /// 判据必须在这一层：popup.js 看得见 DOM 却看不见 `fieldMappings`，它只能上报
  /// 「高亮落地了没有」这件客观事实。
  @protected
  static bool shouldYieldSelectionText({
    required AnkiMiningPayload payload,
    required String? noteTypeName,
    required Map<String, String> fieldMappings,
  }) =>
      payload.glossarySelectionHighlighted &&
      noteTypeName == LapisNoteType.modelName &&
      fieldMappings.values.any((String t) => t.contains('glossary'));

  @protected
  Map<String, String> buildMinedFields({
    required Map<String, String> fieldMappings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required Map<String, String> dictionaryMediaTags,
    String? noteTypeName,
    bool keepEmpty = false,
  }) {
    final bool yieldSelectionText = shouldYieldSelectionText(
      payload: payload,
      noteTypeName: noteTypeName,
      fieldMappings: fieldMappings,
    );
    final fields = <String, String>{};
    for (final entry in fieldMappings.entries) {
      var value = AnkiHandlebarRenderer.render(
        entry.value,
        payload,
        context,
        yieldSelectionText: yieldSelectionText,
      );
      for (final mediaEntry in dictionaryMediaTags.entries) {
        value = value.replaceAll(mediaEntry.key, mediaEntry.value);
      }
      // 旧格式（仍带 gloss-* class）释义的外字中和兜底；新导出不命中门控，原样通过。
      value = normalizeAnkiDictionaryHtml(value);
      // 判空与写入用同一个 trim 口径。此前判空 trim、写入却是原值，于是一个字段里
      // 拼多个占位符时（出厂默认 MiscInfo = `{document-title} {clip-timestamp}`），
      // 某个占位符渲染成空串就会把模板里的字面分隔符留成首尾空白写进 Anki 字段。
      // 首尾空白对 Anki 字段没有任何语义（HTML 渲染同样忽略），trim 掉即可；
      // keepEmpty 路径上空值 trim 后仍是空串，照常写入，覆盖语义不变。
      final String trimmed = value.trim();
      if (keepEmpty || trimmed.isNotEmpty) {
        fields[entry.key] = trimmed;
      }
    }
    return fields;
  }

  /// BUG-2606：覆盖 = 这张卡变成「此刻新制会得到的那张」——note 现有的每个字段都要
  /// 被写：映射到的写渲染值，**没映射到的写空串**。
  ///
  /// 此前只发映射字段，两后端 native 都「未给出的字段保留旧值」。用户报告的形态是
  /// Lapis：`SentenceFurigana` 由别的工具填过，Fushi 不映射它，覆盖后 `Sentence`
  /// 换新、`SentenceFurigana` 留旧，而模板 `{{#SentenceFurigana}}` 优先显示它——
  /// 卡面照旧是老句子，直到用户手动清空。同理 `Hint` 等任何模板会读的字段。
  /// 新制的卡这些字段本来就是空的，覆盖不该比新制多留一截旧内容。
  ///
  /// 只补 [existingFieldNames] 里有、[rendered] 里没有的名字；[rendered] 里 note
  /// 没有的名字原样保留（服务端按名匹配自会丢弃，与 BUG-1900 同口径）。AnkiDroid
  /// 后端在 native `updateNoteFields` 里按位置做同一件事（`clearUnspecified`），
  /// 那边本来就握着整条 note，不必再经通道回读一次。
  @protected
  static Map<String, String> fieldsForOverwrite({
    required Iterable<String> existingFieldNames,
    required Map<String, String> rendered,
  }) {
    final Map<String, String> out = <String, String>{...rendered};
    for (final String name in existingFieldNames) {
      out.putIfAbsent(name, () => '');
    }
    return out;
  }

  /// BUG-1900：只保留**属于 [noteType] 的字段**。
  ///
  /// AnkiConnect 按字段**名**匹配，不认识的名字被服务端静默丢弃。而
  /// [fieldMappingsAfterFetch] 对非 Lapis 笔记类型直接 `return current.fieldMappings`
  /// ——换了笔记类型，映射里的字段名可能一个都不属于新类型。此前这些名字原样送出，
  /// Anki 收到一张全空的卡，`fields_check()` 判首字段空后返回
  /// `cannot create note because it is empty`，用户既看不出是选错了笔记类型，也不知道
  /// 去哪儿改（用户 2026-08-28 报告）。
  ///
  /// AnkiDroid 后端按 `noteType.fields` 的**位置**取值，天然免疫；这里把同一条纪律
  /// 补给 AnkiConnect。
  ///
  /// [noteType] 的字段清单为空时**原样返回**：那说明我们手上没有可信的字段真相
  /// （设置陈旧 / 从未 fetch 过），此时猜不如不猜，交由服务端裁决。
  @protected
  Map<String, String> fieldsForNoteType(
    AnkiNoteType noteType,
    Map<String, String> rendered,
  ) {
    if (noteType.fields.isEmpty) return rendered;
    final Set<String> known = noteType.fields.toSet();
    return <String, String>{
      for (final MapEntry<String, String> e in rendered.entries)
        if (known.contains(e.key)) e.key: e.value,
    };
  }

  /// BUG-1900：本地预检，把服务端那句不可操作的英文原文换成能照着做的分类错误。
  ///
  /// Anki 的 `fields_check()` **只看第一个字段**：空就拒收整张卡。返回非 null 即表示
  /// 这张卡送出去必然失败，调用方应回滚媒体事务并把它当作失败结果返回。
  ///
  /// [rendered] 是渲染出的原始字段（映射键），[outgoing] 是 [fieldsForNoteType] 过滤后
  /// 真正会送出的字段——两者的差别正是「配置的字段名不属于当前笔记类型」这一情形，
  /// 需要与「字段确实没渲染出内容」区分开，否则用户拿到的建议是错的。
  @protected
  MineOutcome? preflightNoteFields(
    AnkiNoteType noteType,
    Map<String, String> rendered,
    Map<String, String> outgoing,
  ) {
    if (noteType.fields.isEmpty) return null;
    final String firstField = noteType.fields.first;
    if ((outgoing[firstField] ?? '').trim().isNotEmpty) return null;

    if (outgoing.isEmpty && rendered.isNotEmpty) {
      return MineOutcome.failure(
        'None of the configured field names exist on note type '
        '"${noteType.name}" (configured: ${rendered.keys.join(", ")}; '
        'available: ${noteType.fields.join(", ")}). Re-map the fields in Anki '
        'settings, or use "Create Lapis deck".',
        errorCode: AnkiErrorCode.fieldMappingMismatch,
      );
    }
    return MineOutcome.failure(
      'The first field "$firstField" of note type "${noteType.name}" is empty; '
      'Anki refuses such a note. Map a field to it in Anki settings.',
      errorCode: AnkiErrorCode.firstFieldEmpty,
    );
  }

  /// 从 [inlineVideoCoverHtml] 渲染出的封面引用里取回媒体库文件名（`src` 反转义）；
  /// 不是内嵌片段引用时 null。
  static String? _inlineVideoMediaName(String? coverRef) {
    if (coverRef == null) return null;
    final RegExpMatch? m = RegExp(
      r'^<video class="fushi-inline-video" src="([^"]*)"',
    ).firstMatch(coverRef);
    if (m == null) return null;
    return m
        .group(1)!
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#47;', '/')
        .replaceAll('&amp;', '&');
  }

  /// 用已备好的媒体引用把 [payload] + [context] 组装成最终渲染结果。
  ///
  /// 两 backend 的差异只在「媒体引用怎么准备」（AnkiConnect 远程上传后内联
  /// `<img>` / `[sound:]`；AnkiDroid 平台通道写入返回已格式化引用）；引用备好
  /// 之后的 payload 字段透传 + [buildMinedFields] 渲染 + 打包完全一致，收敛在
  /// 这里，杜绝两份 16 字段透传漂移。
  ///
  /// [coverRef] / [sasayakiRef] / [processedAudio] 均须是**已格式化**的最终
  /// 引用（`<img src>` / `[sound:]`；无则 null / 空串）。
  @protected
  RenderedMinedFields renderMediaPayload({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required String? coverRef,
    required String? sentenceAudioRef,
    required String processedAudio,
    required Map<String, String> dictionaryMediaTags,
    String? audioWarning,
    bool keepEmpty = false,
  }) {
    // A muxed video owns sentence playback. Keep only one native sound tag:
    // Lapis renders Picture three times, but SentenceAudio is interpolated once
    // after ExpressionAudio and its already-rendered replay buttons are copied.
    //
    // 内嵌片段（WebM）反过来：画面本身就在 Picture 的 `<video>` 里播，句子音频字段只放
    // 重播按钮 + 隐藏 <audio>（[inlineVideoSentenceAudioHtml]），不再有任何 `[sound:]`——否则 Anki 原生
    // 队列会把同一段声音再放一遍。
    final bool managedVideo = settings.fieldMappings.values.any(
      (String value) => value.contains('{card-video}'),
    );
    if (context.synchronizedVideo && managedVideo) {
      final String? audioField = AnkiHandlebarOptions.singleSentenceAudioField(
        settings.fieldMappings,
      );
      if (audioField == null ||
          settings.fieldMappings[audioField]!.contains('{card-video}')) {
        throw StateError(
          'Video adaptation requires exactly one sentence-audio token in one separate field. Check the Anki field mappings.',
        );
      }
    }
    final String? inlineVideoName = _inlineVideoMediaName(coverRef);
    if (context.synchronizedVideo &&
        inlineVideoName != null &&
        isAnkiInlineVideoCover(context.coverPath)) {
      if (managedVideo) {
        coverRef =
            '<video class="fushi-video-source" '
            'src="${const HtmlEscape().convert(inlineVideoName)}" '
            'hidden preload="none" playsinline></video>';
        sentenceAudioRef = null;
      } else {
        sentenceAudioRef =
            AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(
              settings.fieldMappings,
            )
            ? inlineVideoSentenceAudioHtml(inlineVideoName)
            : null;
      }
    } else if (context.synchronizedVideo && coverRef != null) {
      if (AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(
        settings.fieldMappings,
      )) {
        sentenceAudioRef =
            '<span class="fushi-synced-sentence-media">$coverRef</span>';
        coverRef = managedVideo
            ? '<span data-fushi-native-video="1"></span>'
            : synchronizedVideoReplayHtml;
      } else {
        // Custom templates without sentence audio retain a playable Picture.
        sentenceAudioRef = null;
      }
    }
    final AnkiMiningContext mediaContext = context.withMediaRefs(
      coverRef: coverRef,
      sentenceAudioRef: sentenceAudioRef,
    );

    // issue #1432：「紧凑释义」开关只在这里落地——payload 进 handlebar 渲染前给
    // 释义 HTML 注入紧凑样式；关闭时三份释义原样透传，输出逐字节不变。
    final bool compactGlossaries = settings.compactGlossaries;
    final mediaPayload = AnkiMiningPayload(
      expression: payload.expression,
      reading: payload.reading,
      matched: payload.matched,
      furiganaPlain: payload.furiganaPlain,
      frequenciesHtml: payload.frequenciesHtml,
      freqHarmonicRank: payload.freqHarmonicRank,
      glossary: compactAnkiGlossaryHtml(
        payload.glossary,
        enabled: compactGlossaries,
      ),
      glossaryFirst: compactAnkiGlossaryHtml(
        payload.glossaryFirst,
        enabled: compactGlossaries,
      ),
      singleGlossaries: compactAnkiGlossaryMap(
        payload.singleGlossaries,
        enabled: compactGlossaries,
      ),
      pitchPositions: payload.pitchPositions,
      pitchCategories: payload.pitchCategories,
      phoneticTranscriptions: payload.phoneticTranscriptions,
      popupSelectionText: payload.popupSelectionText,
      glossarySelectionHighlighted: payload.glossarySelectionHighlighted,
      audio: processedAudio,
      selectedDictionary: payload.selectedDictionary,
      dictionaryMedia: payload.dictionaryMedia,
    );

    return RenderedMinedFields(
      buildMinedFields(
        fieldMappings: settings.fieldMappings,
        payload: mediaPayload,
        context: mediaContext,
        dictionaryMediaTags: dictionaryMediaTags,
        noteTypeName: settings.selectedNoteTypeName,
        keepEmpty: keepEmpty,
      ),
      audioWarning: audioWarning,
    );
  }

  // ── 远程单词音频失败原因（TODO-779）：两 backend 共用，杜绝两份文案漂移 ──────────

  /// 把单词远程音频的**非 200 HTTP 响应**格式化成给用户看的简短失败原因
  /// （含状态码与 URL）。两 backend 的远程音频路径在拒绝把错误响应体当 .mp3
  /// 写入（HBK-AUDIT-019）的同时调用本方法，把原因经 [AudioFetchOutcome.failed]
  /// 冒泡到 [MineOutcome.audioWarning]，让用户看到「为什么没音频」。纯函数、可单测。
  @protected
  String audioFetchHttpFailureReason(int statusCode, String url) =>
      'HTTP $statusCode for $url';

  /// 把单词远程音频抓取期间抛出的**异常**（DNS/连接失败/超时等）格式化成给用户看的
  /// 简短失败原因（含异常摘要与 URL）。与 [audioFetchHttpFailureReason] 同语义，覆盖
  /// 非 HTTP-码类的可见失败。纯函数、可单测。
  @protected
  String audioFetchErrorReason(Object error, String url) => '$error for $url';
}
