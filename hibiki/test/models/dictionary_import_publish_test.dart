import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';

/// BUG-050 守卫：词典导入「发布到最终目录」的 rename 在 Windows 上会被
/// Defender/搜索索引器的瞬时句柄占用打成 ERROR_ACCESS_DENIED(5) /
/// SHARING_VIOLATION(32)。`publishImportedDir` 必须对这类瞬时错误有界重试，
/// 用尽后回退「复制+删源」，且只在 Windows 触发、只对瞬时码触发。
void main() {
  FileSystemException winError(int code) => FileSystemException(
        'Rename failed',
        r'C:\Users\wrds\Documents\dictionaryResources\import_temp\辞典',
        OSError('拒绝访问。', code),
      );

  group('DictionaryImportManager.publishImportedDir', () {
    test('happy path: rename 一次成功，不重试不复制', () async {
      int renameCalls = 0;
      int copyCalls = 0;
      int sleepCalls = 0;
      final method = await DictionaryImportManager.publishImportedDir(
        rename: () async => renameCalls++,
        copyThenDelete: () async => copyCalls++,
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(method, DictPublishMethod.renamed);
      expect(renameCalls, 1);
      expect(copyCalls, 0);
      expect(sleepCalls, 0);
    });

    test('Windows 瞬时 errno 5 两次后成功：重试后 rename 成功，不复制', () async {
      int renameCalls = 0;
      int copyCalls = 0;
      int sleepCalls = 0;
      final method = await DictionaryImportManager.publishImportedDir(
        rename: () async {
          renameCalls++;
          if (renameCalls <= 2) throw winError(5);
        },
        copyThenDelete: () async => copyCalls++,
        sleep: (_) async => sleepCalls++,
        isWindows: true,
      );
      expect(method, DictPublishMethod.renamed);
      expect(renameCalls, 3); // 2 次失败 + 1 次成功
      expect(sleepCalls, 2); // 每次失败退避一次
      expect(copyCalls, 0); // 没走到回退
    });

    test('Windows 持续 errno 5：重试用尽后回退复制+删源', () async {
      int renameCalls = 0;
      int copyCalls = 0;
      final method = await DictionaryImportManager.publishImportedDir(
        rename: () async {
          renameCalls++;
          throw winError(5);
        },
        copyThenDelete: () async => copyCalls++,
        sleep: (_) async {},
        isWindows: true,
        maxAttempts: 4,
      );
      expect(method, DictPublishMethod.copied);
      expect(renameCalls, 4); // 试满 maxAttempts
      expect(copyCalls, 1); // 回退一次
    });

    test('Windows SHARING_VIOLATION errno 32 同样被当瞬时错误重试', () async {
      int renameCalls = 0;
      final method = await DictionaryImportManager.publishImportedDir(
        rename: () async {
          renameCalls++;
          if (renameCalls == 1) throw winError(32);
        },
        copyThenDelete: () async {},
        sleep: (_) async {},
        isWindows: true,
      );
      expect(method, DictPublishMethod.renamed);
      expect(renameCalls, 2);
    });

    test('非 Windows：errno 5 直接抛出，不重试不复制（POSIX rename 不该走这条）', () async {
      int copyCalls = 0;
      await expectLater(
        DictionaryImportManager.publishImportedDir(
          rename: () async => throw winError(5),
          copyThenDelete: () async => copyCalls++,
          sleep: (_) async {},
          isWindows: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(copyCalls, 0);
    });

    test('Windows 非瞬时错误（errno 13）直接抛出，不重试不复制', () async {
      int copyCalls = 0;
      int sleepCalls = 0;
      await expectLater(
        DictionaryImportManager.publishImportedDir(
          rename: () async => throw winError(13),
          copyThenDelete: () async => copyCalls++,
          sleep: (_) async => sleepCalls++,
          isWindows: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(copyCalls, 0);
      expect(sleepCalls, 0);
    });
  });
}
