// TODO-935 E2/E3: 数据存储位置设置项的纯函数 + 源码守卫。
//
// 整链（选目录 -> 关资源 -> 整目录搬移 -> rebase DB -> 写 pref -> 起新进程重启）无法在
// headless 测试里真正跑（要真实文件锁、真实 Process.start、真实平台 SharedPreferences），
// 留给真机。这里覆盖可纯测的两块：
//   1) [validateDataRootTarget] 触发前校验的纯逻辑（自我迁移 / 目标非空 / 合法）。
//   2) 源码守卫：桌面 restartApp 真起新进程 + 设置项确实接入迁移引擎与重启。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:path/path.dart' as p;

void main() {
  group('validateDataRootTarget (TODO-935 E2 pre-flight)', () {
    const String oldDocs = '/data/app/documents';
    const String oldSupport = '/data/app/support';

    bool alwaysEmpty(String _) => false;

    test('a fresh sibling directory is accepted', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        newDataRoot: '/data/new-root',
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, isNull);
    });

    test('target equal to the documents root is rejected (self-migrate)', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        newDataRoot: oldDocs,
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
    });

    test('target inside the support root is rejected', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        newDataRoot: p.join(oldSupport, 'nested'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
    });

    test('target whose documents/support subtree already has files is rejected',
        () {
      // The probe reports the derived <newRoot>/documents (or /support) as
      // containing files -> must refuse to overwrite existing data.
      final DataRootTargetRejection? r = validateDataRootTarget(
        newDataRoot: '/data/occupied',
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: (String path) => path.contains('occupied'),
      );
      expect(r, DataRootTargetRejection.targetNotEmpty);
    });
  });

  group('source guards (TODO-935 E2/E3)', () {
    File readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f;
    }

    test('desktop restartApp actually spawns a new process and exits', () {
      final String src =
          readSource('lib/src/platform/desktop/desktop_lifecycle_service.dart')
              .readAsStringSync();
      // supportsRestart must be true now (locale-change + data-root migration
      // both gate on it), and restart must launch self + exit, not be a no-op.
      expect(src.contains('bool get supportsRestart => true'), isTrue);
      expect(src.contains('Process.start('), isTrue);
      expect(src.contains('Platform.resolvedExecutable'), isTrue);
      expect(src.contains('ProcessStartMode.detached'), isTrue);
      expect(src.contains('exit(0)'), isTrue);
      // Guard against regressing to the empty stub.
      expect(src.contains('Future<void> restartApp() async {}'), isFalse);
    });

    test('data-root settings widget wires migrator + close + restart', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart')
              .readAsStringSync();
      // Triggers the already-implemented migration engine.
      expect(src.contains('DataRootMigrator().migrate('), isTrue);
      // Injects real resource closers: audio stop, dict FFI dispose, DB close.
      expect(src.contains('audiobookSession.stop()'), isTrue);
      expect(src.contains('HoshiDicts.disposeInstance()'), isTrue);
      expect(src.contains('closeDatabase()'), isTrue);
      expect(src.contains('wal_checkpoint(TRUNCATE)'), isTrue);
      // Writes the data_root pref via the canonical key.
      expect(src.contains('AppPaths.dataRootPrefKey'), isTrue);
      // Auto-restarts after a successful migration.
      expect(src.contains('restartApp()'), isTrue);
    });

    test('data-storage section is gated desktop-only', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      expect(src.contains("id: 'sync.data_storage_location'"), isTrue);
      expect(src.contains('_DataRootWidget(settingsContext: ctx)'), isTrue);
      // The section + item both gate on isDesktopPlatform so mobile never sees
      // a control it cannot honor (sandbox-fixed roots).
      expect(
        src.contains('visible: (SettingsContext ctx) => isDesktopPlatform'),
        isTrue,
      );
    });
  });
}
