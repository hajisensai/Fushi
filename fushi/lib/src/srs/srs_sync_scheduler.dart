/// 复习（SRS）同步的调度：什么时候、用哪个后端跑一轮 [SrsSyncEngine]。
///
/// 三个触发点，都只在复习模块开着时存在（由 `srs_app_runtime.dart` 装配）：
/// 1. 常规同步每条通道成功后（`syncChannelPostRunHook`，与常规同步同一把互斥锁、同一个
///    已认证后端，云盘与互联都算）；
/// 2. 进入复习 tab 时（节流：距上次至少 [kSrsSyncMinInterval]）；
/// 3. 牌组列表「立即同步」/ AnkiConnect `sync` 动作（不节流）。
/// 2、3 除各条通道外还跑本机直接读写的目录（[SrsLocalDirectory]：本机作为互联 host 时
/// 客户端写进来的那块目录——host 自己不是任何一条通道的客户端）。
/// 4. 本机作为互联 host、已配对设备往 SRS 目录写了文件（[notifyLocalDirectoryWritten]，去抖
///    [kSrsHostWriteDebounce]）：只跑本机目录。host 自己经本机文件系统读写这块目录，不走互联，
///    所以它的同步不会再触发自己；客户端也不因 host 同步而被触发——没有循环。
///
/// 目录身份拿不到（云盘账户还没认出来）时这一轮跳过该后端（报告 error =
/// [kSrsSyncDirectoryIdentityUnavailable]），不把同一个目录当成新目录起步 / 重发。
///
/// 每条通道 / 目录各跑一轮引擎，进度按目录记（[SrsSyncEngine.directoryKey]，身份见
/// `srs_directory_key.dart`）：同一份本机数据同时经云盘与互联同步，每个目录都收到全部批次。
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

/// 后端所指同步目录的稳定身份暂时拿不到（例如云盘账户还没认出来）：这一轮不同步它。
const String kSrsSyncDirectoryIdentityUnavailable =
    'directory identity unavailable';

/// 已配对设备往本机 host 的 SRS 目录写入后，等这么久没有新写入再跑一次本机目录。
/// 一轮客户端同步会连写探针 / 批次 / cursor 几个文件，去抖把它们并成一次。
const Duration kSrsHostWriteDebounce = Duration(seconds: 3);

/// 一次 SRS 同步（测试注入假实现）。[directoryKey] 是 [backend] 所指同步目录的稳定身份。
typedef SrsSyncRunner =
    Future<SrsSyncReport> Function(
      SyncAssetStore backend,
      SrsDbStore store,
      String directoryKey,
    );

/// 生产实现：现有同步后端上的 SRS 目录 + 同步引擎跑一轮。
Future<SrsSyncReport> srsDefaultSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
  String directoryKey,
) => SrsSyncEngine(
  directory: SrsAssetStoreDirectory(
    store: backend,
    profileUid: store.profileUid,
  ),
  directoryKey: directoryKey,
  replica: store,
).syncOnce();

/// 本机直接读写的同步目录：本机作为互联 host 时，别的设备经互联写进来的就是这块目录，
/// 本机自己的复习数据也要在这里发布、从这里读别人的（它不是任何一条同步通道）。
class SrsLocalDirectory {
  const SrsLocalDirectory({required this.directoryKey, required this.store});

