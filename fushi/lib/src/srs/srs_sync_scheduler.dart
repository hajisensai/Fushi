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
///
/// 每个目录跑引擎之前先做 profile 关联（[SrsProfileLinker]，铁律 E）：profileUid 是每台设备
/// 本机随机生成的，不关联的话两台设备各写各的 `fushi-srs/<profileUid>/`，互联 / 云盘「同步成功」
/// 而复习数据从不互通。跑完再在本机写入者目录里发布 profile 说明文件（必须在引擎之后：引擎靠
/// 「本机写入者目录不见了」判断自己被当作退役设备清理过，先建目录会把这个信号盖掉）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi/utils.dart' show ErrorLogService;
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
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

/// 本机的 SRS 副本此刻打不开（模块关着 / 还在打开 / 调度器已卸下）：这一轮没同步。
const String kSrsSyncStoreUnavailable = 'srs store unavailable';

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
/// 返回跑成功的通道数与抛错通道的异常。
typedef SrsChannelRunner =
    Future<({int ran, List<Object> errors})> Function(
      Future<void> Function(SyncAssetStore backend) body,
    );

/// 一轮同步报告里带回的错误（[SrsSyncReport.error]）：引擎没抛异常，但这个目录这轮没同步成。
class SrsSyncReportError implements Exception {
  const SrsSyncReportError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「立即同步」的结果：[ran] = 同步成功的目录数，[errors] = 没同步成的目录各自的原因。
/// 两者都为空 = 没配置任何同步后端、本机也没开互联服务。
class SrsSyncNowResult {
  const SrsSyncNowResult({required this.ran, this.errors = const <Object>[]});

  final int ran;
  final List<Object> errors;

  bool get unconfigured => ran == 0 && errors.isEmpty;
}

/// 只提示一次的通知类别。
enum SrsSyncNotice {
  /// 当前同步后端拿不到服务器时间，复习数据没法同步。
  backendUnsupported,

  /// 系统时间与可信时间偏差超过 10 分钟。
  clockSkew,

  /// 同步目录里有另一台设备的同一个 profile，但两边都有用户笔记，没法自动关联
  /// （[SrsSyncScheduler.lastUnlinkedProfile] 是对方的 profile 名）。
  profileNotLinked,
}

class SrsSyncScheduler {
  SrsSyncScheduler({
    required Future<SrsDbStore?> Function() readStore,
    required SrsChannelRunner channels,
    required Future<String?> Function(SyncAssetStore backend) directoryKeyOf,
    required void Function() onDataChanged,
    required void Function(SrsSyncNotice notice) onNotice,
    Future<List<SrsLocalDirectory>> Function()? localDirectories,
    SrsProfileLinker? profileLinker,
    SrsSyncRunner runner = srsDefaultSyncRunner,
    Future<Directory?> Function()? readMediaRoot,
    SrsMediaSyncRunner mediaRunner = srsDefaultMediaSyncRunner,
    DateTime Function()? clock,
    Duration hostWriteDebounce = kSrsHostWriteDebounce,
    bool Function()? canRun,
  }) : _profileLinker = profileLinker,
       _canRun = canRun ?? _alwaysRun,
       _hostWriteDebounce = hostWriteDebounce,
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
  final SrsProfileLinker? _profileLinker;
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

  /// 最近一次 [SrsSyncNotice.profileNotLinked] 说的那个对方 profile 名。
  String? lastUnlinkedProfile;
  bool _disposed = false;

  /// 底层库此刻能不能用（app 侧 = 库已打开）。关库（备份恢复 / 数据根迁移 / 退出）
  /// 期间为 false：新一轮不开、在跑的一轮在下一个检查点收手；重开后自动恢复。
  final bool Function() _canRun;

  static bool _alwaysRun() => true;

  /// 调度器已卸下，或库正关着：这一轮不该开始 / 不该继续。
  bool get _halted => _disposed || !_canRun();

  /// 已经提示过的通知（测试读）。
  Set<SrsSyncNotice> get noticed => Set<SrsSyncNotice>.unmodifiable(_noticed);

  void dispose() {
    _disposed = true;
    _hostWriteTimer?.cancel();
    _hostWriteTimer = null;
  }

