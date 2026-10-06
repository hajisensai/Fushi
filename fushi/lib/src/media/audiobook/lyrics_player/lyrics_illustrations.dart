import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FileImage, ImageProvider;
import 'package:fushi_engine/epub/epub_book.dart'
    show EpubImageRef, kEpubCoverChapterIndex;
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/illustration_aspect_probe.dart';

// 歌词模式里的书中插图（2026-10-07 用户需求）。
//
// 横屏：播放进度走到书里一张插图的位置时，左栏封面以动画换成这张插图并停住，
// 等用户处理——关掉回封面，或在已听到的插图之间前后切换，点中间看大图。
// 竖屏：底部控制条里显示封面的小方块换成插图缩略图，点它进插图大图浏览。
//
// 本文件只放纯逻辑：哪些图算插图（[classifyLyricsIllustration]）、播放位置落在
// 哪张插图之后（[lastReachedLyricsIllustration]）、以及换图 / 回封面 / 前后切换的
// 状态机（[LyricsIllustrationController]）。画法在 lyrics_illustration_view.dart。
//
// 「播放到插图」用的是阅读器现成的那把尺：cue 的 `fushi-cue://` 片段 →
// `ReaderAudioPositionIndex.studyRangeForFragment` 给出章内学习单位偏移；插图的
// 位置是 `EpubImageRef.charOffset`（同一章、同样跳过 ruby 注音的学习单位计数）。
// 两者在同一坐标系里比较，不另造判据。

// ---------------------------------------------------------------------------
// 小图屏蔽：判据与阈值（集中在这一处）
// ---------------------------------------------------------------------------

/// 短边低于此像素数的不算插图：分隔线、花饰条、章节号小图。正经插图（扫描
/// 彩页 / 黑白插画）短边几乎都在 500px 以上，老书低清插图也有 400 左右；240 给
/// 低清书留了足够余量。
const int kLyricsIllustrationMinShortSide = 240;

/// 面积低于此值（400×400）的不算插图：方形的章首装饰、小图标即使边长过了
/// [kLyricsIllustrationMinShortSide] 也只有几百像素见方，放到左栏整块封面位上
/// 只会是一团模糊。
const int kLyricsIllustrationMinArea = 400 * 400;

/// 长短边比超过此值的不算插图：横幅式的标题条、花边、分隔线。跨页大图约 1.4，
/// 竖长插图约 0.7，正常插图离 3 很远。
const double kLyricsIllustrationMaxAspect = 3.0;

/// 排在文字行内（见 `EpubImageRef.sharesLineWithText`）的图，长边不到此值就当
/// 文字处理：外字（把字做成图片嵌进句子，OCR 也会把它当字认）、标题里的小图标。
/// 是阅读器块级插图门槛（[kInlineImageMaxSide] = 256）的两倍：行内图被高清导出
/// 时常有 300~500px 的外字，而真正放在段落里的插图（图下同段写图注）都远大于此。
const int kLyricsInlineIllustrationMinLongSide = kInlineImageMaxSide * 2;

/// 一张图为什么（不）能当插图。除 [illustration] 外都是被屏蔽的原因。
enum LyricsIllustrationVerdict {
  /// 是插图。
  illustration,

  /// 是封面（或与封面同一张图的另一份文件）——左栏本来就显示封面。
  cover,

  /// 宽高都不超过阅读器块级插图门槛（[kInlineImageMaxSide]）：阅读器正文本来就
  /// 把它排进文字流当字用（外字 / 章节号 / 装饰符号）。
  inlineSized,

  /// 短边 / 面积太小（分隔线、小装饰图）。
  tooSmall,

  /// 长短边比过大（标题条、花边）。
  banner,

  /// 排在文字行内且不够大（外字、标题小图标）。
  inlineGlyph,
}

