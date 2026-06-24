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

  group(
      'BUG-414/TODO-809 forward guard: audiobook write paths bind the SOURCE '
      'real key, never sanitizeTtuFilename(title)', () {
    // 历史 BUG-414：pull/import 侧用 sanitizeTtuFilename(title) 重算 audiobook 的
    // book_key 而非源端真实 key 写库 → audiobooks.book_key 与 epub_books.book_key
    // 失配 → 书架耳机徽章查不中（有声书集体「变普通书」）。v26 一次性回填已愈旧库，
    // 本守卫把「写入侧永远用源端真实 key」钉成可回归契约，挡住整个 audiobook 写入
    // 家族（三条 pull 写入路径）退回 sanitize(title) 重算。
    test(
        'orchestrator pull import binds bookKeyOverride to the local EPUB key '
        '(localBookKeys-filtered), not a recomputed sanitize', () {
      final String src = read('lib/src/sync/sync_orchestrator.dart');
      // Pull import 的 override 绑定的是 toPull 循环变量 key（= 已被 localBookKeys
      // 筛过的本地 EPUB bookKey），而非任何 sanitizeTtuFilename(...title)。
      expect(src, contains('bookKeyOverride: key'),
          reason: 'pull import 的 bookKeyOverride 必须是本地 EPUB 的真实 key 变量');
      // audiobook 写入 override 绝不出现按 title 重算 key（BUG-414 失配根因）。
      // 注意：epub_books 的 book_key 本就是 sanitizeTtuFilename(title)，故 EPUB
      // 书 diff 里的 sanitizeTtuFilename(...) 是合法的，本守卫只钉 audiobook 写入
      // override 这一处不得重算。
      expect(src, isNot(contains('bookKeyOverride: sanitizeTtuFilename(')),
          reason: '禁止把 sanitizeTtuFilename(...) 作为 audiobook 写入 override');
    });

    test(
        'all three pull write sites import audiobooks WITHOUT '
        'sanitizeTtuFilename(...title) as the bound key', () {
      const List<String> sites = <String>[
        'lib/src/pages/implementations/reader_history/remote.part.dart',
        'lib/src/sync/sync_compare_dialog.dart',
        'lib/src/sync/sync_orchestrator.dart',
      ];
      for (final String site in sites) {
        final String src = read(site);
        // 各写入点都接了真实导入原语。
        expect(src, contains('importAudioDatabasePackage('),
            reason: '$site 必须经 importAudioDatabasePackage 落盘');
        // 任一写入点都不得用 title 重算 audiobook key（BUG-414 整类回归）。
        expect(src, isNot(contains('sanitizeTtuFilename(book.title)')),
            reason: '$site 禁止用 sanitizeTtuFilename(book.title) 重算有声书 key');
        expect(src, isNot(contains('sanitizeTtuFilename(entry.title)')),
            reason: '$site 禁止用 sanitizeTtuFilename(entry.title) 重算有声书 key');
        expect(src, isNot(contains('sanitizeTtuFilename(a.title)')),
            reason: '$site 禁止用 sanitizeTtuFilename(a.title) 重算有声书 key');
      }
    });
  });
}
