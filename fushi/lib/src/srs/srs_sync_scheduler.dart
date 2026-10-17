/// 复习（SRS）同步的调度：什么时候、用哪个后端跑一轮 [SrsSyncEngine]。
///
/// 三个触发点，都只在复习模块开着时存在（由 `srs_app_runtime.dart` 装配）：
/// 1. 常规同步每条通道成功后（`syncChannelPostRunHook`，与常规同步同一把互斥锁、同一个
///    已认证后端，云盘与互联都算）；
/// 2. 进入复习 tab 时（节流：距上次至少 [kSrsSyncMinInterval]）；
/// 3. 牌组列表「立即同步」/ AnkiConnect `sync` 动作（不节流）。
///
/// 每轮成功拿到服务器时间后 `store.anchorTime(...)`（铁律 F 第一层校时）；后端拿不到
/// 服务器时间（报告 error = `server time unavailable`）时提示一次「当前同步后端不支持
/// 复习数据同步」；可信时间与墙钟偏差超过 10 分钟时提示一次「系统时间不准」。
/// 没配置任何同步后端时什么都不做。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi/utils.dart' show ErrorLogService;
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 两次「进入复习 tab」触发之间的最小间隔。
const Duration kSrsSyncMinInterval = Duration(seconds: 60);

/// 可信时间与系统时钟的偏差超过它就提示一次。
const int kSrsClockSkewWarnMs = 10 * 60 * 1000;

/// [SrsSyncEngine] 报告「后端拿不到服务器时间」时的错误串（fushi_srs 的契约）。
const String kSrsSyncServerTimeUnavailable = 'server time unavailable';

/// 一次 SRS 同步（测试注入假实现）。
typedef SrsSyncRunner =
    Future<SrsSyncReport> Function(SyncAssetStore backend, SrsDbStore store);

/// 生产实现：现有同步后端上的 SRS 目录 + 同步引擎跑一轮。
Future<SrsSyncReport> srsDefaultSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
) => SrsSyncEngine(
  directory: SrsAssetStoreDirectory(
    store: backend,
    profileUid: store.profileUid,
  ),
  replica: store,
).syncOnce();

/// 一轮媒体同步（测试注入假实现）。
typedef SrsMediaSyncRunner =
    Future<SrsMediaSyncReport> Function(
      SyncAssetStore backend,
      SrsDbStore store,
      Directory mediaRoot,
    );

/// 生产实现：见 packages/fushi_engine/lib/srs/srs_media_sync.dart。
Future<SrsMediaSyncReport> srsDefaultMediaSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
  Directory mediaRoot,
) => srsSyncMedia(backend: backend, store: store, mediaRoot: mediaRoot);

/// 「对所有已认证通道跑一次」的入口（生产：`runOnAuthenticatedSyncChannels`）。
typedef SrsChannelRunner =
    Future<int> Function(Future<void> Function(SyncAssetStore backend) body);

/// 只提示一次的通知类别。
enum SrsSyncNotice {
  /// 当前同步后端拿不到服务器时间，复习数据没法同步。
  backendUnsupported,

  /// 系统时间与可信时间偏差超过 10 分钟。
  clockSkew,
}

class SrsSyncScheduler {
  SrsSyncScheduler({
    required Future<SrsDbStore?> Function() readStore,
    required SrsChannelRunner channels,
    required void Function() onDataChanged,
    required void Function(SrsSyncNotice notice) onNotice,
    SrsSyncRunner runner = srsDefaultSyncRunner,
    Future<Directory?> Function()? readMediaRoot,
    SrsMediaSyncRunner mediaRunner = srsDefaultMediaSyncRunner,
    DateTime Function()? clock,
  }) : _readMediaRoot = readMediaRoot,
       _mediaRunner = mediaRunner,
       _readStore = readStore,
       _channels = channels,
       _onDataChanged = onDataChanged,
       _onNotice = onNotice,
       _runner = runner,
       _clock = clock ?? DateTime.now;

  final Future<SrsDbStore?> Function() _readStore;
  final SrsChannelRunner _channels;
  final void Function() _onDataChanged;
  final void Function(SrsSyncNotice notice) _onNotice;
  final SrsSyncRunner _runner;
  final Future<Directory?> Function()? _readMediaRoot;
  final SrsMediaSyncRunner _mediaRunner;
  final DateTime Function() _clock;

  final Set<SrsSyncNotice> _noticed = <SrsSyncNotice>{};
  DateTime? _lastThrottledAt;
  bool _disposed = false;

  /// 已经提示过的通知（测试读）。
  Set<SrsSyncNotice> get noticed => Set<SrsSyncNotice>.unmodifiable(_noticed);

  void dispose() => _disposed = true;

  /// 用一个已认证后端跑一轮（常规同步的通道后置步骤直接调它）。store 打不开时返回 null。
  Future<SrsSyncReport?> syncWithBackend(SyncAssetStore backend) async {
    if (_disposed) return null;
    final SrsDbStore? store = await _readStore();
    if (store == null || _disposed) return null;
    final SrsSyncReport report = await _runner(backend, store);
    final int? serverTime = report.serverTimeMs;
    if (serverTime != null) {
      await store.anchorTime(serverTime);
      final int? skew = store.trustedClock.wallSkewMs;
      if (skew != null && skew.abs() > kSrsClockSkewWarnMs) {
        _noticeOnce(SrsSyncNotice.clockSkew);
      }
    }
    if (report.error == kSrsSyncServerTimeUnavailable) {
      _noticeOnce(SrsSyncNotice.backendUnsupported);
    }
    bool mediaChanged = false;
    final Future<Directory?> Function()? readMediaRoot = _readMediaRoot;
    if (report.error == null && readMediaRoot != null && !_disposed) {
      // 媒体跟在事件之后：先拿到引用它们的笔记，再按内容哈希补齐两边缺的文件。
      // 媒体失败只记日志，不影响复习数据本身的同步结果。
      try {
        final Directory? root = await readMediaRoot();
        if (root != null) {
          final SrsMediaSyncReport media = await _mediaRunner(
            backend,
            store,
            root,
          );
          mediaChanged = media.downloaded > 0;
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsSyncScheduler.media', e, stack);
      }
    }
    if (report.applied > 0 ||
        report.published > 0 ||
        report.reincarnated ||
        mediaChanged) {
      _onDataChanged();
    }
    return report;
  }

  /// 对所有已认证通道各跑一轮（不节流）。返回跑过的通道数（0 = 没配置同步后端）。
  Future<int> syncNow() async {
    if (_disposed) return 0;
    return _channels((SyncAssetStore backend) async {
      await syncWithBackend(backend);
    });
  }

  /// 节流版（进入复习 tab）：距上一次节流触发不足 [kSrsSyncMinInterval] 时跳过，返回 false。
  Future<bool> syncThrottled() async {
    final DateTime now = _clock();
    final DateTime? last = _lastThrottledAt;
    if (last != null && now.difference(last) < kSrsSyncMinInterval) {
      return false;
    }
    _lastThrottledAt = now;
    await syncNow();
    return true;
  }

  void _noticeOnce(SrsSyncNotice notice) {
    if (_noticed.add(notice)) _onNotice(notice);
  }
}
