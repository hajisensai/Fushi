import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/subscription_check_schedule.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_download_subscription_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';

/// 周三 15:00 UTC——历史发布点。
final DateTime kRelease = DateTime.utc(2026, 9, 2, 15);

const SubscriptionCheckCadence kCadence = SubscriptionCheckCadence();

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<int> _insertVideoSource(FushiDatabase database) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: r'D:\Videos',
        createdAt: 1000,
      ),
    );

Future<void> _insertSubscription(
  FushiDatabase database, {
  required String id,
  required int sourceId,
  String mode = 'ongoing',
  bool enabled = true,
  int? nextCheckAt = 1000,
}) =>
    database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: id,
        resourceProvider: 'torznab:indexer-a',
        metadataProvider: const Value<String?>('anilist'),
        externalId: Value<String?>('media-$id'),
        mediaKind: 'tv',
        discoveryCategory: const Value<String?>('anime'),
        title: 'Example Show',
        season: const Value<int?>(1),
        searchQuery: 'Example Show',
        filterJson: Value<String>(
          jsonEncode(<String, Object?>{'strict': true, 'quality': '1080p'}),
        ),
        mode: Value<String>(mode),
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        enabled: Value<bool>(enabled),
        createdAt: 1000,
        updatedAt: 1000,
        nextCheckAt: Value<int?>(nextCheckAt),
      ),
    );

/// 预置若干「每周同一时刻发布」的历史条目。
Future<void> _insertWeeklyHistory(
  FushiDatabase database,
  String subscriptionId, {
  int weeks = 3,
}) async {
  for (int i = 0; i < weeks; i++) {
    final DateTime at = kRelease.subtract(Duration(days: 7 * i));
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: subscriptionId,
        logicalItemKey: 's1e${10 - i}',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: 'release-$i',
        title: 'Example Show - ${10 - i}',
        season: const Value<int?>(1),
        episode: Value<int?>(10 - i),
        publishedAt: Value<int?>(at.millisecondsSinceEpoch),
        discoveredAt: at.millisecondsSinceEpoch,
        updatedAt: at.millisecondsSinceEpoch,
      ),
    );
  }
}

/// [now] 为 null 时用真实时钟。断言 nextCheckAt 具体取值的用例要注入固定时刻；
/// 断言**定时器真的会再醒**的用例必须走真实时钟——固定时钟下 nextCheckAt 恒
/// 落在「未来」，claim 永远领不走，drain 只会空转，测不出活性。
VideoDownloadSubscriptionService _service(
  FushiDatabase database, {
  DateTime? now,
  SubscriptionCheckCadence? cadence,
  _EmptyResourceProvider? provider,
}) {
  final VideoDownloadSubscriptionService service =
      VideoDownloadSubscriptionService(
    database: database,
    resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[
      provider ?? _EmptyResourceProvider(),
    ]),
    // 本套件断言的是「下一次什么时候查」，不是入队；provider 恒返空候选，
    // 检查必定成功且不命中，nextCheckAt 就只由历史样本决定。
    enqueue: (VideoDownloadEnqueueRequest request) async =>
        fail('no candidate should be enqueued'),
    workerId: 'cadence-test-worker',
    cadence: cadence,
    now: now == null ? null : () => now,
  );
  addTearDown(service.dispose);
  return service;
}

/// 唤醒计数探针。
///
/// 服务不暴露 `_timer`，而两条唤醒 clamp 生效的场景里库里一行都领不走
/// （`_EmptyResourceProvider.searchCount` 恒为 0），唯一可观测的就是定时器回调
/// 本身。定时器回调只有 `checkNow` 一个入口，覆写它就能数出真实排程节奏。
class _WakeCountingService extends VideoDownloadSubscriptionService {
  _WakeCountingService({
    required super.database,
    required super.resourceRegistry,
    required super.enqueue,
    required super.cadence,
    required super.now,
    super.workerId,
  });

  int wakeCount = 0;

  @override
  Future<void> checkNow() {
    wakeCount++;
    return super.checkNow();
  }
}

/// 冻结时钟 + 一条领不走的订阅：每一轮重排算出的 delay 都是同一个常数，
/// 断言排程节奏才是确定的（定时器只会晚不会早，上界因此可判）。
_WakeCountingService _countingService(
  FushiDatabase database, {
  required DateTime now,
  required SubscriptionCheckCadence cadence,
}) {
  final _WakeCountingService service = _WakeCountingService(
    database: database,
    resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[
      _EmptyResourceProvider(),
    ]),
    enqueue: (VideoDownloadEnqueueRequest request) async =>
        fail('no candidate should be enqueued'),
    workerId: 'clamp-test-worker',
    cadence: cadence,
    now: () => now,
  );
  addTearDown(service.dispose);
  return service;
}

