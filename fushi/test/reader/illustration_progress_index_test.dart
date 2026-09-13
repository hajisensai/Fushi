import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/illustration_progress_index.dart';

/// 图片库「还没读到的插图先遮罩」的判据来源：插图 → 书中位置索引。
///
/// 这里按真实解压目录（container.xml + OPF + 章节 XHTML + 真图片文件）建索引，
/// 走的是生产同一条 `EpubParser.parseFromExtracted` → 逐章 DOM 扫描路径，断言：
/// ① `<img>` / SVG `<image>` / 行内 background-image 三种插图写法都定位得到；
/// ② 位置坐标（章号 + 章内归一偏移）与 `ReaderPosition` 同尺，章内先后可比；
/// ③ 封面恒排在正文之前（永远算已读到，不该被当剧透遮住）；
/// ④ percent 转义的 src 与磁盘真实文件名归一到同一个 reveal key；
/// ⑤ 正文没引用的孤儿图定位不到 → 不遮罩（宁可漏遮，不凭猜测糊住已读的图）。
void main() {
  late Directory extractDir;

  String rel(String path) => '${extractDir.path}/$path';

  void write(String path, String content) {
    final File file = File(rel(path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('hibiki_illust_index');

    write('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');

    write('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test Book</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
  </spine>
</package>
''');

    // 第 1 章：章首一张 <img>，章中（约一半字数处）再一张。振假名 <rt> 不计字数，
    // 否则「章中那张」的归一偏移会被读音撑偏。
    write('OEBPS/text/ch1.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p><img src="../images/head.png" alt=""/></p>
  <p>あいうえおかきくけこ<ruby>漢字<rt>かんじ</rt></ruby></p>
  <p><img src="../images/middle.png" alt=""/></p>
  <p>さしすせそたちつてとなにぬねの</p>
</body></html>
''');

    // 第 2 章：日文固定版式插图页的常见写法——SVG 包一张 JPEG，全章无 <img>。
    write('OEBPS/text/ch2.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
       viewBox="0 0 800 1200"><image width="800" height="1200" xlink:href="../images/plate.jpg"/></svg>
</body></html>
''');

    // 第 3 章：percent 转义的 src + 行内 background-image。
    write('OEBPS/text/ch3.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p><img src="../images/foo%20bar.png" alt=""/></p>
  <div style="background-image: url('../images/back.png');">x</div>
</body></html>
''');

    for (final String name in <String>[
      'cover.png',
      'head.png',
      'middle.png',
      'plate.jpg',
      'foo bar.png',
      'back.png',
      'orphan.png',
    ]) {
      write('OEBPS/images/$name', 'not-a-real-image');
    }
  });

  tearDown(() {
    try {
      extractDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录由 OS 回收。
    }
  });

  IllustrationProgressIndex build() =>
      buildIllustrationProgressIndex(extractDir.path);

  test('locates img / svg image / inline background-image across the spine',
      () {
    final IllustrationProgressIndex index = build();

    expect(index.positions['OEBPS/images/head.png']?.chapterIndex, 0);
    expect(index.positions['OEBPS/images/middle.png']?.chapterIndex, 0);
    expect(index.positions['OEBPS/images/plate.jpg']?.chapterIndex, 1);
    expect(index.positions['OEBPS/images/foo bar.png']?.chapterIndex, 2);
    expect(index.positions['OEBPS/images/back.png']?.chapterIndex, 2);
    // 正文没引用的图定位不到。
    expect(index.positions.containsKey('OEBPS/images/orphan.png'), isFalse);
  });

  test('orders images inside a chapter by the study chars before them', () {
    final IllustrationProgressIndex index = build();

    final IllustrationPosition head = index.positions['OEBPS/images/head.png']!;
    final IllustrationPosition middle =
        index.positions['OEBPS/images/middle.png']!;
    expect(head.normCharOffset, 0);
    expect(middle.normCharOffset, greaterThan(0));
    expect(middle.normCharOffset, lessThan(10000));

    // 读到第 1 章章首：章首那张已读到，章中那张还没读到。
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/head.png',
        chapterIndex: 0,
        normCharOffset: 0,
      ),
      isFalse,
    );
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/middle.png',
        chapterIndex: 0,
        normCharOffset: 0,
      ),
      isTrue,
    );
    // 读过章中那张之后就不再算未读。
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/middle.png',
        chapterIndex: 0,
        normCharOffset: middle.normCharOffset,
      ),
      isFalse,
    );
  });

  test('later chapters count as unread, earlier ones do not', () {
    final IllustrationProgressIndex index = build();

    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/plate.jpg',
        chapterIndex: 0,
        normCharOffset: 10000,
      ),
      isTrue,
    );
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/plate.jpg',
        chapterIndex: 2,
        normCharOffset: 0,
      ),
      isFalse,
    );
  });

  test('cover sits before the body and is never treated as unread', () {
    final IllustrationProgressIndex index = build();

    expect(index.positions['OEBPS/images/cover.png']?.chapterIndex, -1);
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/cover.png',
        chapterIndex: 0,
        normCharOffset: 0,
      ),
      isFalse,
    );
  });

  test('unknown / null keys never blur', () {
    final IllustrationProgressIndex index = build();

    expect(
      index.isUnread(revealKey: null, chapterIndex: 0, normCharOffset: 0),
      isFalse,
    );
    expect(
      index.isUnread(
        revealKey: 'OEBPS/images/orphan.png',
        chapterIndex: 0,
        normCharOffset: 0,
      ),
      isFalse,
    );
    expect(
      IllustrationProgressIndex.empty.isUnread(
        revealKey: 'OEBPS/images/plate.jpg',
        chapterIndex: 0,
        normCharOffset: 0,
      ),
      isFalse,
    );
  });
}
