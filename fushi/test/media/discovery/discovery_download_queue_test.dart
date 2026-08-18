import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';

DiscoveryResourceItem _item(
  String id, {
  String url = 'https://example.com/files/book.epub',
  String? fileName,
}) {
  return DiscoveryResourceItem(
    sourceId: 'src',
    title: 'title-$id',
    id: id,
    kind: DiscoveryMediaKind.novel,
    payloadKind: DiscoveryPayloadKind.httpFile,
    payload: DiscoveryHttpPayload(url: url, fileName: fileName),
  );
}

Future<DiscoveryPayload> _defaultResolver(DiscoveryResourceItem item) async =>
    item.payload!;

Future<void> _waitFor(bool Function() condition) async {
  for (int i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('discovery_queue_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，不让清理失败弄红测试。
    }
  });

  ResumableDownloadResponse okBytes(List<int> body) =>
      ResumableDownloadResponse.bytes(
        statusCode: 200,
        body: body,
        headers: <String, String>{'content-length': '${body.length}'},
      );

  test('成功路径：下载落盘 → 自动导入 → done，importedCount 累计', () async {
    final List<int> body = utf8.encode('epub-bytes');
    final List<String> importedFiles = <String>[];
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask task, File file) async {
        importedFiles.add(file.path);
        return const DiscoveryImportOutcome(importedCount: 1, summary: 'ok');
      },
      openOverride: (Uri uri, Map<String, String> headers) async =>
          okBytes(body),
    );
    addTearDown(queue.dispose);

    expect(
      queue.enqueue(_item('1'), destinationDir: tempDir.path),
      isTrue,
    );
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.done);
    expect(task.filePath, endsWith('book.epub'));
    expect(await File(task.filePath!).readAsBytes(), body);
    expect(importedFiles.single, task.filePath);
    expect(task.importOutcome?.summary, 'ok');
    expect(queue.importedCount, 1);
  });

  test('同源同 id 未完成任务去重；顺序一次一个', () async {
    final Completer<void> gate = Completer<void>();
    final List<String> started = <String>[];
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async {
        started.add(uri.toString());
        await gate.future;
        return okBytes(utf8.encode('x'));
      },
    );
    addTearDown(queue.dispose);

    expect(
      queue.enqueue(_item('1'), destinationDir: tempDir.path),
      isTrue,
    );
    expect(
      queue.enqueue(_item('1'), destinationDir: tempDir.path),
      isFalse,
      reason: '同条目未完成时重复入队应被拒',
    );
    expect(
      queue.enqueue(
        _item('2', url: 'https://example.com/files/two.epub'),
        destinationDir: tempDir.path,
      ),
      isTrue,
    );
    expect(queue.totalCount, 2);

    await _waitFor(() => started.length == 1);
    expect(
      queue.tasks[1].status,
      DiscoveryDownloadStatus.queued,
      reason: '单飞：第一个没完，第二个不该开跑',
    );

    gate.complete();
    await _waitFor(
        () => queue.tasks.every((DiscoveryDownloadTask t) => t.isFinished));
    expect(started.length, 2);
  });

  test('瞬时网络错误自动退避重试后成功', () async {
    int calls = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(importedCount: 1),
      openOverride: (Uri uri, Map<String, String> headers) async {
        calls++;
        if (calls == 1) throw const SocketException('flaky');
        return okBytes(utf8.encode('x'));
      },
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 20)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(
      () => queue.tasks.single.status == DiscoveryDownloadStatus.done,
    );
    expect(calls, 2);
    expect(queue.tasks.single.autoRetries, 1);
  });

  test('HTTP 404 是稳定结论：直接 failed，不自动重试', () async {
    int calls = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async {
        calls++;
        return ResumableDownloadResponse.bytes(statusCode: 404, body: <int>[]);
      },
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 20)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.failed);
    expect(calls, 1);
    expect(queue.tasks.single.autoRetries, 0);
  });

  test('HTTP 503 属瞬时：进入退避重试', () async {
    int calls = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async {
        calls++;
        if (calls == 1) {
          return ResumableDownloadResponse.bytes(
            statusCode: 503,
            body: <int>[],
          );
        }
        return okBytes(utf8.encode('x'));
      },
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 20)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(
      () => queue.tasks.single.status == DiscoveryDownloadStatus.done,
    );
    expect(calls, 2);
  });

  test('导入失败不自动重试；手动重试跳过下载直接重导', () async {
    int opens = 0;
    int imports = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async {
        imports++;
        if (imports == 1) throw const SocketException('db down');
        return const DiscoveryImportOutcome(importedCount: 1);
      },
      openOverride: (Uri uri, Map<String, String> headers) async {
        opens++;
        return okBytes(utf8.encode('x'));
      },
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 20)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);
    expect(
      queue.tasks.single.status,
      DiscoveryDownloadStatus.failed,
      reason: '导入失败即使是网络型异常也不该吃下载重试预算',
    );
    expect(opens, 1);

    queue.retry(queue.tasks.single);
    await _waitFor(
      () => queue.tasks.single.status == DiscoveryDownloadStatus.done,
    );
    expect(opens, 1, reason: '目标文件已在，重试不重下');
    expect(queue.tasks.single.skippedDownload, isTrue);
    expect(imports, 2);
    expect(queue.importedCount, 1);
  });

  test('源 resolve 出 torrent payload 属实现 bug：failed 不重试', () async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem _) async =>
          const DiscoveryTorrentPayload(magnetUri: 'magnet:?xt=x'),
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async =>
          okBytes(<int>[]),
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 20)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.failed);
    expect(queue.tasks.single.autoRetries, 0);
  });

  test('取消排队中的任务直接移除；取消执行中的任务归 cancelled', () async {
    final Completer<void> gate = Completer<void>();
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async {
        await gate.future;
        return okBytes(utf8.encode('x'));
      },
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    queue.enqueue(
      _item('2', url: 'https://example.com/files/two.epub'),
      destinationDir: tempDir.path,
    );
    await _waitFor(
      () => queue.tasks.first.status == DiscoveryDownloadStatus.running,
    );

    // 排队中的：直接移除。
    queue.cancel(queue.tasks[1]);
    expect(queue.totalCount, 1);

    // 执行中的：置取消标记，流收尾后归 cancelled。
    queue.cancel(queue.tasks.single);
    gate.complete();
    await _waitFor(() => queue.tasks.single.isFinished);
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.cancelled);
  });

  test('clearFinished 只清终态任务', () async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _defaultResolver,
      importer: (DiscoveryDownloadTask _, File __) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async =>
          okBytes(utf8.encode('x')),
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item('1'), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);
    queue.clearFinished();
    expect(queue.totalCount, 0);
  });

  group('sanitizeDiscoveryFileName', () {
    test('剥路径分隔与 Windows 非法字符', () {
      expect(
        sanitizeDiscoveryFileName(r'a/b\c:d*e?"f"<g>|h.epub'),
        'a b c d e f g h.epub',
      );
    });

    test('压缩空白并去尾点/空格', () {
      expect(sanitizeDiscoveryFileName('  a   b.txt.  '), 'a b.txt');
    });

    test('空/纯点回退 download', () {
      expect(sanitizeDiscoveryFileName('   '), 'download');
      expect(sanitizeDiscoveryFileName('..'), 'download');
    });
  });
}
