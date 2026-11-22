import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_auth.dart';
import 'package:fushi/src/media/privacy/media_lock_dialogs.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show TrackingMediaType;
import 'package:fushi_engine/privacy/media_lock.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteBookInfo, RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

/// 上锁作品（拍板台 qiqSbvdxrk）：口令只存 PBKDF2 摘要；显示口径
/// [MediaVisibility] 每次启动回到「藏」，验证通过才本次会话显示；快照没读完时
/// fail-closed 全藏。
final class _FakeDeviceAuth implements DeviceOwnerAuth {
  _FakeDeviceAuth({required this.available, required this.result});

  final bool available;
  final DeviceOwnerAuthResult result;
  int calls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<DeviceOwnerAuthResult> authenticate(String reason) async {
    calls++;
    return result;
  }
}

MediaLockAuth _auth({
  MediaLockPasscode? passcode,
  required DeviceOwnerAuth device,
  bool hasLockedWorks = false,
  MediaLockThrottle? throttle,
}) => MediaLockAuth(
  passcode:
      passcode ??
      MediaLockPasscode(store: MemoryMediaLockCredentialStore(), iterations: 2),
  device: device,
  throttle: throttle ?? MediaLockThrottle(store: MemoryMediaLockSecretStore()),
  hasLockedWorks: () async => hasLockedWorks,
);

