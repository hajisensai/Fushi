// TODO-935 E2/E3: 数据存储位置设置项的纯函数 + 源码守卫。
//
// 整链（选目录 -> 关资源 -> 整目录搬移 -> rebase DB -> 写 pref -> 起新进程重启）无法在
// headless 测试里真正跑（要真实文件锁、真实 Process.start、真实平台 SharedPreferences），
// 留给真机。这里覆盖可纯测的两块：
//   1) [validateDataRootTarget] 触发前校验的纯逻辑（自我迁移 / 目标非空 / 合法）。
//   2) 源码守卫：桌面 restartApp 真起新进程 + 设置项确实接入迁移引擎与重启。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/storage/data_root_migrator.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:path/path.dart' as p;

void main() {
  group('validateDataRootTarget (TODO-935 E2 pre-flight)', () {
    const String oldDocs = '/data/app/documents';
    const String oldSupport = '/data/app/support';

    bool alwaysEmpty(String _) => false;

    test('a fresh sibling directory is accepted', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot('/data/new-root'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, isNull);
    });

    test('target equal to the documents root is rejected (self-migrate)', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot(oldDocs),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
    });

    test('target inside the support root is rejected', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target:
            DataRootMigrationTarget.customRoot(p.join(oldSupport, 'nested')),
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
        target: DataRootMigrationTarget.customRoot('/data/occupied'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: (String path) => path.contains('occupied'),
      );
      expect(r, DataRootTargetRejection.targetNotEmpty);
    });

    test('target is the install dir (contains the running exe) is rejected',
        () {
      // TODO-1182：exe 落在 newRoot 里 → newRoot 是安装目录 → 拒绝（否则失败回滚会删安装目录）。
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot('/apps/Hibiki'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        executablePath: '/apps/Hibiki/hibiki.exe',
      );
      expect(r, DataRootTargetRejection.containsExecutable);
    });

    test('target is an ancestor of the exe dir is rejected', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot('/apps'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        executablePath: '/apps/Hibiki/bin/hibiki.exe',
      );
      expect(r, DataRootTargetRejection.containsExecutable);
    });

    test('exe outside the target dir does not trigger install-dir rejection',
        () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot('/data/new-root'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        executablePath: '/apps/Hibiki/hibiki.exe',
      );
      expect(r, isNull);
    });

    test('null executablePath keeps pre-1182 behavior (no install-dir check)',
        () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot('/data/new-root'),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
      );
      expect(r, isNull);
    });

    // BUG-1115：老安装的 documents 根就是共享的平台 `Documents`。把散落其中的 16 个
    // Hibiki 目录收进 `Documents\Hibiki` 是这批用户唯一自然的整理路径，之前被
    // insideCurrentRoot 一刀切拒绝（新根「位于」旧根内部）。共享根走白名单选择性搬移，
    // 非白名单子目录在搬移全程都是旁观者，因此必须放行。
    test(
        'BUG-1115: nested non-whitelisted dir under the SHARED documents root '
        'is accepted', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot(p.join(oldDocs, 'Hibiki')),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        sharedDocumentsRoot: true,
      );
      expect(r, isNull);
    });

    test(
        'BUG-1115: the same nested target is still rejected for a DEDICATED '
        'root (whole-tree move would swallow it)', () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot(p.join(oldDocs, 'Hibiki')),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        // 默认 false = Hibiki 专属根（<dataRoot>/documents），整树搬移语义。
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
    });

    test('BUG-1115: a whitelisted top-level dir is never an accepted target',
        () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target:
            DataRootMigrationTarget.customRoot(p.join(oldDocs, 'audiobooks')),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        sharedDocumentsRoot: true,
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
    });

    test('BUG-1115: the shared root itself is still a self-migrate rejection',
        () {
      final DataRootTargetRejection? r = validateDataRootTarget(
        target: DataRootMigrationTarget.customRoot(oldDocs),
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        existsAndHasFiles: alwaysEmpty,
        sharedDocumentsRoot: true,
      );
      expect(r, DataRootTargetRejection.insideCurrentRoot);
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
      // supportsRestart must be true (the data-root migration path gates on it
      // and still restarts on every platform), and restart must launch self +
      // exit, not be a no-op. NOTE (TODO-960): UI-language switching no longer
      // uses this restart path on desktop — it hot-reloads via setAppLocale's
      // isDesktopPlatform short-circuit (see locale_switch_no_restart_test.dart)
      // because the restart raced the Windows single-instance mutex and closed
      // the app. supportsRestart stays true regardless: data-root migration
      // still needs it, and mobile language switches still restart.
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
      // TODO-935：迁移前也释放图片缓存句柄（封面/缩略图解码），减少数据根文件锁。
      expect(src.contains('PaintingBinding.instance.imageCache'), isTrue);
      expect(src.contains('clearLiveImages()'), isTrue);
      // Writes the data_root pref via the canonical key.
      expect(src.contains('AppPaths.dataRootPrefKey'), isTrue);
      // Auto-restarts after a successful migration.
      expect(src.contains('restartApp()'), isTrue);
      // This entry is still experimental and must be labeled in-app.
      expect(src.contains('t.settings_experimental_suffix'), isTrue);
    });

    test(
        'data-root part: rejects install dir, safe rollback, prominent failure',
        () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart')
              .readAsStringSync();
      // TODO-1182：UI 把正在运行的 exe 路径喂给校验 + 迁移引擎（拒绝安装目录）。
      expect(
          src.contains('executablePath: Platform.resolvedExecutable'), isTrue);
      expect(
          src.contains('resolvedExecutablePath: Platform.resolvedExecutable'),
          isTrue);
      // 失败切到失败态遮罩（不再立刻重启导致用户看不到失败）。
      expect(src.contains('failDataRootMigration('), isTrue);
      // BUG-1115：共享根判定必须喂给**触发前校验**（而不是只喂给引擎），否则老安装选
      // `Documents\Hibiki` 会在进确认弹窗之前就被 insideCurrentRoot 拒掉。
      expect(src.contains('sharedDocumentsRoot: sharedDocumentsRoot'), isTrue);
    });

    test(
        'migrator engine: safe rollback + install-dir/exe rejection + lock class',
        () {
      final String src = readSource('lib/src/storage/data_root_migrator.dart')
          .readAsStringSync();
      // 回滚只删自建子树，绝不删用户选定的整个 newRoot。
      expect(src.contains('_cleanupCreatedSubtrees('), isTrue);
      expect(src.contains('_deleteIfPresent(newRoot)'), isFalse,
          reason: 'TODO-1182：回滚绝不删用户选定的整个 newRoot');
      // 引擎二次拒绝安装目录/exe 目录。
      expect(src.contains('resolvedExecutablePath'), isTrue);
      // 文件锁失败有明确「被占用」提示。
      expect(src.contains('_isFileInUseError('), isTrue);
      expect(src.contains('有文件被占用'), isTrue);
      // TODO-935：对 Windows 锁码做有界退避重试（吃瞬态 AV/索引器锁），跨盘 copy 校验
      // 完成后删源被锁则降级保留残留、不判失败（避免「整库已复制却回滚、位置没变」）。
      expect(src.contains('_withLockRetry('), isTrue);
      expect(src.contains('_deleteSourceAfterVerifiedCopy('), isTrue);
    });

    test('migration view renders a failure phase with reason + suggestions',
        () {
      final String src =
          readSource('lib/src/storage/data_root_migration_view.dart')
              .readAsStringSync();
      expect(src.contains('final String? failure'), isTrue);
      expect(src.contains('data_storage_migrate_failed_title'), isTrue);
      expect(src.contains('data_storage_migrate_failed_suggestions'), isTrue);
    });

    test('data-storage section is gated desktop-only', () {
      final String src = readSource('lib/src/sync/sync_settings_schema.dart')
          .readAsStringSync();
      expect(src.contains("id: 'sync.data_storage_location'"), isTrue);
      expect(src.contains('_DataRootWidget(settingsContext: ctx)'), isTrue);
      // The section + item both gate on isDesktopPlatform so mobile never sees
      // a control it cannot honor (sandbox-fixed roots).
      expect(
        src.contains('visible: (SettingsContext ctx) => isDesktopPlatform'),
        isTrue,
      );
    });

    test('TODO-1211: default location shows the real path, no prefix label',
        () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart')
              .readAsStringSync();
      // 未迁移（默认根）分支直接返回真实路径，仅 late 未初始化时才回退到标签。
      expect(
        src.contains(
            'return defaultRootPath ?? t.data_storage_location_default;'),
        isTrue,
      );
      // 不再拼「默认位置 - 路径」前缀（旧实现）。
      expect(
        src.contains(
            r"'${t.data_storage_location_default} - $defaultRootPath'"),
        isFalse,
        reason: 'TODO-1211：去掉「默认位置」前缀，直接显示实际路径',
      );
    });
  });
}
