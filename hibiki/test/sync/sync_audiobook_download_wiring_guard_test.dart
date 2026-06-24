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
      // 远端有声书键 = host 传来的真实 bookKey（book.downloadId = bookKey ?? title），
      // 与 EPUB 下载同源；不得 sanitizeTtuFilename(title) 重算（BUG-414 致 404）。
      expect(src, contains('book.downloadId'),
          reason: '远端有声书 bookKey 必须 = book.downloadId（host 真实 key），'
              '与 EPUB 下载同源');
      expect(src, isNot(contains('sanitizeTtuFilename(book.title)')),
          reason: '禁止用 sanitizeTtuFilename(title) 重算有声书 key（BUG-414 致 404）');
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
      // 远端有声书键 = host 清单条目的真实 bookKey（按 title 匹配 RemoteAudiobookInfo），
      // 不得 sanitizeTtuFilename(entry.title) 重算（BUG-414 致 404）。
      expect(src, contains('listRemoteAudiobooks('),
          reason: '必须查 host 有声书清单拿真实 bookKey');
      expect(src, contains('a.bookKey'),
          reason: '必须用清单条目的真实 bookKey 下载，而非 sanitize(title)');
      expect(src, isNot(contains('sanitizeTtuFilename(entry.title)')),
          reason: '禁止用 sanitizeTtuFilename(title) 重算有声书 key（BUG-414 致 404）');
    });
  });

  group('TODO-809 live audiobook sync pulls remote-only into local books', () {
    test(
        'orchestrator _syncAudiobooksLive wires toPull download + import '
        '(not push-only)', () {
      final String src = read('lib/src/sync/sync_orchestrator.dart');

      // 必须遍历 diff.toPull（历史 push-only 时根本不读 toPull）。
      expect(src, contains('diff.toPull'),
          reason: '立即/自动同步有声书必须遍历 diff.toPull（双向拉取），'
              '不能再 push-only');
      // Pull 经 live API 下载有声书包。
      expect(src, contains('backend.getRemoteAudiobook('),
          reason: 'toPull 必须经 HibikiClientSyncBackend.getRemoteAudiobook 下载');
      // Pull 经既有解包原语落盘，并用本地 bookKey 作 override 绑定。
      expect(src, contains('importAudioDatabasePackage('),
          reason: 'toPull 必须经 importAudioDatabasePackage 解包落盘');
      expect(src, contains('bookKeyOverride:'),
          reason: '解包必须用本地 EPUB 的 bookKey 作 override 绑定');
      // 防孤儿：只拉本端已有同 bookKey EPUB 的远端项。
      expect(src, contains('localBookKeys'),
          reason: 'toPull 必须先按本地 EPUB 的 bookKey 集合筛过，避免落孤儿有声书行');
      expect(src, contains('localBookKeys.contains('),
          reason: '只对本端已有同 bookKey EPUB 的远端项拉取（防孤儿）');
      // Pull 成功计入 audiobooksImported（触发本地库刷新）。
      expect(src, contains('report.audiobooksImported++'),
          reason: 'toPull 落盘后必须计入 audiobooksImported');
    });
  });
}
