import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_account.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';

const AppleMusicAccountState _subscribed = AppleMusicAccountState(
  status: AppleMusicAuthStatus.authorized,
  canPlayCatalogContent: true,
  storefront: 'jp',
);

/// 计数账号状态读取的桥；状态与 unauthorize 失败由测试设定。
class _AccountBridge implements AppleMusicBridge {
  final StreamController<AppleMusicPlayerEvent> ctrl =
      StreamController<AppleMusicPlayerEvent>.broadcast(sync: true);
  AppleMusicAccountState state = _subscribed;
  int stateReads = 0;
  int unauthorizeCalls = 0;
  Exception? unauthorizeError;
  AppleMusicUserCredentials? credentials;
  bool disposed = false;

  @override
  Stream<AppleMusicPlayerEvent> get events => ctrl.stream;

  @override
  Future<AppleMusicAccountState> accountState() async {
    stateReads++;
    return state;
  }

  @override
  Future<void> unauthorize() async {
    unauthorizeCalls++;
    final Exception? e = unauthorizeError;
    if (e != null) throw e;
  }

  @override
  Future<AppleMusicUserCredentials?> userCredentials() async => credentials;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Future<AppleMusicAccountState> authorize(BuildContext context) async => state;
  @override
  Future<void> play(
    String songId, {
    int startMs = 0,
    bool autoplay = true,
  }) async {}
  @override
  Future<void> playStation(String stationId, {bool autoplay = true}) async {}
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(int positionMs) async {}
  @override
  Future<void> setVolume(double volume) async {}
}

void main() {
  late _AccountBridge bridge;
  late bool connected;
  late List<bool> connectedWrites;
  late DateTime now;
  late AppleMusicAccount account;

  setUp(() {
    bridge = _AccountBridge();
    connected = true;
    connectedWrites = <bool>[];
    now = DateTime(2026, 11, 3, 12);
    account = AppleMusicAccount(
      bridge: () => bridge,
      connected: () => connected,
      setConnected: (bool v) async {
        connectedWrites.add(v);
        connected = v;
      },
      now: () => now,
    );
  });

  test('not connected: refresh never reads the bridge state', () async {
    connected = false;
    final AppleMusicAccountState s = await account.refresh(force: true);
    expect(s, AppleMusicAccountState.signedOut);
    expect(bridge.stateReads, 0);
    expect(account.canPlayFullTracks, isFalse);
    await expectLater(
      account.userCredentials(),
      throwsA(isA<AppleMusicNotSignedInException>()),
    );
  });

  test('no platform bridge: unsupported, nothing to read', () async {
    final AppleMusicAccount none = AppleMusicAccount(
      bridge: () => null,
      connected: () => true,
      setConnected: (bool _) async {},
    );
    expect(none.platformSupported, isFalse);
    expect(await none.refresh(force: true), AppleMusicAccountState.signedOut);
    expect(none.canPlayFullTracks, isFalse);
  });

  test('state is cached for the TTL; force and expiry re-read', () async {
    await account.refresh();
    expect(bridge.stateReads, 1);
    expect(account.canPlayFullTracks, isTrue);

    now = now.add(kAppleMusicAccountStateTtl - const Duration(seconds: 1));
    await account.refresh();
    expect(bridge.stateReads, 1, reason: '缓存未过期');

    await account.refresh(force: true);
    expect(bridge.stateReads, 2);

    now = now.add(kAppleMusicAccountStateTtl);
    await account.refresh();
    expect(bridge.stateReads, 3, reason: '过期重读');
  });

  test('concurrent refreshes share one bridge read', () async {
    await Future.wait(<Future<AppleMusicAccountState>>[
      account.refresh(force: true),
      account.refresh(force: true),
    ]);
    expect(bridge.stateReads, 1);
  });

  test('full tracks need connected + authorized + subscription', () async {
    bridge.state = const AppleMusicAccountState(
      status: AppleMusicAuthStatus.authorized,
      canBecomeSubscriber: true,
    );
    await account.refresh(force: true);
    expect(account.canPlayFullTracks, isFalse, reason: '没订阅');

    bridge.state = _subscribed;
    await account.refresh(force: true);
    expect(account.canPlayFullTracks, isTrue);

    connected = false;
    expect(account.canPlayFullTracks, isFalse, reason: '在 Fushi 里断开了');
  });

  test('disconnect clears the preference, unauthorizes, signs out', () async {
    await account.refresh(force: true);
    int notifications = 0;
    account.addListener(() => notifications++);
    await account.disconnect();
    expect(connectedWrites, <bool>[false]);
    expect(bridge.unauthorizeCalls, 1);
    expect(account.connected, isFalse);
    expect(account.state, AppleMusicAccountState.signedOut);
    expect(account.canPlayFullTracks, isFalse);
    expect(notifications, greaterThan(0));
  });

  test('disconnect still signs out when unauthorize fails', () async {
    await account.refresh(force: true);
    bridge.unauthorizeError = const AppleMusicBridgeException('unauthorize');
    await account.disconnect();
    expect(account.connected, isFalse);
    expect(account.state, AppleMusicAccountState.signedOut);
    expect(account.lastError, isA<AppleMusicBridgeException>());
  });

  test('bridge account events: sign-in re-reads, sign-out is final', () async {
    await account.refresh(force: true);
    expect(bridge.stateReads, 1);
    // 网页桥的 auth 事件不带订阅情况：作废缓存，下次 refresh 重读。
    bridge.ctrl.add(
      const AppleMusicAccountChanged(
        AppleMusicAccountState(status: AppleMusicAuthStatus.authorized),
      ),
    );
    await account.refresh();
    expect(bridge.stateReads, 2);
    // 已退出是确定的状态：直接落下，不必再读。
    bridge.ctrl.add(
      const AppleMusicAccountChanged(AppleMusicAccountState.signedOut),
    );
    expect(account.state, AppleMusicAccountState.signedOut);
    expect(account.canPlayFullTracks, isFalse);
    await account.refresh();
    expect(bridge.stateReads, 2);
  });

  test('a failed state read is reported without losing the state', () async {
    await account.refresh(force: true);
    final _ThrowingBridge throwing = _ThrowingBridge();
    final AppleMusicAccount broken = AppleMusicAccount(
      bridge: () => throwing,
      connected: () => true,
      setConnected: (bool _) async {},
    );
    final AppleMusicAccountState s = await broken.refresh(force: true);
    expect(s, AppleMusicAccountState.signedOut);
    expect(broken.lastError, isA<AppleMusicBridgeException>());
    broken.dispose();
  });

  test('dispose releases the bridge it created', () async {
    expect(account.platformSupported, isTrue);
    account.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.disposed, isTrue);
  });
}

class _ThrowingBridge extends _AccountBridge {
  @override
  Future<AppleMusicAccountState> accountState() async =>
      throw const AppleMusicBridgeException('bridge_page_timeout');
}
