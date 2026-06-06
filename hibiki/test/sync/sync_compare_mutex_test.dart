import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// 一个只记录「远端列举是否发生」的最小 backend：远端为空，所以 [_load] 很快走完。
/// 只实现 compare 的 `_load` 真正会触达的读方法，其余成员经 [noSuchMethod] 兜底——
/// 它们一旦被调用就抛异常，等于断言「`_load` 不应触达它们」。
class _RecordingBackend implements SyncBackend {
  int listBooksCalls = 0;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    listBooksCalls++;
    return const <DriveFile>[];
  }

  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}

  @override
  String? get cachedRootFolderId => null;

  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};

  @override
  Future<String> ensureNamespace(String name) async => name;

  @override
  Future<List<AssetEntry>> listChildren(String id) async =>
      const <AssetEntry>[];

  @override
  Future<bool> get isAuthenticated async => true;

  // 其余 SyncBackend 成员不应被 compare 的 _load 触达：调用即失败。
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets(
      'compare load waits for an in-flight sync to release the shared mutex '
      '(BUG-083)', (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _RecordingBackend backend = _RecordingBackend();

    // 模拟一次正在跑的同步：持有全局同步互斥锁直到 gate 完成。
    final Completer<void> gate = Completer<void>();
    final Future<void> holder = runExclusiveWithSync(() => gate.future);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: backend),
          ),
        ),
      ),
    );

    // 让 initState→_load 跑到「取锁」处停住。同步还持锁，compare 绝不能去列举远端。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      backend.listBooksCalls,
      0,
      reason: '同步持锁期间，对比对话框不得并发列举远端（否则会抢连接打断同步）',
    );

    // 同步结束放锁后，compare 才继续拉取。
    gate.complete();
    await holder;
    await tester.pumpAndSettle();
    expect(
      backend.listBooksCalls,
      greaterThan(0),
      reason: '同步放锁后，对比对话框应当继续完成它的远端列举',
    );
  });
}