  /// 关库前调用：撤掉待触发的本机目录同步，等在跑（及已排队）的一轮结束。
  ///
  /// 调用方先让 [canRun] 变 false（app 侧先把库标成未初始化），排队中的轮次一进来就
  /// 收手；在跑的一轮在下一个检查点收手，并且它此刻还持着 store 独占区——关库若不等
  /// 它，就会在半截同步上把连接关掉（反馈 OMWOurRQKb 日志：`SrsDbStore._loadLocal`
  /// 「connection was closed」）。
  Future<void> quiesce() async {
    _hostWriteTimer?.cancel();
    _hostWriteTimer = null;
    await _tail;
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

  /// 用一个已认证后端跑一轮（常规同步的通道后置步骤直接调它）。store 打不开（或调度器已卸下）
  /// 时这一轮没跑，报告带 [kSrsSyncStoreUnavailable]——「立即同步」据此如实报未同步，不算成功。
  /// [directoryKey] 缺省时按后端算（[directoryKeyOf]）。
  Future<SrsSyncReport> syncWithBackend(
    SyncAssetStore backend, {
    String? directoryKey,
  }) => _serially(() => _syncWithBackend(backend, directoryKey));

  Future<SrsSyncReport> _syncWithBackend(
    SyncAssetStore backend,
    String? directoryKey,
  ) async {
    if (_halted) return SrsSyncReport()..error = kSrsSyncStoreUnavailable;
    SrsDbStore? store = await _readStore();
    if (store == null || _halted) {
      return SrsSyncReport()..error = kSrsSyncStoreUnavailable;
    }
    final String? key = directoryKey ?? await _directoryKeyOf(backend);
    if (key == null) {
      // 同一个物理目录换了个身份就会被当成新目录（重新起步、可能全量重发）：宁可这轮不同步。
      return SrsSyncReport()..error = kSrsSyncDirectoryIdentityUnavailable;
    }
    final SrsProfileLinker? linker = _profileLinker;
    bool adopted = false;
    if (linker != null) {
      final SrsProfileLinkOutcome link = await linker.link(backend, store);
      adopted = !identical(link.store, store);
      store = link.store;
      final String? unlinked = link.unlinkedProfileName;
      if (unlinked != null) {
        lastUnlinkedProfile = unlinked;
        _noticeOnce(SrsSyncNotice.profileNotLinked);
      }
      if (_halted) return SrsSyncReport()..error = kSrsSyncStoreUnavailable;
    }
    // 引擎在一轮开头写探针取服务器时间，整轮（上传 / 拉取 / 快照，大库能跑几十分钟）跑完才回来：
    // 校时按开跑那一刻的单调时钟算，误差只剩探针前的一次列目录，而不是整轮耗时。
    // 放在 profile 关联之后：关联可能换成另一个 store，校时落在真正跑同步的那个上。
    final int probedAtMono = store.trustedClock.monotonicNowMs();
    final SrsSyncReport report = await _runner(backend, store, key);
    if (linker != null && report.error == null && !_halted) {
      try {
        await linker.publish(backend, store, key);
      } catch (e, stack) {
        // 说明文件只用来让别的设备认出同一个 profile，写失败下一轮再写。
        ErrorLogService.instance.log('SrsSyncScheduler.profileInfo', e, stack);
      }
    }
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
      await store.anchorTime(serverTime, atMonotonicMs: probedAtMono);
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
    if (report.error == null && readMediaRoot != null && !_halted) {
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
    if (adopted ||
        report.applied > 0 ||
        report.published > 0 ||
        report.reincarnated ||
        mediaChanged) {
      _onDataChanged();
    }
    return report;
  }

  /// 对所有已认证通道、以及本机直接读写的目录（本机作为互联 host 时）各跑一轮（不节流）。
  /// 通道抛错与报告里带回错误的目录都记进 [SrsSyncNowResult.errors]，不算同步成功。
  Future<SrsSyncNowResult> syncNow() async {
    if (_halted) return const SrsSyncNowResult(ran: 0);
    int reportFailures = 0;
    final List<Object> errors = <Object>[];
    final ({int ran, List<Object> errors}) channels = await _channels((
      SyncAssetStore backend,
    ) async {
      final String? error = (await syncWithBackend(backend)).error;
      if (error != null) {
        reportFailures++;
        errors.add(SrsSyncReportError(error));
      }
    });
    errors.addAll(channels.errors);
    final SrsSyncNowResult local = await syncLocalDirectories();
    errors.addAll(local.errors);
    return SrsSyncNowResult(
      ran: channels.ran - reportFailures + local.ran,
      errors: errors,
    );
  }

  /// 只跑本机直接读写的目录（本机作为互联 host 时）。
  Future<SrsSyncNowResult> syncLocalDirectories() async {
    final Future<List<SrsLocalDirectory>> Function()? local = _localDirectories;
    if (local == null || _halted) return const SrsSyncNowResult(ran: 0);
    int ran = 0;
    final List<Object> errors = <Object>[];
    for (final SrsLocalDirectory d in await local()) {
      try {
        final String? error = (await syncWithBackend(
          d.store,
          directoryKey: d.directoryKey,
        )).error;
        if (error != null) {
          errors.add(SrsSyncReportError(error));
        } else {
          ran++;
        }
      } catch (e, stack) {
        errors.add(e);
        ErrorLogService.instance.log(
          'SrsSyncScheduler.localDirectory',
          e,
          stack,
        );
      }
    }
    return SrsSyncNowResult(ran: ran, errors: errors);
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
