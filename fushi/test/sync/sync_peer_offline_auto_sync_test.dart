import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_task_board.dart' show resetSyncTasksForTest;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart'
    show LocalAudioPackageContents;

/// BUG-5368（反馈 AND29vti1l）守卫：互联对端离线是预期状态，自动同步路径不得把它
/// 记成失败；任务表里的失败文案必须是本地化的友好句子，不是原始异常。
///
/// 修复前：手机配了互联、电脑没开 Fushi，每次开机 / 定时 sweep 都在后台任务明细里
/// 多留一条「已结束，1 项失败」，内容是
/// `sync channel (interconnect=true): SyncBackendError: No reachable Fushi server address`，
/// 红点常亮。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 假后端：`restoreAuth` 抛给定异常（模拟对端离线 / 网络错误）。其余成员一律未
/// 实现——被碰到就是测试假设错了，直接炸。
class _ThrowingBackend implements SyncBackend {
  _ThrowingBackend(this.error);

  final Exception error;

  @override
  Future<bool> restoreAuth(SyncRepository repo) async => throw error;

  @override
  Future<bool> get isAuthenticated async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

SyncChannel _interconnectOffline() => SyncChannel(
  _ThrowingBackend(SyncPeerUnreachableError()),
  type: SyncBackendType.fushiServer,
  isInterconnect: true,
);

SyncChannel _cloudRefused() => SyncChannel(
  _ThrowingBackend(const SocketException('Connection refused')),
  type: SyncBackendType.webDav,
  isInterconnect: false,
);

List<String> _allTaskErrors() => <String>[
  for (final SyncTask task in syncTasks.value)
    for (final SyncTaskError e in task.errors) e.message,
];

void main() {
  late FushiDatabase db;
  late Directory work;

  setUp(() async {
    resetSyncTasksForTest();
    resetAutoSweepFailureBackoffForTest();
    lastSyncOutcome.value = null;
    db = _memDb();
    work = await Directory.systemTemp.createTemp('bug5368_');
    await SyncRepository(db).setAutoSyncEnabled(true);
  });

  tearDown(() async {
    debugSyncChannelsOverride = null;
    resetSyncTasksForTest();
    resetAutoSweepFailureBackoffForTest();
    await db.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  Future<void> sweep() => runAutoSyncAllForTest(
    db: db,
    dictionaryResourceRoot: work,
    audioDatabaseRoot: work,
    tempDir: work,
  );

  group('自动 sweep', () {
    test('只有互联且对端离线：结局 peerOffline，任务表不留失败项，仍推进退避', () async {
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        _interconnectOffline(),
      ];

      await sweep();

      expect(lastSyncOutcome.value!.reason, SyncOutcomeReason.peerOffline);
      expect(
        syncTasks.value,
        isEmpty,
        reason: '修复前：每轮都留一条「已结束，1 项失败」，后台任务红点常亮',
      );
      expect(
        autoSweepFailureBackoffUntilMsForTest,
        isNotNull,
        reason: '对端离线不算失败，但仍要退避，不能每分钟重付候选探测（BUG-1569①）',
      );
    });

    test('另一条通道真失败：结局 failed，失败项是本地化通道名 + 友好文案', () async {
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        _cloudRefused(),
        _interconnectOffline(),
      ];

      await sweep();

      expect(lastSyncOutcome.value!.reason, SyncOutcomeReason.failed);
      expect(_allTaskErrors(), <String>[
        '${t.sync_task_channel_cloud}: ${t.sync_err_network}',
      ], reason: '对端离线那条不进失败项；云通道的失败不再是原始异常拼接');
      for (final String message in _allTaskErrors()) {
        expect(message, isNot(contains('SocketException')));
        expect(message, isNot(contains('interconnect=')));
      }
    });
  });

  test('合集轻量同步：对端离线同样记 peerOffline、不留失败项', () async {
    debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
      _interconnectOffline(),
    ];

    await runCollectionsSyncNow(db: db);

    expect(lastSyncOutcome.value!.reason, SyncOutcomeReason.peerOffline);
    expect(syncTasks.value, isEmpty);
  });

  test('退出书同步：对端离线记 peerOffline、不留失败项', () async {
    const String bookKey = 'bug5368book';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'BUG-5368 fixture',
        epubPath: '/tmp/$bookKey/original.epub',
        extractDir: '/tmp/$bookKey',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ),
    );
    debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
      _interconnectOffline(),
    ];

    await runAutoSyncForBookForTest(
      db: db,
      mediaIdentifier: 'fushi://book/$bookKey',
    );

    expect(lastSyncOutcome.value!.reason, SyncOutcomeReason.peerOffline);
    expect(syncTasks.value, isEmpty);
  });

  test('手动「立即同步」：对端离线照常报给用户，但用友好文案', () async {
    debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
      _interconnectOffline(),
    ];

    await expectLater(
      runManualFullSync(
        db: db,
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
        localAudioEntries: const <LocalAudioDbEntry>[],
        onLocalAudioImported: (LocalAudioPackageContents _) async {},
      ),
      throwsA(isA<SyncPeerUnreachableError>()),
    );

    expect(lastSyncOutcome.value!.reason, SyncOutcomeReason.failed);
    expect(_allTaskErrors(), <String>[
      '${t.sync_task_channel_interconnect}: ${t.sync_err_peer_unreachable}',
    ], reason: '修复前是 `sync channel (interconnect=true): SyncBackendError: …`');
  });
}