/// 定时器行为用的压缩节奏：真等毫秒级，不改变任何分支逻辑。
///
/// 取值刻意不再更小。同目录下有几条时间敏感的既有用例（例如 90ms lease 的
/// 心跳续期），本组测试若用几毫秒的定时器 + 忙等轮询去抢 CPU，会把它们挤红——
/// 那是本组测试制造的干扰，不是那些用例的问题。
const SubscriptionCheckCadence kFastCadence = SubscriptionCheckCadence(
  baseInterval: Duration(milliseconds: 200),
  hotInterval: Duration(milliseconds: 100),
  coldInterval: Duration(milliseconds: 300),
  minInterval: Duration(milliseconds: 20),
);

/// 轮询等待 [predicate] 成立，最多等 [timeout]；返回是否等到。
Future<bool> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    // 轮询间隔要够大：忙等会和同机并行的时间敏感用例抢 CPU。
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return predicate();
}

/// 断言取样这条路本身是通的，返回样本条数。
///
/// 三条「退回均匀间隔」的用例若只看 nextCheckAt，与「取样恒抛异常被降级吞掉」
/// 完全同形——必须先确认样本确实取到了预期条数，退回才是因为样本不足而不是
/// 因为这条路断了。
Future<int> _expectSampleCount(
  FushiDatabase database,
  String subscriptionId,
  int expected,
) async {
  final List<int> samples =
      await database.getVideoDownloadSubscriptionPublishedAt(subscriptionId);
  expect(samples.length, expected, reason: '取样路径本身应当是通的');
  return samples.length;
}

Future<int?> _checkAndReadNextCheckAt(
  FushiDatabase database,
  String subscriptionId, {
  required DateTime now,
}) async {
  await _service(database, now: now).checkNow();
  final VideoDownloadSubscriptionRow row =
      (await database.getVideoDownloadSubscription(subscriptionId))!;
  expect(row.lastCheckedAt, now.millisecondsSinceEpoch, reason: '这一轮检查应当真的跑到了');
  // 失败路径首次退避同样是 15 分钟，与「退回均匀间隔」肉眼无法区分——必须显式
  // 排除，否则一条抛异常的检查会被读成「节奏退化」而悄悄通过。
  expect(row.lastError, isNull, reason: '这一轮检查不该失败');
  expect(row.retryCount, 0);
  return row.nextCheckAt;
}

