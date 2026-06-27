/// TODO-919 / BUG-441：书架有声书卡角标守卫。
///
/// 病灶：TODO-894 起 EPUB 有声书导入会额外落一条 `srt_books` 配对行（stable uid
/// `srtbook_epub_<bookKey>`），书架因此把它当**字幕书**经 `_buildSrtCard` 渲染，
/// 右上角角标从耳机（有声书语义）变成了字幕图标。
///
/// 修复：`_buildSrtCard` / `_buildSrtCover` 用纯判据 [isEpubBackedAudiobookSrt]
/// 区分「EPUB 有声书配对行（bookKey 非空且有音频）→ 耳机」与「纯字幕书 → 字幕」。
///
/// 本测试直接驱动该纯判据（widget 私有难驱动），断言：
/// - EPUB 关联 + 有 audioPaths → true（耳机）
/// - EPUB 关联 + 有 audioRoot → true（耳机）
/// - EPUB 关联但无音频 → false（字幕，纯关联字幕书不误判）
/// - 无 EPUB 关联（bookKey 空）即便有音频 → false（standalone 字幕书不变）
///
/// load-bearing：把 [isEpubBackedAudiobookSrt] 改回恒 false（回退修复）会让前两条断言变红。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show isEpubBackedAudiobookSrt;
import 'package:hibiki_audio/hibiki_audio.dart';

SrtBook _srt({
  required String bookKey,
  List<String>? audioPaths,
  String? audioRoot,
}) {
  final SrtBook book = SrtBook()
    ..uid = 'srtbook_epub_$bookKey'
    ..title = 'T'
    ..srtPath = '/tmp/a.srt'
    ..importedAt = 0
    ..bookKey = bookKey
    ..audioPaths = audioPaths
    ..audioRoot = audioRoot;
  return book;
}

void main() {
  group('TODO-919 / BUG-441 isEpubBackedAudiobookSrt', () {
    test('EPUB-backed row with audioPaths is an audiobook (headphones)', () {
      expect(
        isEpubBackedAudiobookSrt(
          _srt(bookKey: 'book-1', audioPaths: const ['/a/1.mp3']),
        ),
        isTrue,
      );
    });

    test('EPUB-backed row with audioRoot is an audiobook (headphones)', () {
      expect(
        isEpubBackedAudiobookSrt(
          _srt(bookKey: 'book-1', audioRoot: '/audio/dir'),
        ),
        isTrue,
      );
    });

    test('EPUB-linked subtitle book without audio stays subtitles', () {
      expect(
        isEpubBackedAudiobookSrt(_srt(bookKey: 'book-1')),
        isFalse,
      );
      expect(
        isEpubBackedAudiobookSrt(
          _srt(bookKey: 'book-1', audioPaths: const <String>[], audioRoot: ''),
        ),
        isFalse,
      );
    });

    test(
        'standalone subtitle book (no bookKey) stays subtitles even with audio',
        () {
      expect(
        isEpubBackedAudiobookSrt(
          _srt(bookKey: '', audioPaths: const ['/a/1.mp3']),
        ),
        isFalse,
      );
    });
  });
}
