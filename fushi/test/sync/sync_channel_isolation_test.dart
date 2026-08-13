import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1604 守卫：双通道的**循环结构**不变式——「一条通道抛异常，其余通道照跑」。
///
/// UI 承诺「互联与云备份并存、互不干扰」。云通道恒排第一（见
/// [enabledSyncChannelBackends]），所以只要通道循环没有逐通道 try，云盘一坏（令牌
/// 失效 / WebDAV 不可达 / 裸 SocketException）就会终止整个 for，局域网互联通道这一
/// 轮根本不执行——用户看到的是弥散的「互联所有地方都有点问题」。
///
/// 这类缺陷只能用「第一条通道 throw、断言第二条仍被调用」来守，而真实通道来自六个
/// 后端工厂 + 全套编排依赖，单测层拉不起来。BUG-1552 当初因此把测试记成欠账，同一个
/// 结构缺陷于是在另外两条循环里原样存活。[debugSyncChannelsOverride] 就是补上的那个
/// 缝：注入假通道，四条循环从此都守得住。
///
/// **断言落在 `restoreAuth` 被调用与否上**：它是每条通道进入实际工作前的第一步，
/// 「第二条通道的 restoreAuth 有没有被调到」精确等价于「循环有没有被第一条通道的
/// 异常掐断」，且不需要拉起 orchestrator/SyncManager。第二条通道让
/// `isAuthenticated` 返回 false，循环体在构造编排器之前就 continue。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 假后端：记录 restoreAuth 是否被调用；[throwOnRestore] 时抛裸异常模拟
/// 「云盘不可达」。其余成员一律未实现——被碰到就是测试假设错了，直接炸。
class _ProbeBackend implements SyncBackend {
  _ProbeBackend({this.throwOnRestore = false});

  final bool throwOnRestore;
  bool restoreAuthCalled = false;

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    restoreAuthCalled = true;
    if (throwOnRestore) {
      // 裸 SocketException：审计里 WebDavOps 抛的就是它（不是 SyncBackendError），
      // 用它才能守住「任何异常都被隔离」而不是只守住某个自家异常类型。
      throw const SocketException('backend unreachable');
    }
    return true;
  }

  /// 第二条通道恒返回 false：循环体据此 continue，不必构造真编排器。
  @override
  Future<bool> get isAuthenticated async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

/// 造一对通道：云通道（会抛）+ 互联通道（应当仍被跑到）。
({_ProbeBackend cloud, _ProbeBackend interconnect}) _probePair() => (
      cloud: _ProbeBackend(throwOnRestore: true),
      interconnect: _ProbeBackend(),
    );

List<SyncChannel> _channels(
        ({_ProbeBackend cloud, _ProbeBackend interconnect}) p) =>
    <SyncChannel>[
      SyncChannel(p.cloud, type: SyncBackendType.webDav, isInterconnect: false),
      SyncChannel(p.interconnect,
          type: SyncBackendType.fushiServer, isInterconnect: true),
    ];

void main() {
  tearDown(() => debugSyncChannelsOverride = null);

  test('测试缝默认关闭：生产枚举不受影响', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    // 未设 override 时走真实枚举：只配了云备份默认值 → 至少解析出一条通道，
    // 且绝不是本测试的假后端。
    final List<SyncChannel> real = await enabledSyncChannelBackends(repo);
    expect(real, isNotEmpty);
    expect(real.first.backend, isNot(isA<_ProbeBackend>()));
  });

  group('BUG-1604 合集同步：云通道抛异常不得掐断互联通道', () {
    test('第一条通道 restoreAuth 抛 SocketException，第二条仍被跑到', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(true);

      final ({_ProbeBackend cloud, _ProbeBackend interconnect}) p =
          _probePair();
      debugSyncChannelsOverride = (SyncRepository _) async => _channels(p);

      await runCollectionsSyncNow(db: db);

      expect(p.cloud.restoreAuthCalled, isTrue, reason: '第一条通道本就该被跑到');
      expect(
        p.interconnect.restoreAuthCalled,
        isTrue,
        reason: '修复前：云通道的异常终止整个 for，互联通道这一轮根本不执行',
      );
    });

    test('自动同步关闭时一条通道都不跑（不误伤既有短路）', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(false);

      final ({_ProbeBackend cloud, _ProbeBackend interconnect}) p =
          _probePair();
      debugSyncChannelsOverride = (SyncRepository _) async => _channels(p);

      await runCollectionsSyncNow(db: db);

      expect(p.cloud.restoreAuthCalled, isFalse);
      expect(p.interconnect.restoreAuthCalled, isFalse);
    });
  });

  group('BUG-1604 退出书同步：云通道抛异常不得掐断互联通道', () {
    test('第一条通道 restoreAuth 抛 SocketException，第二条仍被跑到', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(true);
      // per-book 路径要先取到书，取不到会在进入通道循环前就以 nothingToSync 收尾。
      const String bookKey = 'bug1604book';
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'BUG-1604 fixture',
        epubPath: '/tmp/$bookKey/original.epub',
        extractDir: '/tmp/$bookKey',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ));

      final ({_ProbeBackend cloud, _ProbeBackend interconnect}) p =
          _probePair();
      debugSyncChannelsOverride = (SyncRepository _) async => _channels(p);

      // 前缀必须是 fushi://book/：入口用 `_bookKeyPattern` + parseBookKey 双重
      // 校验，别的前缀会在取书之前就 return，测试会假绿。
      await runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/$bookKey',
      );

      expect(p.cloud.restoreAuthCalled, isTrue, reason: '第一条通道本就该被跑到');
      expect(
        p.interconnect.restoreAuthCalled,
        isTrue,
        reason: '修复前：云通道的异常终止整个 for，互联通道的书进度整轮被跳过',
      );
    });
  });
}
