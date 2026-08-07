import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';

/// Guard: the overwrite import's content-tree swap renames a freshly-extracted
/// `.import-tmp` into place; on Windows an antivirus/indexer scanning the
/// just-written tree briefly locks it, so the rename fails with
/// ERROR_ACCESS_DENIED(5) / SHARING_VIOLATION(32) / DIR_NOT_EMPTY(145) — the
/// "备份导入失败: Rename failed … 拒绝访问" the user hit.
/// [BackupService.renameDirectoryWithRetry] must bounded-retry those transient
/// codes (rethrow when exhausted), and ONLY on Windows / ONLY for transient
/// codes (non-Windows or non-transient rethrows immediately).
void main() {
  FileSystemException winError(int code) => FileSystemException(
        'Rename failed',
        r'D:\APP\FUSHI_date\documents\hoshi_books.import-tmp',
        OSError('拒绝访问。', code),
      );

  group('BackupService.renameDirectoryWithRetry', () {
    test('happy path: 一次成功，不重试', () async {
      int renameCalls = 0;
      int sleepCalls = 0;
      await BackupService.renameDirectoryWithRetry(
        rename: () async => renameCalls++,
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(renameCalls, 1);
      expect(sleepCalls, 0);
    });

    test('Windows 瞬时 errno 5 两次后成功：重试救回', () async {
      int renameCalls = 0;
      int sleepCalls = 0;
      await BackupService.renameDirectoryWithRetry(
        rename: () async {
          renameCalls++;
          if (renameCalls <= 2) throw winError(5);
        },
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(renameCalls, 3);
      expect(sleepCalls, 2);
    });

    test('Windows SHARING_VIOLATION(32) / DIR_NOT_EMPTY(145) 也当瞬时重试', () async {
      for (final int code in <int>[32, 145]) {
        int renameCalls = 0;
        await BackupService.renameDirectoryWithRetry(
          rename: () async {
            renameCalls++;
            if (renameCalls == 1) throw winError(code);
          },
          sleep: (_) async {},
          isWindows: true,
        );
        expect(renameCalls, 2, reason: 'code $code should retry once');
      }
    });

    test('非 Windows：errno 5 立即抛，不重试', () async {
      int renameCalls = 0;
      int sleepCalls = 0;
      await expectLater(
        BackupService.renameDirectoryWithRetry(
          rename: () async {
            renameCalls++;
            throw winError(5);
          },
          sleep: (_) async => sleepCalls++,
          isWindows: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(renameCalls, 1);
      expect(sleepCalls, 0);
    });

    test('Windows 非瞬时码（如 2 not found）立即抛', () async {
      int renameCalls = 0;
      await expectLater(
        BackupService.renameDirectoryWithRetry(
          rename: () async {
            renameCalls++;
            throw winError(2);
          },
          sleep: (_) async {},
          isWindows: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(renameCalls, 1);
    });

    test('用尽 maxAttempts 后抛出最后一个异常', () async {
      int renameCalls = 0;
      await expectLater(
        BackupService.renameDirectoryWithRetry(
          rename: () async {
            renameCalls++;
            throw winError(5);
          },
          sleep: (_) async {},
          isWindows: true,
          maxAttempts: 4,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(renameCalls, 4);
    });
  });
}
