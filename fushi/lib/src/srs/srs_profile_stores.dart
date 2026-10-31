/// 反馈 biLEesNqWb：浏览器扩展选了**非激活**配置、而那份配置的挖词目标是 Fushi 复习时，卡要进
/// **那份配置**的复习（用户拍板「进到对应的复习才对吧」）。
///
/// 复习数据怎么按配置分：整台设备只有一个 `srs.db`，由一条 Rust 写连接持有（[SrsStorage]：
/// `db` 是这条连接上的 drift 视图，`core` 是同一连接的内核句柄）；各配置的行按 `profiles.uid`
/// （`profile_uid` 列）分区，本机状态（HLC / 写入者序号 / 同步 v2 发件序号 / 设备身份）也按 uid
/// 存在 `srs_local_state` 里。[SrsDbStore] 只是「某个 uid 的副本」：同一个 db / core 上按 uid
/// 读写的对象。所以给别的配置制卡**不开第二个库**，而是在同一个句柄上为那个 uid 开一份副本
/// （与删配置时的级联清理 `srs_profile_cleanup.dart` 同一做法）。
///
/// 并发规则（两条都由本类保证）：
/// 1. **同一个 uid 同一时刻只有一份活副本**：副本把 HLC / 序号缓存在内存里，两份副本各自分配
///    序号会撞号。App 把某个配置切成激活时（`srsStoreProvider` 经 [activate] 打开它），先把这个
///    uid 的扩展副本作废（[SrsDbStore.retire]：排在它已排队的写入之后），再把**旧激活副本**排空并
///    作废、在它最后一段独占区里打开新激活副本（交接，[_handOver]）。旧激活副本作废后，之后为它的 uid
///    来的扩展请求开的是新的扩展副本，读到的是旧副本写完之后的本机状态；旧副本若还活着，两份副本会
///    各自分配 HLC / 写入者序号，在 `sync2_ops` 里撞号。激活 / 交接过程中来的请求等它做完：同 uid 的
///    直接用新激活副本，别的 uid（包括正被交出去的旧激活 uid）等交接完再取副本 / 进外层锁。
/// 2. **扩展副本的写入不插进激活副本的事务**：激活副本的数据库事务跨多个 await，扩展副本的独占区
///    套在激活副本的独占区里（[SrsExclusiveOuter]），整段排在它后面。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show FsrsEngine;

import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';

/// [SrsProfileStores] 的依赖（测试注入真实存储）。
class SrsProfileStoresDeps {
  const SrsProfileStoresDeps({
    required this.storage,
    required this.deviceId,
    required this.supportRoot,
    required this.engine,
  });

  /// 本机 srs.db；复习模块关着时为 null。
  final Future<SrsStorage?> Function() storage;

  final Future<String> Function() deviceId;

  /// `srs_media` / 释义样式所在的支持目录。
  final Future<Directory> Function() supportRoot;

  /// FSRS 排程内核（原生库不可用时为 null）。
  final FsrsEngine? Function() engine;
}

/// 各配置的复习副本：App 激活配置的那份（由 `srsStoreProvider` 经 [activate] 交进来）+ 浏览器扩展
/// 按所选配置用到的别的配置的副本（按 uid 缓存）。见文件头。
class SrsProfileStores {
  SrsProfileStores(this._deps);

  final SrsProfileStoresDeps _deps;

  /// App 激活配置的副本。切配置时保留旧的那份直到交接完成（[_handOver]：它已排队的写入写完、
  /// 新副本在它最后一段独占区里打开、随后它作废）。
  SrsDbStore? _active;

  /// 最近一次发起的激活：uid、打开结果、做完（成败都算，只会正常完成）的信号。激活期间来的同 uid
  /// 请求等打开结果，别的 uid 等它做完（见 [storeFor]）。
  ({String uid, Future<SrsDbStore> store, Future<void> settled})? _activating;

  /// 激活 / 卸下激活副本串行进行：每一次等前一次做完。
  Future<void> _switchTail = Future<void>.value();

  /// 交接激活副本期间（[_handOver]）非 null，交接做完时完成；期间来的扩展写入等它，再排进新激活副本。
  Future<void>? _handoff;

