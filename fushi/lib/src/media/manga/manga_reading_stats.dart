import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 漫画阅读的**字数**记账（统计口径接入）。
///
/// 背景：漫画此前只往 `reading_statistics` 落时长，`charsRead` 恒 0——理由是
/// 「页数绝不能塞进 charsRead」。那个理由仍然成立，但漫画并非没有文本：mokuro /
/// 内置 OCR 每页都给出 [MokuroBlock.lines]，那才是用户真正读到的字。用它计数，
/// 漫画就能和 EPUB / 视频字幕 / 游戏文本一样进同一个字数口径（首页每日目标、
/// 热力图、阅读统计页），而不是永远显示 0 字。
///
/// 口径与 EPUB 完全一致：走 [japaneseCharCount]（只数假名/汉字/字母数字，剔除
/// 标点、括号、空白），所以两种书的「字数」「阅读速度」可直接相加、直接比较。
///
/// 去重语义：以**页**为记账单位，一页在同一次阅读会话里只计一次（[counted]
/// 集合），来回翻页刷不出字数或页数。跳读没停留过的页不计——宁可少算，不虚高。

/// 单页 OCR 文本的实义字符数。无 OCR（纯图页 / 尚未识别）自然为 0。
int mangaPageCharCount(MokuroImage page) {
  final StringBuffer buffer = StringBuffer();
  for (final MokuroBlock block in page.blocks) {
    for (final String line in block.lines) {
      buffer.write(line);
    }
  }
  return japaneseCharCount(buffer.toString());
}

/// 把 [pageIndices] 中**尚未记账**的页计入 [counted]，返回本次新增的字符数与页数。
///
/// 字数与页数是两个独立量纲，一起返回、分别落库（`charsRead` / `pagesRead`）：漫画
/// 「今天读了 3200 字 / 48 页」两个都要真，页数绝不塞进字数。越界页码直接忽略
/// （布局重建 / payload 换书的竞态下可能短暂出现）。调用方在每次页码推进时调用，
/// flush 时把累计值随时长一起落库。
({int chars, int pages}) mangaAccumulateReadingStats({
  required MokuroPayload payload,
  required Iterable<int> pageIndices,
  required Set<int> counted,
}) {
  int chars = 0;
  int pages = 0;
  for (final int index in pageIndices) {
    if (index < 0 || index >= payload.images.length) continue;
    if (!counted.add(index)) continue;
    chars += mangaPageCharCount(payload.images[index]);
    pages++;
  }
  return (chars: chars, pages: pages);
}
