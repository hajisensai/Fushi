import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-142 诊断守卫：用户疑「坚果云同步把数据内容跑到文件外面去了 / 进度和书是
/// 分开的」。沿真实代码路径核实——这**不是 bug**：进度/统计/有声书位置/封面本就
/// 是独立 JSON，与 epub **平级放在同一个「书名」文件夹内**（ッツ Ebook Reader Web
/// 同步格式，见 ttu_filename.dart 顶部注释，git 首提即如此）。进度从来不是「嵌在
/// epub 文件里」。用户感知的「分开」来自 syncContent 默认 false：最初云端只有小进度
/// JSON，开内容同步/换设备后 epub 才与进度并列出现在同一书文件夹。
///
/// 本守卫钉死真正重要的**数据完整性契约**：同一本书的 progress 与 epub 必须写进
/// 同一个 folderId（书文件夹）。若未来有人把进度写到书文件夹**外面**（根目录或别
/// 处），数据会真正错位——这正是用户担心的情形，守卫在此防回归。
void main() {
  group('TODO-142: book progress metadata stays inside the book folder', () {
    test(
        'SyncManager._handleExport uploads progress AND content with the SAME folderId',
        () {
      final File src = File('lib/src/sync/sync_manager.dart');
      expect(src.existsSync(), isTrue,
          reason: 'run from the hibiki/ package root');
      final String body = src.readAsStringSync();

      final int idx = body.indexOf('Future<SyncBookResult> _handleExport(');
      expect(idx, greaterThanOrEqualTo(0),
          reason: '_handleExport 被改名/删除 — 更新本守卫');
      final int end = body.indexOf('Future<void> _exportContentIfMissing(');
      final String exportBody =
          end > idx ? body.substring(idx, end) : body.substring(idx);

      // 进度上传收 folderId（书文件夹），不是根目录或别处。
      expect(
        RegExp(r'updateProgressFile\(\s*folderId:\s*folderId')
            .hasMatch(exportBody),
        isTrue,
        reason: '进度必须上传到书文件夹 folderId，不得跑到外面（数据完整性）',
      );
      // 内容（epub/音频）上传也收同一个 folderId（与进度同目录）。
      expect(
        RegExp(r'_exportContentIfMissing\(\s*book:\s*book,\s*folderId:\s*folderId')
            .hasMatch(exportBody),
        isTrue,
        reason: 'epub 内容必须与进度上传到同一个书文件夹 folderId（不是分开两处）',
      );
    });

    test('WebDav updateProgressFile writes into the given folderId, not root',
        () {
      final File src = File('lib/src/sync/webdav_sync_backend.dart');
      final String body = src.readAsStringSync();

      final int idx = body.indexOf('Future<void> updateProgressFile(');
      expect(idx, greaterThanOrEqualTo(0));
      final String tail = body.substring(idx, idx + 600);
      // uploadJson 的目标目录是传入的 folderId（书文件夹），不是 baseUrl 根。
      expect(
        RegExp(r'uploadJson\(\s*folderId\b').hasMatch(tail),
        isTrue,
        reason: 'WebDAV 进度 JSON 必须 PUT 进 folderId（书文件夹）内',
      );
    });

    test('ttu_filename documents folder = book title (TTU-compatible layout)',
        () {
      final File src = File('lib/src/sync/ttu_filename.dart');
      final String body = src.readAsStringSync();
      // 文档化契约：文件夹名 = sanitized 书名；进度/统计是独立 JSON（非嵌入 epub）。
      expect(body.contains('文件夹名: sanitized book title'), isTrue,
          reason: 'TTU 兼容布局注释被删 — 这是 142 诊断的真相源，勿移除');
      expect(body.contains('progress_1_6_'), isTrue,
          reason: 'progress 文件名前缀（独立 JSON，与 epub 平级）');
    });
  });
}
