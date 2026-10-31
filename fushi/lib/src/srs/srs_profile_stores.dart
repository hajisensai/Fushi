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
///    uid 的扩展副本作废（[SrsDbStore.retire]：排在它已排队的写入之后），再打开激活副本；激活过程
///    中来的扩展请求等激活完成后直接用激活副本。
/// 2. **扩展副本的写入不插进激活副本的事务**：激活副本的数据库事务跨多个 await，扩展副本的独占区
///    套在激活副本的独占区里（[SrsExclusiveOuter]），整段排在它后面。
library;

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

  /// App 激活配置的副本。切配置时保留旧的那份直到新的打开（旧副本可能还有进行中的写入，
  /// 扩展副本的写入照样排在它后面）。
  SrsDbStore? _active;

  /// 正在激活的 uid 与它的打开结果（激活期间来的同 uid 请求等它）。
  ({String uid, Future<SrsDbStore> store})? _activating;

  /// 扩展副本（uid → 打开中 / 已打开）。
  final Map<String, Future<SrsDbStore>> _foreign =
      <String, Future<SrsDbStore>>{};

  /// 扩展副本的回退日界（每次取副本时按那份配置的设置更新）。
  final Map<String, int Function()> _rollover = <String, int Function()>{};

  late final SrsExclusiveOuter _outer = _ActiveStoreOuter(this);

  /// 在激活副本的独占区里跑 [body]。还没有激活副本、或它已作废（不会再写这条连接）时直接跑。
  Future<T> _underActive<T>(Future<T> Function() body) {
    final SrsDbStore? active = _active;
    return active == null || !active.isUsable
        ? body()
        : active.runExclusive(body);
  }

  /// `srsStoreProvider` 打开激活副本：先作废同 uid 的扩展副本，再 [open]。激活完成前来的同 uid
  /// 请求等它、直接用它（见 [storeFor]）。
  Future<SrsDbStore> activate(
    String profileUid,
    Future<SrsDbStore> Function() open,
  ) {
    late final ({String uid, Future<SrsDbStore> store}) marker;
    final Future<SrsDbStore> opening = () async {
      try {
        await release(profileUid);
        // 新激活副本的打开同样写这条连接：排在旧激活副本（以及套在它里面的扩展副本）的写入后面。
        final SrsDbStore store = await _underActive(open);
        _active = store;
        return store;
      } finally {
        if (identical(_activating, marker)) _activating = null;
      }
    }();
    marker = (uid: profileUid, store: opening);
    _activating = marker;
    return opening;
  }

  /// 复习模块关掉（srs.db 不再开放）：作废全部扩展副本，忘掉激活副本。
  Future<void> releaseAll() async {
    _active = null;
    for (final String uid in _foreign.keys.toList()) {
      await release(uid);
    }
  }

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
    final ({String uid, Future<SrsDbStore> store})? activating = _activating;
    if (activating != null && activating.uid == profileUid) {
      return activating.store;
    }
    final SrsDbStore? active = _active;
    if (active != null && active.profileUid == profileUid) return active;
    _rollover[profileUid] = fallbackRolloverHour;
    final Future<SrsDbStore>? cached = _foreign[profileUid];
    if (cached != null) return cached;
    final SrsStorage? storage = await _deps.storage();
    if (storage == null) return null;
    // await 之后重新查一遍：等存储的工夫里别的请求可能已经开了 / 正在激活。
    final ({String uid, Future<SrsDbStore> store})? nowActivating = _activating;
    if (nowActivating != null && nowActivating.uid == profileUid) {
      return nowActivating.store;
    }
    final SrsDbStore? nowActive = _active;
    if (nowActive != null && nowActive.profileUid == profileUid) {
      return nowActive;
    }
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
