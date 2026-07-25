import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS data root security-scoped bookmark guard', () {
    String read(String path) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: 'missing $path');
      return file.readAsStringSync();
    }

    test('entitlements allow app-scoped security bookmarks', () {
      for (final String path in <String>[
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final String src = read(path);
        expect(
            src, contains('com.apple.security.files.user-selected.read-write'));
        expect(src, contains('com.apple.security.files.bookmarks.app-scope'));
      }
    });

    test('AppDelegate creates and restores security-scoped bookmarks', () {
      final String src = read('macos/Runner/AppDelegate.swift');
      expect(src, contains('app.hibiki/data_root_access'));
      expect(src, contains('bookmarkData('));
      expect(src, contains('.withSecurityScope'));
      expect(src, contains('startAccessingSecurityScopedResource()'));
      expect(src, contains('activeSecurityScopedURLs'));
    });

    test('Dart startup restores bookmark before data root existence check', () {
      final String src = read('lib/src/storage/app_paths.dart');
      final int restoreIdx =
          src.indexOf('MacOSDataRootAccess.startAccessingStoredBookmark');
      // TODO-1260：existsSync() 已换成带超时的异步 exists() 探测（掉线盘不 hang）。
      // BUG-815 后探测收敛进 _probeDataRootExists，且 resolve() 预检的探测入参
      // configured 只能来自 _configuredDataRootPath()——bookmark 恢复就在该函数
      // 内部完成，所以顺序契约改由数据依赖表达：先 await _configuredDataRootPath()
      // 拿到 configured，再把它喂给 _probeDataRootExists。
      final int configuredIdx = src.indexOf('await _configuredDataRootPath()');
      final int probeCallIdx =
          src.indexOf('_probeDataRootExists(Directory(configured))');
      expect(restoreIdx, greaterThan(0));
      expect(configuredIdx, greaterThan(0));
      expect(probeCallIdx, greaterThan(0));
      expect(configuredIdx, lessThan(probeCallIdx),
          reason: 'resolve() must obtain configured via '
              '_configuredDataRootPath() (which restores the bookmark) before '
              'probing data-root existence');
      expect(src, contains('_configuredDataRootPath'),
          reason:
              'sandbox permission must be restored before touching dataRoot');
    });

    test('migration stores bookmark before data_root path', () {
      final String src =
          read('lib/src/sync/sync_settings_schema/data_root.part.dart');
      final int createIdx = src.indexOf('createBookmarkForPath(picked)');
      final int migrateIdx = src.indexOf('DataRootMigrator().migrate(');
      final int storeIdx = src.indexOf('MacOSDataRootAccess.storeBookmark');
      final int pathIdx = src.indexOf('setString(AppPaths.dataRootPrefKey');
      expect(createIdx, greaterThan(0));
      expect(migrateIdx, greaterThan(0));
      expect(createIdx, lessThan(migrateIdx),
          reason:
              'bookmark creation must happen while NSOpenPanel access is live');
      expect(storeIdx, greaterThan(0));
      expect(pathIdx, greaterThan(0));
      expect(storeIdx, lessThan(pathIdx),
          reason: 'new process must not see data_root without its bookmark');
    });

    test('migration restores the previous bookmark when data_root write fails',
        () {
      final String src =
          read('lib/src/sync/sync_settings_schema/data_root.part.dart');
      final int previousIdx = src.indexOf('previousBookmark');
      final int storeIdx = src.indexOf('MacOSDataRootAccess.storeBookmark');
      final int rootWriteIdx =
          src.indexOf('setString(AppPaths.dataRootPrefKey');
      final int restoreIdx = src.indexOf('MacOSDataRootAccess.restoreBookmark');
      expect(previousIdx, greaterThan(0));
      expect(storeIdx, greaterThan(0));
      expect(rootWriteIdx, greaterThan(0));
      expect(restoreIdx, greaterThan(rootWriteIdx),
          reason:
              'if data_root write fails after bookmark write, the old bookmark must be restored');
      expect(previousIdx, lessThan(storeIdx),
          reason: 'old bookmark has to be captured before it is overwritten');
    });
  });
}
