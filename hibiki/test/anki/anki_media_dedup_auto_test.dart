// 用户拍板「加一个可以打开的自动处理」之后的守卫：
//   1. 自动处理**默认关**——不开就连扫都不扫，一个文件都不会动；
//   2. 打开之后仍然只做**干跑并提示**，真删必须用户确认；
//   3. 只有用户**另外显式**打开「自动直接删除」，自动路径才会跳过确认去删。
//
// 原实现的缺陷正是「自动路径绕过确认框」，所以把开关加回来时这三条必须结构性
// 成立，而不是靠 UI 自觉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/anki/anki_media_dedup_runner.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _TempDirRunner extends AnkiMediaDedupRunner {
  _TempDirRunner(super.repository, this._dir);

  final Directory _dir;

  @override
  Future<Directory> journalDirectory() async => _dir;
}

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo(
      {required this.settings, this.deletions = 1, this.cancelled = false});

  AnkiSettings settings;

  /// 干跑清单里有几条（0 = 没有重复）。
  final int deletions;

  /// 返回的报告是否标记为「中途取消」。
  final bool cancelled;

  /// 每次 runMediaDedup 的 dryRun 取值，按调用顺序记录。
  final List<bool> dedupCalls = <bool>[];

  /// runner 是否把进度/取消回调透传下来（BUG-1263 的管道守卫）。
  bool receivedOnProgress = false;
  bool receivedShouldCancel = false;

  @override
  bool get supportsMediaMaintenance => true;

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => settings = s;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {
    dedupCalls.add(dryRun);
    receivedOnProgress = receivedOnProgress || onProgress != null;
    receivedShouldCancel = receivedShouldCancel || shouldCancel != null;
    return AnkiMediaDedupReport(
      dryRun: dryRun,
      groupCount: deletions == 0 ? 0 : 1,
      deletions: <MediaDedupDeletion>[
        for (int i = 0; i < deletions; i++)
          MediaDedupDeletion(
              filename: 'dupe$i.jpg', canonical: 'keep.jpg', bytes: 1024),
      ],
      notesRewritten: 0,
      modelsRewritten: 0,
      skipped: 0,
      cancelled: cancelled,
    );
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('anki_dedup_auto_test');
    AnkiMediaDedupRunner.resetAutoSessionGate();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('默认关：全新设置不跑自动处理，连扫描都不发生', () async {
    const AnkiSettings fresh = AnkiSettings();
    expect(fresh.mediaDedupAutoEnabled, isFalse);
    expect(fresh.mediaDedupAutoDelete, isFalse);

    final _FakeRepo repo = _FakeRepo(settings: fresh);
    final AnkiMediaDedupAutoOutcome? outcome =
        await _TempDirRunner(repo, dir).maybeAutoRunOnStartup();

    expect(outcome, isNull);
    expect(repo.dedupCalls, isEmpty);
  });

  test('缺键的老设置反序列化上来也是关的（升级不会凭空多一条自动删除路径）', () {
    final AnkiSettings migrated = AnkiSettings.fromJson(<String, dynamic>{});
    expect(migrated.mediaDedupAutoEnabled, isFalse);
    expect(migrated.mediaDedupAutoDelete, isFalse);
  });

  test('打开自动处理：只干跑 + 要求确认，绝不自己删', () async {
    final _FakeRepo repo = _FakeRepo(
      settings: const AnkiSettings(mediaDedupAutoEnabled: true),
    );

    final AnkiMediaDedupAutoOutcome? outcome =
        await _TempDirRunner(repo, dir).maybeAutoRunOnStartup();

    expect(outcome, isNotNull);
    expect(outcome!.applied, isNull, reason: '没确认就不许删');
    expect(outcome.needsConfirmation, isTrue);
    expect(outcome.plan.deletions, hasLength(1));
    // 只发生过干跑；真删那次调用根本没出现。
    expect(repo.dedupCalls, <bool>[true]);
    expect(repo.settings.lastMediaDedupAtMs, isNull);
    expect(repo.settings.lastMediaDedupScanAtMs, isNotNull);
  });

  test('自动处理开着但没有重复：不提示、不删', () async {
    final _FakeRepo repo = _FakeRepo(
      settings: const AnkiSettings(mediaDedupAutoEnabled: true),
      deletions: 0,
    );

    final AnkiMediaDedupAutoOutcome? outcome =
        await _TempDirRunner(repo, dir).maybeAutoRunOnStartup();

    expect(outcome!.needsConfirmation, isFalse);
    expect(outcome.applied, isNull);
    expect(repo.dedupCalls, <bool>[true]);
  });

  test('额外显式打开「自动直接删除」才会跳过确认真删', () async {
    final _FakeRepo repo = _FakeRepo(
      settings: const AnkiSettings(
        mediaDedupAutoEnabled: true,
        mediaDedupAutoDelete: true,
      ),
    );

    final AnkiMediaDedupAutoOutcome? outcome =
        await _TempDirRunner(repo, dir).maybeAutoRunOnStartup();

    expect(outcome!.applied, isNotNull);
    expect(outcome.needsConfirmation, isFalse);
    expect(repo.dedupCalls, <bool>[true, false]);
    expect(repo.settings.lastMediaDedupAtMs, isNotNull);
  });

  test('只开「自动直接删除」而没开自动处理：什么都不发生', () async {
    final _FakeRepo repo = _FakeRepo(
      settings: const AnkiSettings(mediaDedupAutoDelete: true),
    );

    expect(await _TempDirRunner(repo, dir).maybeAutoRunOnStartup(), isNull);
    expect(repo.dedupCalls, isEmpty);
  });

  test('每进程只跑一次（HomePage 重建不会重扫）', () async {
    final _FakeRepo repo = _FakeRepo(
      settings: const AnkiSettings(mediaDedupAutoEnabled: true),
    );
    final AnkiMediaDedupRunner runner = _TempDirRunner(repo, dir);

    expect(await runner.maybeAutoRunOnStartup(), isNotNull);
    expect(await runner.maybeAutoRunOnStartup(), isNull);
    expect(repo.dedupCalls, <bool>[true]);
  });

  group('扫描节流边界', () {
    final DateTime now = DateTime.utc(2026, 7, 27, 12);

    test('从未扫过 → 跑', () {
      expect(
        shouldRunAutoMediaDedupScan(lastScanAtMs: null, now: now),
        isTrue,
      );
    });

    test('正好到间隔 → 跑；差 1 毫秒 → 不跑', () {
      final DateTime exactly = now.subtract(kAnkiMediaDedupAutoInterval);
      expect(
        shouldRunAutoMediaDedupScan(
            lastScanAtMs: exactly.millisecondsSinceEpoch, now: now),
        isTrue,
      );
      final DateTime tooSoon = exactly.add(const Duration(milliseconds: 1));
      expect(
        shouldRunAutoMediaDedupScan(
            lastScanAtMs: tooSoon.millisecondsSinceEpoch, now: now),
        isFalse,
      );
    });

    test('还没到间隔时自动处理直接跳过（不白扫一遍全库）', () async {
      final _FakeRepo repo = _FakeRepo(
        settings: AnkiSettings(
          mediaDedupAutoEnabled: true,
          lastMediaDedupScanAtMs: now.millisecondsSinceEpoch,
        ),
      );

      final AnkiMediaDedupAutoOutcome? outcome =
          await _TempDirRunner(repo, dir).maybeAutoRunOnStartup(now: now);

      expect(outcome, isNull);
      expect(repo.dedupCalls, isEmpty);
    });
  });

  test('BUG-1263：取消的真删轮不推进时间戳（下次自动扫描照常到期）', () async {
    final _FakeRepo repo =
        _FakeRepo(settings: const AnkiSettings(), cancelled: true);

    final AnkiMediaDedupReport? report = await _TempDirRunner(repo, dir)
        .runNow(dryRun: false, onProgress: (AnkiMediaDedupProgress p) {});

    expect(report!.cancelled, isTrue);
    expect(repo.settings.lastMediaDedupAtMs, isNull);
    expect(repo.settings.lastMediaDedupScanAtMs, isNull);
  });

  test('BUG-1263：runNow 把进度/取消回调透传到仓库层（干跑与真跑都要）', () async {
    for (final bool dryRun in <bool>[true, false]) {
      final _FakeRepo repo = _FakeRepo(settings: const AnkiSettings());
      await _TempDirRunner(repo, dir).runNow(
        dryRun: dryRun,
        onProgress: (AnkiMediaDedupProgress p) {},
        shouldCancel: () => false,
      );
      expect(repo.receivedOnProgress, isTrue, reason: 'dryRun=$dryRun');
      expect(repo.receivedShouldCancel, isTrue, reason: 'dryRun=$dryRun');
    }
  });

  test('源码守卫：启动自动路径本身不得直接真删', () {
    final String source =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();
    final int autoStart =
        source.indexOf('Future<void> _maybeAutoDedupAnkiMedia');
    final int reviewStart = source.indexOf('Future<void> _reviewAutoDedupPlan');
    expect(autoStart, greaterThan(0));
    expect(reviewStart, greaterThan(autoStart));
    final String autoBody = source.substring(autoStart, reviewStart);
    // 真删只能出现在「用户点了查看 → 确认弹窗」之后的 _reviewAutoDedupPlan 里。
    // 无论旧拼写 runNow(dryRun: false) 还是进度包装
    // runAnkiMediaDedupWithProgress(..., dryRun: false)，自动路径正文一律不得
    // 出现真删调用。
    expect(autoBody.contains('runNow(dryRun: false)'), isFalse);
    expect(autoBody.contains('dryRun: false'), isFalse);
    expect(
      source
          .substring(reviewStart)
          .contains('showAnkiMediaDedupPlanDialog(context, plan'),
      isTrue,
    );
  });
}
