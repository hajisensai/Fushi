import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-406 守卫：互联下载有声书丢音频。
///
/// 历史 bug = 互联下载（书架远端书卡 + 同步对比对话框）只下/导 EPUB，从不补下
/// 有声书包，即使远端书 `hasAudiobook`。修复 = 在两个下载侧接上既有原语
/// `getRemoteAudiobook` + `importAudioDatabasePackage`。这两条接线一旦被退回到
/// 「只导 EPUB」就回归 BUG-406，本守卫源码级钉死接线存在，避免静默回退。
void main() {
  String read(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: 'missing source file: $relative');
    return f.readAsStringSync();
  }

  group('BUG-406 audiobook download wiring is present at both download sites',
      () {
    test(
        'bookshelf remote download (remote.part.dart) wires audiobook fetch + '
        'import after EPUB import', () {
      final String src =
          read('lib/src/pages/implementations/reader_history/remote.part.dart');

      // EPUB 导入后调用有声书接线。
      expect(src, contains('_downloadRemoteAudiobook('),
          reason: '书架远端下载必须在 EPUB 导入后接有声书下载');
      // 经互联后端的 live API 下载有声书包。
      expect(src, contains('getRemoteAudiobook('),
          reason: '有声书包必须经 HibikiClientSyncBackend.getRemoteAudiobook 下载');
      // 经既有解包原语导入，且用本地 bookKey 作 override 绑定。
      expect(src, contains('importAudioDatabasePackage('),
          reason: '有声书包必须经 importAudioDatabasePackage 解包落盘');
      expect(src, contains('bookKeyOverride:'),
          reason: '解包必须用本地刚导入 EPUB 的 bookKey 作 override 绑定');
      // 远端有声书键与 host 同源（sanitizeTtuFilename(title)）。
      expect(src, contains('sanitizeTtuFilename(book.title)'),
          reason: '远端有声书 bookKey 必须 = sanitizeTtuFilename(title)，与 host 同源');
      // 有声书失败有专用可见错误（不静默吞）。
      expect(src, contains('remote_book_audiobook_download_failed'),
          reason: '有声书下载/导入失败必须有可见错误提示');
    });

    test(
        'sync compare dialog (sync_compare_dialog.dart) wires audiobook fetch + '
        'import on the interconnect live branch', () {
      final String src = read('lib/src/sync/sync_compare_dialog.dart');

      expect(src, contains('_downloadLiveAudiobookFor('),
          reason: '互联对比下载远端独有书必须在 EPUB 导入后接有声书下载');
      expect(src, contains('getRemoteAudiobook('),
          reason: '有声书包必须经 HibikiClientSyncBackend.getRemoteAudiobook 下载');
      expect(src, contains('importAudioDatabasePackage('),
          reason: '有声书包必须经 importAudioDatabasePackage 解包落盘');
      expect(src, contains('bookKeyOverride:'),
          reason: '解包必须用本地刚导入 EPUB 的 bookKey 作 override 绑定');
      expect(src, contains('sanitizeTtuFilename(entry.title)'),
          reason: '远端有声书 bookKey 必须 = sanitizeTtuFilename(title)，与 host 同源');
    });
  });
}