  /// 扩展副本（uid → 打开中 / 已打开）。
  final Map<String, Future<SrsDbStore>> _foreign =
      <String, Future<SrsDbStore>>{};

  /// 扩展副本的回退日界（每次取副本时按那份配置的设置更新）。
  final Map<String, int Function()> _rollover = <String, int Function()>{};

  late final SrsExclusiveOuter _outer = _ActiveStoreOuter(this);

  /// 在激活副本的独占区里跑 [body]。还没有激活副本、或它已作废（不会再写这条连接）时直接跑。
  ///
  /// 已在激活副本独占区里（重入，例如交接时在旧激活副本最后一段独占区里打开新副本）直接跑；交接
  /// 进行中则先等交接做完——交接排在旧激活副本已排队写入之后、并在最后作废它，此时再排进旧副本的
  /// 锁只会在它作废后失败。
  Future<T> _underActive<T>(Future<T> Function() body) async {
    final SrsDbStore? current = _active;
    if (current != null && current.holdsExclusive) return body();
    for (Future<void>? h = _handoff; h != null; h = _handoff) {
      await h;
    }
    final SrsDbStore? active = _active;
    return active == null || !active.isUsable
        ? body()
        : active.runExclusive(body);
  }

  /// 串行跑一次激活 / 卸下（等前一次做完）。
  Future<T> _serialSwitch<T>(Future<T> Function() body) {
    final Future<void> before = _switchTail;
    final Completer<void> done = Completer<void>();
    _switchTail = done.future;
    return () async {
      try {
        await before;
        return await body();
      } finally {
        done.complete();
      }
    }();
  }

  /// 把激活副本换成 [next] 打开的那份（null = 不再有激活副本）。
  ///
  /// 旧激活副本还能写时：[next] 作为它的 [SrsDbStore.retire] 体跑——排在它已排队的写入（以及套在它
  /// 外层锁里的扩展副本写入）之后，新副本的打开写这条连接也不与它们交错；跑完旧副本作废，之后再用它
  /// 的写入明确失败，不会在过期的 HLC / 序号上与这个 uid 的新副本各写各的。[next] 失败旧副本同样作废、
  /// 不再有激活副本（下次激活重开）。交接期间来的扩展写入等交接做完（[_underActive]）。
  Future<SrsDbStore?> _handOver(Future<SrsDbStore?> Function() next) async {
    final SrsDbStore? previous = _active;
    final Completer<void> handoff = Completer<void>();
    _handoff = handoff.future;
    SrsDbStore? store;
    try {
      store = previous != null && previous.isUsable
          ? await previous.retire(
              next,
              reason:
                  'profile ${previous.profileUid} is no longer the active '
                  'SRS profile',
            )
          : await next();
      return store;
    } finally {
      _active = store;
      _handoff = null;
      handoff.complete();
    }
  }

  /// `srsStoreProvider` 打开激活副本：先作废同 uid 的扩展副本，再交接（[_handOver]：旧激活副本
  /// 排空作废、在它最后一段独占区里 [open]）。激活完成前来的同 uid 请求等它、直接用它；别的 uid 等它
  /// 做完（见 [storeFor]）。
  Future<SrsDbStore> activate(
    String profileUid,
    Future<SrsDbStore> Function() open,
  ) {
    final Completer<void> settled = Completer<void>();
    late final ({String uid, Future<SrsDbStore> store, Future<void> settled})
    marker;
    final Future<SrsDbStore> opening = _serialSwitch(() async {
      try {
        await release(profileUid);
        return (await _handOver(open))!;
      } finally {
        if (identical(_activating, marker)) _activating = null;
        settled.complete();
      }
    });
    marker = (uid: profileUid, store: opening, settled: settled.future);
    _activating = marker;
    return opening;
  }

  /// 复习模块关掉（srs.db 不再开放）：作废全部扩展副本，再排空并作废激活副本。
  Future<void> releaseAll() => _serialSwitch(() async {
    for (final String uid in _foreign.keys.toList()) {
      await release(uid);
    }
    await _handOver(() async => null);
  });

