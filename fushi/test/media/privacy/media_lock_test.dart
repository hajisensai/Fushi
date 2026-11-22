import 'dart:convert';

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
import 'package:fushi_engine/privacy/media_lock.dart';
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

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late MediaLockAuth savedAuth;

  setUp(() {
    savedAuth = MediaLockAuth.instance;
    MediaLockSession.instance.resetForTest();
    resetMediaLockThrottleForTest();
  });
  tearDown(() {
    MediaLockAuth.instance = savedAuth;
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

    test('设 / 验 / 清；存储里只有摘要；过短拒绝；记录坏了 fail-closed', () async {
      final MemoryMediaLockSecretStore store = MemoryMediaLockSecretStore();
      final MediaLockPasscode passcode = MediaLockPasscode(
        store: store,
        iterations: 3,
      );
      expect(await passcode.isSet(), isFalse);
      expect(await passcode.verify('1234'), isFalse);
      expect(() => passcode.set('12'), throwsArgumentError);

      await passcode.set('2468');
      expect(await passcode.isSet(), isTrue);
      expect(
        store.values[MediaLockPasscode.storageKey],
        isNot(contains('2468')),
      );
      expect(await passcode.verify('2468'), isTrue);
      expect(await passcode.verify('2469'), isFalse);

      store.values[MediaLockPasscode.storageKey] = 'not json';
      expect(await passcode.verify('2468'), isFalse);

      await passcode.clear();
      expect(await passcode.isSet(), isFalse);
    });

    test('有口令或系统验证可用才算有解锁方式', () async {
      final MediaLockPasscode passcode = MediaLockPasscode(
        store: MemoryMediaLockSecretStore(),
        iterations: 2,
      );
      expect(
        await MediaLockAuth(
          passcode: passcode,
          device: _FakeDeviceAuth(
            available: false,
            result: DeviceOwnerAuthResult.unavailable,
          ),
        ).hasAnyMethod(),
        isFalse,
      );
      expect(
        await MediaLockAuth(
          passcode: passcode,
          device: _FakeDeviceAuth(
            available: true,
            result: DeviceOwnerAuthResult.success,
          ),
        ).hasAnyMethod(),
        isTrue,
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
    }) async {
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
                  onPressed: () async =>
                      onResult(await unlockMediaLockSession(context)),
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
          store: MemoryMediaLockSecretStore(),
          iterations: 2,
        );
        await tester.runAsync(() => passcode.set('2468'));
        MediaLockAuth.instance = MediaLockAuth(
          passcode: passcode,
          device: _FakeDeviceAuth(
            available: false,
            result: DeviceOwnerAuthResult.unavailable,
          ),
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
      MediaLockAuth.instance = MediaLockAuth(
        passcode: MediaLockPasscode(
          store: MemoryMediaLockSecretStore(),
          iterations: 2,
        ),
        device: device,
      );
      bool? result;
      await pumpHost(tester, apple: false, onResult: (bool v) => result = v);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(device.calls, 1);
      expect(result, isFalse);
      expect(MediaLockSession.instance.isUnlocked, isFalse);
    });
  });
}