/// 判一张书中图片能否当歌词模式插图。
///
/// * [size]：图片真实像素尺寸（读文件头得到）；null = 读不出来（SVG 等），此时
///   只看排版：独占一块的当插图，排在文字行内的当字。
/// * [sharesLineWithText]：图片在排版里是否与文字同处一个块（行内嵌字）。
/// * [isCover]：是 OPF 封面，或与封面是同一张图。
LyricsIllustrationVerdict classifyLyricsIllustration({
  required ImagePixelSize? size,
  required bool sharesLineWithText,
  bool isCover = false,
}) {
  if (isCover) return LyricsIllustrationVerdict.cover;
  if (size == null) {
    return sharesLineWithText
        ? LyricsIllustrationVerdict.inlineGlyph
        : LyricsIllustrationVerdict.illustration;
  }
  if (isInlineSizedImage(size)) return LyricsIllustrationVerdict.inlineSized;
  final int shortSide = math.min(size.width, size.height);
  final int longSide = math.max(size.width, size.height);
  if (shortSide < kLyricsIllustrationMinShortSide ||
      size.width * size.height < kLyricsIllustrationMinArea) {
    return LyricsIllustrationVerdict.tooSmall;
  }
  if (longSide / shortSide > kLyricsIllustrationMaxAspect) {
    return LyricsIllustrationVerdict.banner;
  }
  if (sharesLineWithText && longSide < kLyricsInlineIllustrationMinLongSide) {
    return LyricsIllustrationVerdict.inlineGlyph;
  }
  return LyricsIllustrationVerdict.illustration;
}

/// 文件头探测结果：像素尺寸 + 字节数（字节数只用来认出「与封面同一张图的另一份
/// 文件」——封面页 xhtml 里常再引用一份同图不同名的封面）。
typedef LyricsIllustrationFileProbe = ({int width, int height, int bytes});

/// `compute()` 入口：批量读图片文件头拿像素尺寸与文件大小。读不出尺寸的文件
/// 不进结果（调用方按「尺寸未知」处理）。
Map<String, LyricsIllustrationFileProbe> probeLyricsIllustrationFiles(
  List<String> paths,
) {
  final Map<String, ImagePixelSize> sizes = probeIllustrationSizes(paths);
  final Map<String, LyricsIllustrationFileProbe> result =
      <String, LyricsIllustrationFileProbe>{};
  sizes.forEach((String path, ImagePixelSize size) {
    int bytes = -1;
    try {
      bytes = File(path).lengthSync();
    } on FileSystemException {
      bytes = -1;
    }
    result[path] = (width: size.width, height: size.height, bytes: bytes);
  });
  return result;
}

/// [probe] 是否与封面 [cover] 是同一张图（像素尺寸与字节数都相同）。
bool isSameImageAsCover(
  LyricsIllustrationFileProbe? probe,
  LyricsIllustrationFileProbe? cover,
) {
  if (probe == null || cover == null) return false;
  if (probe.bytes < 0 || cover.bytes < 0) return false;
  return probe.width == cover.width &&
      probe.height == cover.height &&
      probe.bytes == cover.bytes;
}

/// 一本书的插图筛选结果：[items] 是通过的插图（书中顺序），[verdicts] 是每张
/// 正文图片（按 `revealKey`）的判定，供诊断 / 测试看哪些图被屏蔽、为什么。
typedef LyricsIllustrationSelection = ({
  List<LyricsIllustration> items,
  Map<String, LyricsIllustrationVerdict> verdicts,
});