  /// 作废 [profileUid] 的扩展副本（没有就什么都不做）：它已排队的写入照常写完，之后再用它的
  /// 写入报错。App 激活这个配置、或删这个配置的复习数据之前调用。
  Future<void> release(String profileUid) async {
    final Future<SrsDbStore>? pending = _foreign.remove(profileUid);
    _rollover.remove(profileUid);
    if (pending == null) return;
    final SrsDbStore store;
    try {
      store = await pending;
    } on Object {
      // 打开就失败了：没有副本可作废（失败已报给打开它的那次请求）。
      return;
    }
    await store.retire(
      () async {},
      reason: 'profile $profileUid is now handled by another store',
    );
  }

  /// [profileUid] 这份配置的制卡器（制卡 / 查重 / 同词反查 / 打开笔记都走它）。
  ///
  /// 就是 App 激活配置时用激活副本；否则用（必要时打开）这个 uid 的扩展副本。复习模块关着时
  /// 为 null。[fallbackRolloverHour] 是那份配置的统计日界（副本的「今天」在没有同步来的翻日时刻时
  /// 用它）。
  Future<SrsMiner?> minerFor({
    required String profileUid,
    required SrsMiningDestination destination,
    required int Function() fallbackRolloverHour,
  }) async {
    final SrsDbStore? store = await storeFor(
      profileUid,
      fallbackRolloverHour: fallbackRolloverHour,
    );
    if (store == null) return null;
    final Directory support = await _deps.supportRoot();
    return SrsMiner(
      store: store,
      media: SrsMediaStore(SrsMediaStore.directoryFor(support, profileUid)),
      destination: destination,
    );
  }

  /// [profileUid] 的副本（见 [minerFor]）；复习模块关着时为 null。
  Future<SrsDbStore?> storeFor(
    String profileUid, {
    required int Function() fallbackRolloverHour,
  }) async {
    final SrsStorage? storage = await _deps.storage();
    if (storage == null) return null;
    // 有激活在进行：同 uid 的直接等它打开的激活副本；别的 uid 等它做完再看——此刻的激活副本可能
    // 正被交出去（排空后作废），这个 uid 也可能正是它，交接完要开的是新的扩展副本。
    for (
      ({String uid, Future<SrsDbStore> store, Future<void> settled})?
      activating = _activating;
      activating != null;
      activating = _activating
    ) {
      if (activating.uid == profileUid) return activating.store;
      await activating.settled;
    }
    // 以下到登记 _foreign 都是同步的：不会有新的激活插进来。
    final SrsDbStore? active = _active;
    if (active != null && active.isUsable && active.profileUid == profileUid) {
      return active;
    }
    _rollover[profileUid] = fallbackRolloverHour;
    final Future<SrsDbStore> opening = _foreign[profileUid] ??= _openForeign(
      storage,
      profileUid,
    );
    try {
      return await opening;
    } on Object {
      if (identical(_foreign[profileUid], opening)) {
        _foreign.remove(profileUid);
      }
      rethrow;
    }
  }

  Future<SrsDbStore> _openForeign(SrsStorage storage, String profileUid) async {
    final String deviceId = await _deps.deviceId();
    final Directory support = await _deps.supportRoot();
    // 打开本身（读本机状态、首次初始化）也在激活副本的独占区里：它同样写这条连接。
    return _underActive(
      () => SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: profileUid,
        deviceId: deviceId,
        engine: _deps.engine(),
        fallbackRolloverHour: () =>
            (_rollover[profileUid] ?? _defaultRollover)(),
        styles: SrsStyleStore(SrsStyleStore.directoryFor(support, profileUid)),
        exclusiveOuter: _outer,
      ),
    );
  }

  static int _defaultRollover() => 0;
}

/// 扩展副本的外层锁 = 此刻 App 激活副本的独占区（随激活配置变）。
class _ActiveStoreOuter implements SrsExclusiveOuter {
  _ActiveStoreOuter(this._owner);

  final SrsProfileStores _owner;

  @override
  Future<T> run<T>(Future<T> Function() body) => _owner._underActive(body);
}
