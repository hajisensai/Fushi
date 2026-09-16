import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';

/// 一张插图在书里的阅读位置：spine 章号 + 章内归一偏移。
///
/// 坐标系与 `ReaderPosition`（`sectionIndex` / `normCharOffset`，0~10000 分数基准）
/// **完全一致**，两者可直接比较——图片库据此判「这张图读到了没有」。
class IllustrationPosition {
  const IllustrationPosition({
    required this.chapterIndex,
    required this.normCharOffset,
  });

  /// spine 章号（0-based）。`-1` = 封面（OPF `cover-image`），恒排在正文之前，
  /// 因此永远算「已读到」——封面不是剧透。
  final int chapterIndex;

  /// 章内归一偏移（0~10000）：图片之前的实义字符数 ÷ 全章实义字符数。
  final int normCharOffset;

  /// 本图是否落在阅读位置（[chapterIndex] / [normCharOffset]）**之后** = 还没读到。
  bool isAfter({required int chapterIndex, required int normCharOffset}) {
    if (this.chapterIndex != chapterIndex) {
      return this.chapterIndex > chapterIndex;
    }
    return this.normCharOffset > normCharOffset;
  }
}

/// 插图 → 阅读位置的索引：图片库「未读到的插图先遮罩」的判据来源。
///
/// 键是 `EpubImageRef.revealKey` 的稳定 key（extractDir 相对、decode、正斜杠），
/// 与阅读器 WebView / Drift `revealed_images` / 图片库磁盘 `File` 三端同一套标识，
/// 所以「已揭开」与「读到没读到」两个判据能落在同一张图上。
///
/// 定位范围由 [EpubBook.images] 决定（`<img src>`、SVG `<image xlink:href|href>`、
/// **行内** `style="background-image:url(...)"`，外加 OPF 封面）。`<style>` 块 /
/// 外部 CSS 里的背景图没有 DOM 位置，不进清单也不进索引 → [isUnread] 返回 false
/// → 不遮罩：宁可漏遮，也不凭猜测把已读的图糊住。
class IllustrationProgressIndex {
  const IllustrationProgressIndex(this.positions);

  /// 空索引（解析失败 / 无 EPUB 结构时的退化值：一律不按进度遮罩）。
  static const IllustrationProgressIndex empty = IllustrationProgressIndex(
    <String, IllustrationPosition>{},
  );

  /// reveal key → 该图在书中**首次出现**的位置（同一张图被多章引用时取最早那次，
  /// 早于阅读位置就算读到了）。
  final Map<String, IllustrationPosition> positions;

  /// [revealKey] 这张图是否还没读到（= 落在阅读位置之后）。
  ///
  /// key 为空、或索引里定位不到（正文没引用 / 只在外部 CSS 里出现）一律 false。
  bool isUnread({
    required String? revealKey,
    required int chapterIndex,
    required int normCharOffset,
  }) {
    if (revealKey == null) return false;
    final IllustrationPosition? position = positions[revealKey];
    if (position == null) return false;
    return position.isAfter(
      chapterIndex: chapterIndex,
      normCharOffset: normCharOffset,
    );
  }

  /// 按 spine 顺序扫全书建索引。纯函数（只读 [book]），可直接在 isolate 内跑。
  ///
  /// 扫描本身在 [EpubBook.images] 里：插图册（阅读器）与图片库（书架）共用那一份
  /// 清单，本类只把它转成「reveal key → 位置」的查表形态。两边各扫一遍曾是
  /// BUG-2559 的根因——同一张图在两个表面被判出不同的「读到没读到」，用户看到的
  /// 就是「同一本书，两处糊的图不一样」。
  static IllustrationProgressIndex build(EpubBook book) {
    return IllustrationProgressIndex(
      Map<String, IllustrationPosition>.unmodifiable(
        <String, IllustrationPosition>{
          for (final EpubImageRef ref in book.images)
            ref.revealKey: IllustrationPosition(
              chapterIndex: ref.chapterIndex,
              normCharOffset: ref.normCharOffset,
            ),
        },
      ),
    );
  }
}

/// `compute()` 入口：后台 isolate 里解析已解压目录并建索引。
///
/// 图片库开页时整本 html 解析（几十~几百章）不能压在 UI 线程上——与开书路径的
/// [parseBookOnly] 同款处理。目录不是合法 EPUB（`parseFromExtracted` 抛
/// [FormatException]）由调用方按「无索引」降级。
IllustrationProgressIndex buildIllustrationProgressIndex(String extractDir) {
  return IllustrationProgressIndex.build(
    EpubParser.parseFromExtracted(extractDir),
  );
}