/// 从 `EpubBook.images` 选出歌词模式插图。
///
/// * [pathByKey]：`revealKey` → 磁盘文件路径（解析不到文件的图不进结果）；
/// * [probes]：[probeLyricsIllustrationFiles] 的结果（路径 → 尺寸 / 字节数）；
/// * [coverPath]：歌词页正在显示的封面文件（OPF cover-image 解析出的那份）。
///
/// 封面判据：OPF 封面条目本身、路径与 [coverPath] 相同、或与封面像素尺寸和
/// 字节数都相同（封面页 xhtml 另存的一份同图）。
LyricsIllustrationSelection selectLyricsIllustrations({
  required List<EpubImageRef> refs,
  required Map<String, String> pathByKey,
  required Map<String, LyricsIllustrationFileProbe> probes,
  String? coverPath,
}) {
  String? coverKey;
  for (final EpubImageRef ref in refs) {
    if (ref.chapterIndex == kEpubCoverChapterIndex) coverKey = ref.revealKey;
  }
  final String? coverFile = coverKey == null
      ? coverPath
      : (pathByKey[coverKey] ?? coverPath);
  final LyricsIllustrationFileProbe? coverProbe = coverFile == null
      ? null
      : probes[coverFile];
  final List<LyricsIllustration> items = <LyricsIllustration>[];
  final Map<String, LyricsIllustrationVerdict> verdicts =
      <String, LyricsIllustrationVerdict>{};
  for (final EpubImageRef ref in refs) {
    if (ref.chapterIndex < 0) continue;
    final String? path = pathByKey[ref.revealKey];
    if (path == null) continue;
    final LyricsIllustrationFileProbe? probe = probes[path];
    final bool isCover =
        ref.revealKey == coverKey ||
        (coverFile != null &&
            p.equals(p.normalize(path), p.normalize(coverFile))) ||
        isSameImageAsCover(probe, coverProbe);
    final LyricsIllustrationVerdict verdict = classifyLyricsIllustration(
      size: probe == null ? null : (width: probe.width, height: probe.height),
      sharesLineWithText: ref.sharesLineWithText,
      isCover: isCover,
    );
    verdicts[ref.revealKey] = verdict;
    if (verdict != LyricsIllustrationVerdict.illustration) continue;
    final File file = File(path);
    items.add(
      LyricsIllustration(
        key: ref.revealKey,
        position: LyricsBookPosition(ref.chapterIndex, ref.charOffset),
        image: FileImage(file),
        file: file,
      ),
    );
  }
  return (items: items, verdicts: verdicts);
}

// ---------------------------------------------------------------------------
// 位置
// ---------------------------------------------------------------------------

/// 书中位置：spine 章号 + 章内学习单位偏移（与 `EpubImageRef.charOffset`、
/// `ReaderAudioPositionIndex.studyRangeForFragment` 同一把尺）。
@immutable
class LyricsBookPosition implements Comparable<LyricsBookPosition> {
  const LyricsBookPosition(this.chapter, this.offset);

  final int chapter;
  final int offset;

  @override
  int compareTo(LyricsBookPosition other) {
    if (chapter != other.chapter) return chapter.compareTo(other.chapter);
    return offset.compareTo(other.offset);
  }

  bool operator <=(LyricsBookPosition other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is LyricsBookPosition &&
      other.chapter == chapter &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(chapter, offset);

  @override
  String toString() => 'LyricsBookPosition($chapter, $offset)';
}

/// 一张通过了 [classifyLyricsIllustration] 的插图。
@immutable
class LyricsIllustration {
  const LyricsIllustration({
    required this.key,
    required this.position,
    required this.image,
    this.file,
  });

  /// 稳定身份（`EpubImageRef.revealKey`）。
  final String key;

  /// 插图在书中的位置：播放位置到达（≥）这里就算「听到了这张图」。
  final LyricsBookPosition position;

  /// 画图用的图源（生产是 [FileImage]）。
  final ImageProvider image;

