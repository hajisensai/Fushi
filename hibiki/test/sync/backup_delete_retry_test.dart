import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';

/// BUG-298 守卫：备份导出在 finally 里递归删临时目录时，Windows 上 sqlite/AV
/// 句柄的瞬时占用会把 delete 打成 ERROR_DIR_NOT_EMPTY(145) /
/// ERROR_SHARING_VIOLATION(32) / ERROR_ACCESS_DENIED(5)。
/// [BackupService.deleteDirectoryWithRetry] 必须对这类瞬时错误有界重试（用尽后
/// 抛出），且只在 Windows 触发、只对瞬时码触发；非 Windows / 非瞬时码直接抛。
void main() {
  FileSystemException winError(int code) => FileSystemException(
        'Deletion failed',
        r'C:\Users\wrds\AppData\Local\Temp\hibiki_backup_abc',
        OSError('目录不是空的。', code),
      );

  group('BackupService.deleteDirectoryWithRetry', () {
    test('happy path: 目录存在，删一次成功，不重试', () async {
      int deleteCalls = 0;
      int sleepCalls = 0;
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => true,
        delete: () async => deleteCalls++,
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(deleteCalls, 1);
      expect(sleepCalls, 0);
    });

    test('目录已不存在：不调 delete（早已清理）', () async {
      int deleteCalls = 0;
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => false,
        delete: () async => deleteCalls++,
        sleep: (_) async {},
        isWindows: true,
      );
      expect(deleteCalls, 0);
    });

    test('PathNotFoundException：检查与删除之间消失，吞掉不抛', () async {
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => true,
        delete: () async => throw const PathNotFoundException(
          'gone',
          OSError('not found', 2),
        ),
        sleep: (_) async {},
        isWindows: true,
      );
      // 不抛即通过。
    });

    test('Windows 瞬时 errno 145 两次后成功：重试后删成功救回', () async {
      int deleteCalls = 0;
      int sleepCalls = 0;
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => true,
        delete: () async {
          deleteCalls++;
          if (deleteCalls <= 2) throw winError(145);
        },
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(deleteCalls, 3); // 2 次失败 + 1 次成功
      expect(sleepCalls, 2); // 每次失败退避一次
    });

    test('Windows SHARING_VIOLATION errno 32 同样被当瞬时错误重试', () async {
      int deleteCalls = 0;
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => true,
        delete: () async {
          deleteCalls++;
          if (deleteCalls == 1) throw winError(32);
        },
        sleep: (_) async {},
        isWindows: true,
      );
      expect(deleteCalls, 2);
    });

    test('Windows ACCESS_DENIED errno 5 也是瞬时错误，重试救回', () async {
      int deleteCalls = 0;
      await BackupService.deleteDirectoryWithRetry(
        exists: () async => true,
        delete: () async {
          deleteCalls++;
          if (deleteCalls == 1) throw winError(5);
        },
        sleep: (_) async {},
        isWindows: true,
      );
      expect(deleteCalls, 2);
    });

    test('Windows 持续 errno 145：重试用尽后抛出（不静默吞）', () async {
      int deleteCalls = 0;
      await expectLater(
        BackupService.deleteDirectoryWithRetry(
          exists: () async => true,
          delete: () async {
            deleteCalls++;
            throw winError(145);
          },
          sleep: (_) async {},
          isWindows: true,
          maxAttempts: 4,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(deleteCalls, 4); // 试满 maxAttempts 后抛
    });

    test('非 Windows：errno 145 直接抛出，不重试（POSIX 不该走这条）', () async {
      int deleteCalls = 0;
      int sleepCalls = 0;
      await expectLater(
        BackupService.deleteDirectoryWithRetry(
          exists: () async => true,
          delete: () async {
            deleteCalls++;
            throw winError(145);
          },
          sleep: (_) async => sleepCalls++,
          isWindows: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(deleteCalls, 1);
      expect(sleepCalls, 0);
    });

    test('Windows 非瞬时错误（errno 13）直接抛出，不重试', () async {
      int deleteCalls = 0;
      int sleepCalls = 0;
      await expectLater(
        BackupService.deleteDirectoryWithRetry(
          exists: () async => true,
          delete: () async {
            deleteCalls++;
            throw winError(13);
          },
          sleep: (_) async => sleepCalls++,
          isWindows: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(deleteCalls, 1);
      expect(sleepCalls, 0);
    });
  });
}