_FakeDeviceAuth _noDevice() => _FakeDeviceAuth(
  available: false,
  result: DeviceOwnerAuthResult.unavailable,
);

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  setUp(() {
    MediaLockAuth.debugOverride = null;
    MediaLockSession.instance.resetForTest();
  });
  tearDown(() {
    MediaLockAuth.debugOverride = null;
    MediaLockSession.instance.resetForTest();
  });

  group('口令', () {
    test('PBKDF2-HMAC-SHA256 对上标准向量', () {
      expect(
        _hex(
          pbkdf2HmacSha256(utf8.encode('password'), utf8.encode('salt'), 1, 32),
        ),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        _hex(
          pbkdf2HmacSha256(utf8.encode('password'), utf8.encode('salt'), 2, 32),
        ),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('设 / 验 / 清；库里只有摘要；过短拒绝；记录坏了 / 迭代数离谱 fail-closed', () async {
      final MemoryMediaLockCredentialStore store =
          MemoryMediaLockCredentialStore();
      final MediaLockPasscode passcode = MediaLockPasscode(
        store: store,
        iterations: 3,
      );
      expect(await passcode.isSet(), isFalse);
      expect(await passcode.verify('1234'), isFalse);
      expect(() => passcode.set('12'), throwsArgumentError);

      await passcode.set('2468');
      expect(await passcode.isSet(), isTrue);
      expect(store.verifier, isNot(contains('2468')));
      expect(await passcode.verify('2468'), isTrue);
      expect(await passcode.verify('2469'), isFalse);

      final Map<String, Object?> record =
          (jsonDecode(store.verifier!) as Map<String, Object?>)
            ..['iter'] = 1 << 30;
      store.verifier = jsonEncode(record);
      expect(
        await passcode.verify('2468'),
        isFalse,
        reason: '同步来的记录迭代数超上限：拒绝而不是卡死',
      );

      store.verifier = 'not json';
      expect(await passcode.verify('2468'), isFalse);

      await passcode.clear();
      expect(await passcode.isSet(), isFalse);
    });

    test('常量时间比较：长度不同 / 任一字节不同都不等', () {
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 3]), isTrue);
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 4]), isFalse);
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 2, 3]), isFalse);
    });

    test('口令摘要在库里（media_lock_credentials），删除留带戳的空记录以便同步', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final MediaLockPasscode passcode = MediaLockPasscode(
        store: DbMediaLockCredentialStore(db),
        iterations: 2,
      );
      await passcode.set('2468');
      expect((await db.mediaLockCredential())?.verifier, isNotNull);
      expect(await passcode.verify('2468'), isTrue);
      await passcode.clear();
      final MediaLockCredential? cleared = await db.mediaLockCredential();
      expect(cleared, isNotNull);
      expect(cleared?.verifier, isNull);
      expect(await passcode.isSet(), isFalse);
    });

    test('冷却：5 次输错进一轮、时长翻倍封顶 1 小时；跨实例持久；成功清零；记录坏了按最长冷却', () async {
      DateTime now = DateTime(2026, 1, 1);
      final MemoryMediaLockSecretStore store = MemoryMediaLockSecretStore();
      MediaLockThrottle throttle() =>
          MediaLockThrottle(store: store, clock: () => now);

      for (int i = 0; i < 4; i++) {
        expect(await throttle().recordFailure(), isNull);
      }
      expect(await throttle().coolingUntil(), isNull);
      expect(await throttle().recordFailure(), const Duration(seconds: 30));
      expect(
        await throttle().coolingUntil(),
        now.add(const Duration(seconds: 30)),
        reason: '新实例（= 重启 app）读到同一份冷却',
      );
      now = now.add(const Duration(seconds: 31));
      expect(await throttle().coolingUntil(), isNull);
      for (int i = 0; i < 4; i++) {
        await throttle().recordFailure();
      }
      expect(await throttle().recordFailure(), const Duration(seconds: 60));
      for (int round = 0; round < 20; round++) {
        for (int i = 0; i < 5; i++) {
          await throttle().recordFailure();
        }
      }
      for (int i = 0; i < 4; i++) {
        expect(await throttle().recordFailure(), isNull);
      }
      expect(await throttle().recordFailure(), MediaLockThrottle.maxCooldown);

      await throttle().recordSuccess();
      expect(await throttle().coolingUntil(), isNull);

      store.values[MediaLockThrottle.storageKey] = '{broken';
      expect(
        await throttle().coolingUntil(),
        now.add(MediaLockThrottle.maxCooldown),
      );
    });

    test('有口令或系统验证可用才算有解锁方式', () async {
      expect(await _auth(device: _noDevice()).hasAnyMethod(), isFalse);
      expect(
        await _auth(
          device: _FakeDeviceAuth(
            available: true,
            result: DeviceOwnerAuthResult.success,
          ),
        ).hasAnyMethod(),
        isTrue,
      );
    });

    test('验证 / 设口令 / 删口令的判定：没口令没系统验证却有上锁作品 → 一律拒绝', () async {
      final _FakeDeviceAuth device = _FakeDeviceAuth(
        available: true,
        result: DeviceOwnerAuthResult.success,
      );
      final MediaLockPasscode withCode = MediaLockPasscode(
        store: MemoryMediaLockCredentialStore(),
        iterations: 2,
      );
      await withCode.set('2468');

      expect(
        await _auth(passcode: withCode, device: _noDevice()).verifyOwnerPlan(),
        MediaLockVerifyPlan.passcode,
      );
      expect(
        await _auth(device: device, hasLockedWorks: true).verifyOwnerPlan(),
        MediaLockVerifyPlan.device,
      );
      expect(
        await _auth(
          device: _noDevice(),
          hasLockedWorks: true,
        ).verifyOwnerPlan(),
        MediaLockVerifyPlan.blocked,
        reason: '同步来的锁不能靠「新设一个口令」打开',
      );
      expect(
        await _auth(device: _noDevice()).verifyOwnerPlan(),
        MediaLockVerifyPlan.nothingToProtect,
      );

      expect(
        await _auth(
          passcode: withCode,
          device: _noDevice(),
        ).passcodeChangePlan(),
        MediaLockPasscodeChangePlan.verifyOwner,
      );
      expect(
        await _auth(device: device, hasLockedWorks: true).passcodeChangePlan(),
        MediaLockPasscodeChangePlan.verifyDevice,
      );
      expect(
        await _auth(
          device: _noDevice(),
          hasLockedWorks: true,
        ).passcodeChangePlan(),
        MediaLockPasscodeChangePlan.blocked,
      );
      expect(
        await _auth(device: _noDevice()).passcodeChangePlan(),
        MediaLockPasscodeChangePlan.free,
      );

      expect(
        await _auth(device: device).passcodeRemovalPlan(),
        MediaLockPasscodeRemovalPlan.notSet,
      );
      expect(
        await _auth(
          passcode: withCode,
          device: _noDevice(),
          hasLockedWorks: true,
        ).passcodeRemovalPlan(),
        MediaLockPasscodeRemovalPlan.blockedByLockedWorks,
      );
      expect(
        await _auth(
          passcode: withCode,
          device: device,
          hasLockedWorks: true,
        ).passcodeRemovalPlan(),
        MediaLockPasscodeRemovalPlan.allowed,
      );
      expect(
        await _auth(
          passcode: withCode,
          device: _noDevice(),
        ).passcodeRemovalPlan(),
        MediaLockPasscodeRemovalPlan.allowed,
      );
    });
  });

  group('显示口径', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('没有上锁作品 = 什么都不藏；pending 全藏', () {
      expect(
        MediaVisibility.fromSnapshot(MediaLockSnapshot.none).hidesAnything,
        isFalse,
      );
      expect(MediaVisibility.all.hidesVideo('v'), isFalse);
      expect(MediaVisibility.pending.hidesVideo('v'), isTrue);
      expect(MediaVisibility.pending.hidesMusicAlbum('a'), isTrue);
    });

    test('未解锁藏上锁作品（含合集成员）；解锁后本次会话全显示；重新上锁又藏', () async {
      final int c = await db.createMediaCollection('锁');
      await db.addToCollection(c, MediaKind.game, 'g-in');
      await db.setMediaLocked(
        TagHostKind.collection,
        collectionTagEntryKey(c),
        true,
      );
      await db.setMediaLocked(TagHostKind.video, 'v1', true);
      await db.setMediaLocked(TagHostKind.musicAlbum, 'alb', true);

      MediaVisibility v = await MediaVisibility.load(db);
      expect(v.hidesVideo('v1'), isTrue);
      expect(v.hidesVideo('v2'), isFalse);
      expect(v.hidesCollection(c), isTrue);
      expect(v.hidesGame('g-in'), isTrue);
      expect(v.hidesCollectionMember(MediaKind.game.dbValue, 'g-in'), isTrue);
      expect(v.hidesCollectionMember('unknown-kind', 'x'), isFalse);
      expect(v.hidesMusicAlbum('alb'), isTrue);

      MediaLockSession.instance.unlock();
      v = await MediaVisibility.load(db);
      expect(v.hidesAnything, isFalse);

      MediaLockSession.instance.relock();
      v = await MediaVisibility.load(db);
      expect(v.hidesVideo('v1'), isTrue);
    });

    test('只知来源键 / 标题的行：书 bookKey、字幕书 uid 与 bookKey、合集成员、专辑曲目都认', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'bk-locked',
          title: '上锁的书',
          epubPath: '/tmp/a.epub',
          extractDir: '/tmp/a',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: 0,
        ),
      );
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'v-in',
          title: '合集里的视频',
          videoPath: '/tmp/v.mp4',
        ),
      );
      await db
          .into(db.musicTracks)
          .insert(
            MusicTracksCompanion.insert(
              trackUid: 't1',
              path: '/m/t1.flac',
              title: 'T1',
              fileMtimeAt: 1,
              fileSize: 1,
              addedAt: 1,
              albumUid: const Value<String?>('alb'),
            ),
          );
      await db.setMediaLocked(TagHostKind.epub, 'bk-locked', true);
      await db.setMediaLocked(TagHostKind.musicAlbum, 'alb', true);
      final int c = await db.createMediaCollection('锁');
      await db.addToCollection(c, MediaKind.video, 'v-in');
      await db.setMediaLocked(
        TagHostKind.collection,
        collectionTagEntryKey(c),
        true,
      );

      final MediaVisibility v = await MediaVisibility.load(db);
      expect(v.hidesWork(key: 'bk-locked'), isTrue);
      expect(v.hidesWork(key: 'v-in'), isTrue, reason: '上锁合集的成员');
      expect(v.hidesWork(key: 'other'), isFalse);
      expect(v.hidesWork(title: '上锁的书'), isTrue, reason: 'legacy 无身份行按标题');
      expect(v.hidesWork(title: '合集里的视频'), isTrue);
      expect(v.hidesWork(title: '别的书'), isFalse);
      expect(v.hidesMusicTrack('t1'), isTrue);
      expect(v.hidesMusicTrack('t2'), isFalse);
      expect(
        v.hidesTrackedMedia(TrackingMediaType.book.value, 'bk-locked'),
        isTrue,
      );
      expect(
        v.hidesTrackedMedia(TrackingMediaType.video.value, 'v-in'),
        isTrue,
      );
      expect(
        v.hidesTrackedMedia(TrackingMediaType.videoCollection.value, '$c'),
        isTrue,
      );
      expect(v.hidesTrackedMedia(TrackingMediaType.video.value, 'x'), isFalse);
    });

    test('统计事实面去掉上锁作品的行，复习事实保留', () async {
      await db.setMediaLocked(TagHostKind.video, 'v1', true);
      final MediaVisibility v = await MediaVisibility.load(db);
      StatFact fact(String kind, String key) => StatFact(
        mediaKind: kind,
        mediaKey: key,
        title: key,
        format: '',
        dateKey: '2026-01-01',
        hour: 1,
        ms: 1000,
        chars: 0,
        pages: 0,
        lastActiveMs: 1,
      );
      final StatFacts facts = StatFacts(
        daily: <StatFact>[
          fact('video', 'v1'),
          fact('video', 'v2'),
          fact(kStatMediaReview, 'v1'),
        ],
        hourly: <StatFact>[fact('video', 'v1')],
        segments: StatFacts.empty.segments,
        legacyActivity: StatFacts.empty.legacyActivity,
        epubRows: StatFacts.empty.epubRows,
      );
      final StatFacts visible = v.visibleStatFacts(facts);
      expect(
        visible.daily.map((StatFact f) => (f.mediaKind, f.mediaKey)),
        <(String, String)>[('video', 'v2'), (kStatMediaReview, 'v1')],
      );
      expect(visible.hourly, isEmpty);
      expect(
        identical(MediaVisibility.nothingLocked.visibleStatFacts(facts), facts),
        isTrue,
      );
    });

    test('互联远端条目：对端标了上锁就藏（本机没上锁作品也藏），解锁后显示', () {
      const RemoteBookInfo locked = RemoteBookInfo(
        title: '对端上锁',
        bookKey: 'rk',
        hasContent: true,
        locked: true,
      );
      const RemoteBookInfo open = RemoteBookInfo(
        title: '对端公开',
        bookKey: 'ok',
        hasContent: true,
      );
      expect(MediaVisibility.nothingLocked.hidesRemoteBook(locked), isTrue);
      expect(MediaVisibility.nothingLocked.hidesRemoteBook(open), isFalse);
      expect(MediaVisibility.pending.hidesRemoteBook(open), isTrue);
      expect(MediaVisibility.all.hidesRemoteBook(locked), isFalse);
      expect(
        RemoteBookInfo.fromJson(locked.toJson()).locked,
        isTrue,
        reason: 'wire 字段 locked 往返',
      );
      expect(
        open.toJson().containsKey('locked'),
        isFalse,
        reason: '只在 true 时写',
      );
      final RemoteVideoInfo video = RemoteVideoInfo(
        id: 'rv',
        title: 'V',
        locked: true,
      );
      expect(RemoteVideoInfo.fromJson(video.toJson()).locked, isTrue);
      expect(MediaVisibility.nothingLocked.hidesRemoteVideo(video), isTrue);
    });

    test('快照流：上锁 / 解锁立即重发，内容没变不重发', () async {
      final List<MediaLockSnapshot> seen = <MediaLockSnapshot>[];
      final sub = watchMediaLockSnapshot(db).listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen, hasLength(1));
      expect(seen.last.isEmpty, isTrue);

      await db.setMediaLocked(TagHostKind.video, 'v1', true);
      await pumpEventQueue();
      expect(seen.last.isVideoLocked('v1'), isTrue);
      final int count = seen.length;

      await db.addToCollection(
        await db.createMediaCollection('x'),
        MediaKind.video,
        'v9',
      );
      await pumpEventQueue();
      expect(seen, hasLength(count), reason: '上锁口径没变，不重发');
    });
  });

  group('解锁对话框', () {
    Future<void> pumpHost(
      WidgetTester tester, {
      required bool apple,
      required ValueChanged<bool> onResult,
      Future<bool> Function(BuildContext context, FushiDatabase db)? action,
    }) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          home: FushiGlassScope(
            child: Scaffold(
              body: Builder(
                builder: (BuildContext context) => TextButton(
                  onPressed: () async => onResult(
                    await (action ?? unlockMediaLockSession)(context, db),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    }

    for (final bool apple in <bool>[false, true]) {
      final String system = apple ? 'Apple' : 'MD3';

      testWidgets('$system：口令错提示、口令对解锁本次会话', (WidgetTester tester) async {
        final MediaLockPasscode passcode = MediaLockPasscode(
          store: MemoryMediaLockCredentialStore(),
          iterations: 2,
        );
        await tester.runAsync(() => passcode.set('2468'));
        MediaLockAuth.debugOverride = _auth(
          passcode: passcode,
          device: _noDevice(),
        );
        bool? result;
        await pumpHost(tester, apple: apple, onResult: (bool v) => result = v);
        await tester.tap(find.text('open'));
        await settle(tester);

        final Finder field = find.byKey(
          const ValueKey<String>('media-lock-passcode-field'),
        );
        expect(field, findsOneWidget);
        expect(find.text(t.media_lock_use_device_auth), findsNothing);

        await tester.enterText(field, '1111');
        await tester.tap(find.text(t.media_lock_unlock_action));
        await settle(tester);
        expect(
          find.byKey(const ValueKey<String>('media-lock-passcode-error')),
          findsOneWidget,
        );
        expect(MediaLockSession.instance.isUnlocked, isFalse);

        await tester.enterText(field, '2468');
        await tester.tap(find.text(t.media_lock_unlock_action));
        await settle(tester);
        expect(field, findsNothing);
        expect(result, isTrue);
        expect(MediaLockSession.instance.isUnlocked, isTrue);
      });
    }

    testWidgets('没设口令、系统验证可用：直接走系统验证，取消不解锁', (WidgetTester tester) async {
      final _FakeDeviceAuth device = _FakeDeviceAuth(
        available: true,
        result: DeviceOwnerAuthResult.failed,
      );
      MediaLockAuth.debugOverride = _auth(device: device);
      bool? result;
      await pumpHost(tester, apple: false, onResult: (bool v) => result = v);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(device.calls, 1);
      expect(result, isFalse);
      expect(MediaLockSession.instance.isUnlocked, isFalse);
    });

    for (final bool apple in <bool>[false, true]) {
      final String system = apple ? 'Apple' : 'MD3';

      testWidgets('$system：没口令没系统验证、本机有上锁作品 → 拒绝说明，不弹设口令框', (
        WidgetTester tester,
      ) async {
        MediaLockAuth.debugOverride = _auth(
          device: _noDevice(),
          hasLockedWorks: true,
        );
        bool? result;
        await pumpHost(tester, apple: apple, onResult: (bool v) => result = v);
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(
          find.byKey(const ValueKey<String>('media-lock-blocked-dialog')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('media-lock-passcode-field')),
          findsNothing,
        );
        await tester.tap(find.text(t.dialog_ok));
        await settle(tester);
        expect(result, isFalse);
        expect(MediaLockSession.instance.isUnlocked, isFalse);
      });

      testWidgets('$system：删口令先验证、再确认；删掉后口令不存在、会话不解锁', (
        WidgetTester tester,
      ) async {
        final MediaLockPasscode passcode = MediaLockPasscode(
          store: MemoryMediaLockCredentialStore(),
          iterations: 2,
        );
        await tester.runAsync(() => passcode.set('2468'));
        MediaLockAuth.debugOverride = _auth(
          passcode: passcode,
          device: _noDevice(),
        );
        bool? result;
        await pumpHost(
          tester,
          apple: apple,
          onResult: (bool v) => result = v,
          action: removeMediaLockPasscode,
        );
        await tester.tap(find.text('open'));
        await settle(tester);
        final Finder field = find.byKey(
          const ValueKey<String>('media-lock-passcode-field'),
        );
        expect(field, findsOneWidget, reason: '删之前要先验证机主');
        await tester.enterText(field, '2468');
        await tester.tap(find.text(t.media_lock_unlock_action));
        await settle(tester);
        expect(
          find.text(t.media_lock_passcode_remove_confirm_title),
          findsOneWidget,
        );
        await tester.tap(find.text(t.media_lock_passcode_remove_action));
        await settle(tester);
        expect(result, isTrue);
        expect(await tester.runAsync(passcode.isSet), isFalse);
        expect(MediaLockSession.instance.isUnlocked, isFalse);
      });
    }
  });
}