  /// 磁盘文件（看大图 / 分享用）；测试里可为 null。
  final File? file;
}

/// [items]（按书中顺序）里最后一张位置不晚于 [position] 的插图下标；一张都没
/// 到为 -1。
int lastReachedLyricsIllustration(
  List<LyricsIllustration> items,
  LyricsBookPosition position,
) {
  int lo = 0;
  int hi = items.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (items[mid].position <= position) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

/// 两次观测之间音频前进不超过这么久，才算「顺着播过去」：拖进度条 / 跳章
/// 一下跨过好几张插图不该一张张弹出来，只静默更新「已听到」的范围。
const Duration kLyricsIllustrationNaturalAdvance = Duration(seconds: 90);

/// 歌词模式插图状态。
///
/// * [reached]：已听到的最后一张插图下标（-1 = 一张都没听到）。可浏览的范围
///   是 `0..reached`——还没听到的插图不给看（不剧透，与阅读器「未读到的插图
///   打码」同一取向）。
/// * [shown]：插图位（横屏左栏 / 竖屏小方块）当前显示的插图；null = 显示封面。
///
/// 播放顺着走过一张插图的位置时自动换上它并停住；用户 [dismiss] 才回封面。
class LyricsIllustrationController extends ChangeNotifier {
  List<LyricsIllustration> _items = const <LyricsIllustration>[];
  int _reached = -1;
  int? _shown;
  int? _lastAudioMs;

  /// 插图表（按书中顺序）。
  List<LyricsIllustration> get items => _items;

  int get reached => _reached;

  int? get shown => _shown;

  /// 插图位上正在显示的插图；null = 封面。
  LyricsIllustration? get shownIllustration {
    final int? index = _shown;
    return index == null ? null : _items[index];
  }

  /// 是否有可浏览的插图（至少听到了一张）。
  bool get hasReached => _reached >= 0;

  bool get canShowPrevious => (_shown ?? 0) > 0;

  bool get canShowNext {
    final int? index = _shown;
    return index != null && index < _reached;
  }

  /// 装入插图表，并把 [position] 之前的插图记为已听到（**不**弹出——进歌词
  /// 模式时已经过去的插图不该一进来就盖住封面）。
  void load(
    List<LyricsIllustration> items, {
    LyricsBookPosition? position,
    Duration? audioPosition,
  }) {
    _items = List<LyricsIllustration>.unmodifiable(items);
    _reached = position == null
        ? -1
        : lastReachedLyricsIllustration(_items, position);
    _shown = null;
    _lastAudioMs = audioPosition?.inMilliseconds;
    notifyListeners();
  }

  /// 播放位置推进（cue 变化 / seek 时调用）。
  ///
  /// 顺着播（音频前进且不超过 [kLyricsIllustrationNaturalAdvance]）新走过插图时，
  /// 插图位换成新走过的**第一张**（连续几张彩页一起走过时从第一张看起，后面的
  /// 用「下一张」翻）。跳跃式的 seek 只更新已听到范围；往回 seek 把超出范围的
  /// 插图收回封面。
  void observe(LyricsBookPosition position, {required Duration audioPosition}) {
    final int audioMs = audioPosition.inMilliseconds;
    final int? lastMs = _lastAudioMs;
    _lastAudioMs = audioMs;
    if (_items.isEmpty) return;
    final int next = lastReachedLyricsIllustration(_items, position);
    if (next == _reached) return;
    final bool natural =
        lastMs != null &&
        audioMs >= lastMs &&
        audioMs - lastMs <= kLyricsIllustrationNaturalAdvance.inMilliseconds;
    final int previous = _reached;
    _reached = next;
    if (next > previous) {
      if (natural) _shown = previous + 1;
    } else {
      final int? shown = _shown;
      if (shown != null && shown > next) _shown = null;
    }
    notifyListeners();
  }

  /// 回到封面。
  void dismiss() {
    if (_shown == null) return;
    _shown = null;
    notifyListeners();
  }

  /// 插图位显示第 [index] 张（夹到已听到范围内；一张都没听到则不动）。
  void showAt(int index) {
    if (_reached < 0) return;
    final int target = index.clamp(0, _reached);
    if (target == _shown) return;
    _shown = target;
    notifyListeners();
  }

  /// 从封面打开插图时从哪张看起：正在显示的那张，否则最近听到的那张；没有为
  /// null。
  int? get browseStart => _shown ?? (_reached >= 0 ? _reached : null);

  void showPrevious() {
    final int? index = _shown;
    if (index == null || index <= 0) return;
    showAt(index - 1);
  }

  void showNext() {
    final int? index = _shown;
    if (index == null || index >= _reached) return;
    showAt(index + 1);
  }
}