  final String directoryKey;
  final SyncAssetStore store;
}

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
    required Future<String?> Function(SyncAssetStore backend) directoryKeyOf,
    required void Function() onDataChanged,
    required void Function(SrsSyncNotice notice) onNotice,
    Future<List<SrsLocalDirectory>> Function()? localDirectories,
    SrsSyncRunner runner = srsDefaultSyncRunner,
    Future<Directory?> Function()? readMediaRoot,
    SrsMediaSyncRunner mediaRunner = srsDefaultMediaSyncRunner,
    DateTime Function()? clock,
    Duration hostWriteDebounce = kSrsHostWriteDebounce,
  }) : _hostWriteDebounce = hostWriteDebounce,
       _readMediaRoot = readMediaRoot,
       _mediaRunner = mediaRunner,
       _readStore = readStore,
       _channels = channels,
       _directoryKeyOf = directoryKeyOf,
       _localDirectories = localDirectories,
       _onDataChanged = onDataChanged,
       _onNotice = onNotice,
       _runner = runner,
       _clock = clock ?? DateTime.now;

  final Future<SrsDbStore?> Function() _readStore;
  final SrsChannelRunner _channels;
  final Future<String?> Function(SyncAssetStore backend) _directoryKeyOf;
  final Duration _hostWriteDebounce;
  Timer? _hostWriteTimer;

  /// 坏文件只记一次日志（每轮都会再跳过同一个文件）。
  final Set<String> _loggedSkipped = <String>{};
  final Future<List<SrsLocalDirectory>> Function()? _localDirectories;
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

  void dispose() {
    _disposed = true;
    _hostWriteTimer?.cancel();
    _hostWriteTimer = null;
  }

  /// 已配对设备往本机 host 的 SRS 目录写了文件：去抖后只跑本机目录（见文件头第 4 条）。
  void notifyLocalDirectoryWritten() {
    if (_disposed || _localDirectories == null) return;
    _hostWriteTimer?.cancel();
    _hostWriteTimer = Timer(_hostWriteDebounce, () {
      _hostWriteTimer = null;
      unawaited(syncLocalDirectories());
    });
  }

  /// 串行化：通道后置步骤（常规同步互斥锁里）、进复习 tab、「立即同步」、本机 host 目录可能同时触发，
  /// 而它们改的是同一份本机同步状态（同一个 SrsDbStore），一次只跑一个目录。
  Future<void> _tail = Future<void>.value();

  Future<T> _serially<T>(Future<T> Function() body) {
    final Future<T> run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 用一个已认证后端跑一轮（常规同步的通道后置步骤直接调它）。store 打不开时返回 null。
  /// [directoryKey] 缺省时按后端算（[directoryKeyOf]）。
  Future<SrsSyncReport?> syncWithBackend(
    SyncAssetStore backend, {
    String? directoryKey,
  }) => _serially(() => _syncWithBackend(backend, directoryKey));

  Future<SrsSyncReport?> _syncWithBackend(
    SyncAssetStore backend,
    String? directoryKey,
  ) async {
    if (_disposed) return null;
    final SrsDbStore? store = await _readStore();
    if (store == null || _disposed) return null;
    final String? key = directoryKey ?? await _directoryKeyOf(backend);
    if (key == null) {
      // 同一个物理目录换了个身份就会被当成新目录（重新起步、可能全量重发）：宁可这轮不同步。
      return SrsSyncReport()..error = kSrsSyncDirectoryIdentityUnavailable;
    }
    final SrsSyncReport report = await _runner(backend, store, key);
    for (final String f in report.skippedFiles) {
      if (_loggedSkipped.add('$key|$f')) {
        ErrorLogService.instance.log(
          'SrsSyncScheduler.skippedFile',
          StateError('SRS sync skipped a malformed file in $key: $f'),
          StackTrace.current,
        );
      }
    }
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

  /// 对所有已认证通道、以及本机直接读写的目录（本机作为互联 host 时）各跑一轮（不节流）。
  /// 返回跑过的目录数（0 = 没配置同步后端、本机也没开互联服务）。
  Future<int> syncNow() async {
    if (_disposed) return 0;
    final int ran = await _channels((SyncAssetStore backend) async {
      await syncWithBackend(backend);
    });
    return ran + await syncLocalDirectories();
  }

  /// 只跑本机直接读写的目录（本机作为互联 host 时）。返回跑过的目录数。
  Future<int> syncLocalDirectories() async {
    final Future<List<SrsLocalDirectory>> Function()? local = _localDirectories;
    if (local == null || _disposed) return 0;
    int ran = 0;
    for (final SrsLocalDirectory d in await local()) {
      try {
        await syncWithBackend(d.store, directoryKey: d.directoryKey);
        ran++;
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'SrsSyncScheduler.localDirectory',
          e,
          stack,
        );
      }
    }
    return ran;
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
