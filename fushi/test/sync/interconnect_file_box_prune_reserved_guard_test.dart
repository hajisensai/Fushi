import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/auto_backup/cloud_backup_mirror.dart'
    show kCloudBackupNamespace;
import 'package:fushi/src/sync/font_sync.dart' show kSyncFontsNamespace;
import 'package:fushi/src/sync/settings_sync.dart' show kSyncSettingsNamespace;
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show
        isReservedSyncFolderName,
        kSyncCollectionsNamespace,
        kSyncDictionaryNamespace,
        kSyncLocalAudioNamespace,
        kSyncVideosNamespace;
import 'package:fushi_engine/anki_sync/pending_mine_relay.dart'
    show PendingMineRelay;
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/aggregate_sync_service.dart'
    show kSyncAggregateNamespace;
import 'package:fushi_engine/sync/deletion_propagation.dart'
    show kSyncTombstonesNamespace;
import 'package:fushi_engine/sync/sync_reserved_namespaces.dart';
import 'package:path/path.dart' as p;

// BUG-4991 / BUG-5007 守卫：互联 host 启动时收走已死的文件箱书文件夹，但同步根下的**保留命名空间**
// 是别的设备 / host 自己还在读的共享数据，一个都不能被当成书文件夹删掉。

/// 源码里声明的全部同步命名空间名（`const String k…Namespace = '…'` 与
/// `static const String namespace = '…'`）。
Set<String> _declaredNamespaces() {
  final RegExp decl = RegExp(
    r"const\s+String\s+(?:k\w*Namespace|namespace)\s*=\s*'([^']+)'",
  );
  final Set<String> names = <String>{};
  for (final String dir in <String>['lib', '../packages']) {
    for (final FileSystemEntity e in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String norm = e.path.replaceAll(r'\', '/');
      if (norm.contains('/test/') ||
          norm.contains('/.dart_tool/') ||
          norm.contains('/build/') ||
          norm.endsWith('.g.dart')) {
        continue;
      }
      for (final RegExpMatch m in decl.allMatches(e.readAsStringSync())) {
        names.add(m.group(1)!);
      }
    }
  }
  return names;
}

void main() {
  test('已知的每个保留命名空间都不会被 host 文件箱清理删掉', () {
    final List<String> known = <String>[
      kSyncDictionaryNamespace,
      kSyncLocalAudioNamespace,
      kSyncAggregateNamespace,
      kSyncCollectionsNamespace,
      kSyncVideosNamespace,
      kSyncTombstonesNamespace,
      kSyncFontsNamespace,
      kSyncSettingsNamespace,
      PendingMineRelay.namespace,
      kSrsSync2Namespace,
      kCloudBackupNamespace,
    ];
    for (final String name in known) {
      expect(isReservedSyncNamespaceName(name), isTrue, reason: name);
    }
  });

  test('源码里新声明的同步命名空间也必须落在保留判据里', () {
    final Set<String> declared = _declaredNamespaces();
    // 扫描本身要真的扫到东西，否则守卫形同虚设。
    expect(declared, containsAll(<String>['__pending_mines__', 'fushi-srs']));
    for (final String name in declared) {
      expect(
        isReservedSyncNamespaceName(name),
        isTrue,
        reason:
            '同步命名空间 `$name` 不在 isReservedSyncNamespaceName 里：'
            '互联 host 启动清理会把它当死书文件夹删掉。新命名空间请用 `__x__` 形状。',
      );
    }
  });

  test('客户端列书与 host 清理共用同一份保留判据（BUG-5007）', () {
    for (final String name in _declaredNamespaces()) {
      expect(isReservedSyncFolderName(name), isTrue, reason: name);
    }
  });

  test('两个 host 装配点都在绑端口前清理文件箱', () {
    for (final String path in <String>[
      'lib/src/sync/fushi_server_controller.dart',
      '../packages/fushi_server/lib/src/headless_host.dart',
    ]) {
      final String src = File(p.normalize(path)).readAsStringSync();
      final int prune = src.indexOf(
        'await pruneDeadInterconnectFileBox(server.syncDataDir);',
      );
      final int start = src.indexOf('await server.start();');
      expect(prune, isNonNegative, reason: path);
      expect(start, greaterThan(prune), reason: path);
    }
  });
}
