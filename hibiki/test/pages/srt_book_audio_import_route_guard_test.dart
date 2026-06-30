import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_history_source_corpus.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-1032 回归守卫：SRT 字幕书的音频真值必须统一落 SrtBooks.audioPaths，三入口
/// 归一到 SrtBookRepository.replaceAudio。历史上书架卡片「导入音频」入口误弹
/// AudiobookImportDialog（写进 Audiobooks 表），导致导入对话框查不到、显示空表单。
///
/// 这里用源码切片守卫，防止任何人把书架「导入音频」入口改回 AudiobookImportDialog：
///   1. 书架 _openAudioImport 必须调 replaceAudio，且方法体内不得实例化
///      AudiobookImportDialog。
///   2. 阅读器内 SRT 音频导入也走 replaceAudio（与书架同一写入路径）。
void main() {
  test(
      'shelf _openAudioImport routes SRT audio through replaceAudio, never '
      'AudiobookImportDialog', () {
    final String history = readReaderHistorySource();
    final int start = history.indexOf('Future<void> _openAudioImport(');
    expect(start, isNonNegative, reason: '_openAudioImport 应存在于书架 part 语料中');

    // 切出 _openAudioImport 方法体：到下一个同缩进的方法签名为止。
    final int nextMethod = history.indexOf(
        '\n  Future<', start + 'Future<void> _openAudioImport('.length);
    final String body = nextMethod >= 0
        ? history.substring(start, nextMethod)
        : history.substring(start);

    expect(body.contains('replaceAudio('), isTrue,
        reason: '书架「导入音频」必须经 SrtBookRepository.replaceAudio 写 SrtBook');
    expect(body.contains('AudiobookImportDialog'), isFalse,
        reason: 'SRT 书「导入音频」不得弹 AudiobookImportDialog（会误写 Audiobooks 表）');
  });

  test('reader in-page SRT audio import also routes through replaceAudio', () {
    final String reader = readReaderPageSource();
    expect(reader.contains('replaceAudio('), isTrue,
        reason: '阅读器内 SRT 音频导入应与书架共用 replaceAudio 写入路径');
  });
}
