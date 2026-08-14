import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_history_source_corpus.dart';

/// TODO-1032 回归守卫（2026-08 扩写）：字幕书的音频真值必须落 `SrtBooks.audioPaths`，
/// 唯一写入路径是 `SrtBookRepository.replaceAudio`。
///
/// 原守卫钉的是「书架入口**永不**弹 AudiobookImportDialog」。那条判据太粗，反而
/// 掩盖了一个真 bug：EPUB 有声书除了 `audiobooks` 行还会落一条配对 `srt_books` 行，
/// 书架把它渲染成 SRT 卡片，于是这个入口也出现在**有声书**卡上；无条件走
/// `replaceAudio` 写 `SrtBooks` 时，播放侧 `AudiobookSessionLauncher.resolve`
/// **先查 Audiobooks 再回退 SrtBooks**，命中就返回——刚写的音频永远读不到
/// （用户报的「导入音频没用」）。
///
/// 所以判据改成「按播放侧真相分流」，两条都守：
///   1. 入口必须先 `getAudiobookByBookKey` 判这本书归哪张表；只有命中 Audiobooks
///      行才允许弹 [AudiobookImportDialog]（那本书的音频真值本来就在那张表）；
///   2. 真字幕书那一支必须走 [SrtBookReimportDialog] -> `reimportSrtBook`，而
///      `reimportSrtBook` 的音频写入必须是 `repo.replaceAudio(`——服务层不得自己
///      往 `Audiobooks` 写一行。
void main() {
  test('shelf SRT reimport routes by which table owns the audio', () {
    final String history = readReaderHistorySource();
    final int start = history.indexOf('Future<void> _openSrtBookReimport(');
    expect(start, isNonNegative,
        reason: '_openSrtBookReimport 应存在于书架 part 语料中');

    // 切出方法体：到下一个同缩进的方法签名为止。
    final int nextMethod = history.indexOf(
        '\n  Future<', start + 'Future<void> _openSrtBookReimport('.length);
    final String body = nextMethod >= 0
        ? history.substring(start, nextMethod)
        : history.substring(start);

    expect(body.contains('getAudiobookByBookKey('), isTrue,
        reason: '必须按「这本书有没有 Audiobooks 行」分流，'
            '而不是无条件写 SrtBooks（写了播放侧也不看）');
    expect(body.contains('SrtBookReimportDialog('), isTrue,
        reason: '真字幕书那一支必须走字幕书自己的重新导入对话框');
  });

  test('reimportSrtBook writes audio through replaceAudio only', () {
    final String service =
        File('lib/src/media/import/srt_book_reimport.dart').readAsStringSync();
    expect(service.contains('repo.replaceAudio('), isTrue,
        reason: '字幕书音频写入必须复用 SrtBookRepository.replaceAudio 唯一路径');
    expect(service.contains('AudiobookRepository('), isFalse,
        reason: '字幕书重新导入不得自己往 Audiobooks 表写行');
  });
}