void main() {
  group('订阅检查节奏落到 nextCheckAt', () {
    test('连载订阅在冷窗里睡满冷窗封顶，而不是固定 15 分钟', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      // 预测点之后 3 天：深在冷窗里。
      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'weekly',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.coldInterval.inMilliseconds,
      );
    });

    test('连载订阅在热窗里加密到 5 分钟', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      // 预测点后 1 小时：字幕组滞后余温里。
      final DateTime now = kRelease.add(const Duration(hours: 1));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'weekly',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.hotInterval.inMilliseconds,
      );
    });

    test('历史样本不足时退回 15 分钟均匀间隔', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'fresh', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'fresh', weeks: 2);
      await _expectSampleCount(database, 'fresh', 2);

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'fresh',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });

    test('oneShot 订阅没有周期语义，始终用均匀间隔', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'once',
        sourceId: sourceId,
        mode: 'oneShot',
      );
      // 即便历史看着很像每周更新，一次性订阅也不该据此改节奏。
      await _insertWeeklyHistory(database, 'once');
      await _expectSampleCount(database, 'once', 3);

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'once',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });

    test('缺 publishedAt 的历史条目不参与相位判定', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'partial', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'partial', weeks: 2);
      // 第三条没有发布时刻（provider 没给 pubDate），样本仍然只有两条。
      await database.upsertVideoDownloadSubscriptionItem(
        VideoDownloadSubscriptionItemsCompanion.insert(
          subscriptionId: 'partial',
          logicalItemKey: 's1e7',
          resourceProvider: 'torznab:indexer-a',
          selectedResourceId: 'release-nodate',
          title: 'Example Show - 7',
          season: const Value<int?>(1),
          episode: const Value<int?>(7),
          discoveredAt: kRelease.millisecondsSinceEpoch,
          updatedAt: kRelease.millisecondsSinceEpoch,
        ),
      );
      await _expectSampleCount(database, 'partial', 2);

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'partial',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });
  });

  group('调度器活性（单次 Timer 重排）', () {
    test('一轮检查之后会自己再醒，不需要外部推动', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      final _EmptyResourceProvider provider = _EmptyResourceProvider();
      final VideoDownloadSubscriptionService service = _service(
        database,
        cadence: kFastCadence,
        provider: provider,
      );

      service.start();
      // 旧实现是 Timer.periodic，无条件保证还会再醒；新实现靠自己重排。
      expect(
        await _waitFor(() => provider.searchCount >= 3),
        isTrue,
        reason: '调度器只跑了 ${provider.searchCount} 轮就不动了',
      );
    });

    test('零启用订阅时仍留兜底唤醒，之后新建订阅能被自动捡起', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      final _EmptyResourceProvider provider = _EmptyResourceProvider();
      final VideoDownloadSubscriptionService service = _service(
        database,
        cadence: kFastCadence,
        provider: provider,
      );

      // 启动时库里一条订阅都没有。
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(provider.searchCount, 0);

      // 此后新建订阅，**不调用 checkNow**：若零订阅时没排兜底唤醒，调度器已经
      // 永久睡死，这一条永远不会被检查。
      await _insertSubscription(database, id: 'later', sourceId: sourceId);
      expect(
        await _waitFor(() => provider.searchCount >= 1),
        isTrue,
        reason: '零订阅时没有留下兜底唤醒，新建的订阅再也没人检查',
      );
    });

    test('stop() 之后不再自己醒来', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      final _EmptyResourceProvider provider = _EmptyResourceProvider();
      final VideoDownloadSubscriptionService service = _service(
        database,
        cadence: kFastCadence,
        provider: provider,
      );

      // 关键是让 stop() 落在**一轮重排正在途中**的时刻：start() 发起的检查还没
      // 结束就调 stop()，stop() 内部 await 这一轮时，whenComplete 会发起重排并
      // 挂在 DB 读上——它从 await 恢复已经是 stop() 返回之后。只取消定时器停不住
      // 它，必须有个标志让恢复后的重排自己放弃。
      service.start();
      await service.stop();
      final int afterStop = provider.searchCount;

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        provider.searchCount,
        afterStop,
        reason: 'stop() 之后调度器又自己醒了',
      );
    });

    test('下一次到期近在眼前时，唤醒不会快过热窗（下界 clamp）', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      final DateTime frozen = kRelease;
      final int at = frozen.millisecondsSinceEpoch;
      await _insertSubscription(
        database,
        id: 'held',
        sourceId: sourceId,
        nextCheckAt: at - 1000,
      );
      // 别的 worker 正占着这一行，租约还差 1ms 到期：行早就到期了，本 worker
      // 却领不走。这正是唤醒下限那条注释说的「已到期但领不走」，dueAt 恒等于
      // 租约到期时刻，算出来的 delay 恒为 1ms。
      expect(
        await database.claimNextVideoDownloadSubscription(
          workerId: 'other-worker',
          nowAt: at - 999,
          leaseDurationMs: 1000,
        ),
        isNotNull,
      );
      expect(
        await database.nextVideoDownloadSubscriptionDueAt(),
        at + 1,
        reason: '喂给唤醒下限的 delay 必须真的是 1ms，否则这条用例测的不是 clamp',
      );

      final _WakeCountingService service = _countingService(
        database,
        now: frozen,
        cadence: kFastCadence,
      );
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // 时钟冻结 + 领不走：每一轮重排读到的都是同一个 1ms，库里没有任何写入
      // 能让它自己收敛。定时器只会晚不会早，所以上界是确定的——start() 那一次
      // 加上 600ms 里最多 6 个 hotInterval(100ms)。去掉下限 clamp 就是每毫秒
      // 重排一轮的空转。
      expect(
        service.wakeCount,
        greaterThanOrEqualTo(2),
        reason: '调度器压根没再醒过，这一轮没观测到任何排程',
      );
      expect(
        service.wakeCount,
        lessThanOrEqualTo(12),
        reason: '唤醒快过热窗：600ms 里醒了 ${service.wakeCount} 次，等于空转',
      );
    });

    test('下一次到期远在未来时，冷窗仍兜底探测（上界 clamp）', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      final DateTime frozen = kRelease;
      final int at = frozen.millisecondsSinceEpoch;
      await _insertSubscription(
        database,
        id: 'far',
        sourceId: sourceId,
        nextCheckAt: at + const Duration(hours: 1).inMilliseconds,
      );
      expect(
        await database.nextVideoDownloadSubscriptionDueAt(),
        at + const Duration(hours: 1).inMilliseconds,
        reason: '喂给唤醒封顶的 delay 必须真的是 1 小时',
      );

      final _WakeCountingService service = _countingService(
        database,
        now: frozen,
        cadence: kFastCadence,
      );
      service.start();

      // 冷窗 300ms。没有封顶，这一条就会睡满一小时，兜底探测再也不会发生。
      expect(
        await _waitFor(() => service.wakeCount >= 3),
        isTrue,
        reason: '唤醒被推迟到了冷窗之外，等了 10s 只醒了 ${service.wakeCount} 次',
      );
    });
  });

  group('构造参数校验', () {
    test('非法 cadence 立刻抛，而不是让节奏静默失效', () async {
      final FushiDatabase database = await _openDatabase();
      VideoDownloadSubscriptionService build(
        SubscriptionCheckCadence cadence,
      ) =>
          VideoDownloadSubscriptionService(
            database: database,
            resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[
              _EmptyResourceProvider(),
            ]),
            enqueue: (VideoDownloadEnqueueRequest request) async => 'unused',
            cadence: cadence,
          );

      // maxSamples: 0 会让每次取样抛 ArgumentError 并被降级吞掉——整个特性静默
      // 变成 no-op。必须在构造时就拒绝。
      expect(
        () => build(const SubscriptionCheckCadence(maxSamples: 0)),
        throwsArgumentError,
      );
      expect(
        () => build(const SubscriptionCheckCadence(minSamples: 0)),
        throwsArgumentError,
      );
      expect(
        () => build(
          const SubscriptionCheckCadence(baseInterval: Duration.zero),
        ),
        throwsArgumentError,
      );
      expect(
        () => build(
          const SubscriptionCheckCadence(
            hotInterval: Duration(hours: 3),
            coldInterval: Duration(hours: 1),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('getVideoDownloadSubscriptionPublishedAt', () {
    test('按发布时刻降序返回，并滤掉缺失值', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      final List<int> samples =
          await database.getVideoDownloadSubscriptionPublishedAt('weekly');
      expect(samples, <int>[
        kRelease.millisecondsSinceEpoch,
        kRelease.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
        kRelease.subtract(const Duration(days: 14)).millisecondsSinceEpoch,
      ]);
    });

    test('limit 只取最近若干条', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly', weeks: 4);

      expect(
        (await database.getVideoDownloadSubscriptionPublishedAt(
          'weekly',
          limit: 2,
        ))
            .length,
        2,
      );
    });
  });

  group('nextVideoDownloadSubscriptionDueAt', () {
    test('没有订阅时返回 null', () async {
      final FushiDatabase database = await _openDatabase();
      expect(await database.nextVideoDownloadSubscriptionDueAt(), isNull);
    });

    test('取启用订阅中最早的到期时刻', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'late',
        sourceId: sourceId,
        nextCheckAt: 9000,
      );
      await _insertSubscription(
        database,
        id: 'early',
        sourceId: sourceId,
        nextCheckAt: 4000,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 4000);
    });

    test('停用的订阅不参与调度', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'off',
        sourceId: sourceId,
        enabled: false,
        nextCheckAt: 1000,
      );
      await _insertSubscription(
        database,
        id: 'on',
        sourceId: sourceId,
        nextCheckAt: 7000,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 7000);
    });

    test('nextCheckAt 为 NULL 的新订阅立即到期', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'brand-new',
        sourceId: sourceId,
        nextCheckAt: null,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 0);
    });

    test('被别的 worker 占着的行要等 lease 过期才算到期', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'claimed',
        sourceId: sourceId,
        nextCheckAt: 1000,
      );
      await database.claimNextVideoDownloadSubscription(
        workerId: 'other-worker',
        nowAt: 1000,
        leaseDurationMs: 5000,
      );

      // nextCheckAt 仍是 1000，但 lease 要到 6000 才过期。
      expect(await database.nextVideoDownloadSubscriptionDueAt(), 6000);
    });
  });
}

class _EmptyResourceProvider implements VideoResourceProvider {
  int searchCount = 0;

  @override
  String get id => 'torznab';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    searchCount++;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      const <VideoResourceCandidate>[],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      fail('no candidate should be resolved');

  @override
  void close() {}
}
