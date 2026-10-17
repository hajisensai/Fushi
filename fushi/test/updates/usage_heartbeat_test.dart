import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/updates/usage_heartbeat.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/install_identity.dart';

/// 安装统计心跳：平台门、UTC 日到期判据、开关、失败不记时刻、安装 id 稳定且设备本地。
/// 安装证明的推导（机器标识 → installId、回退种子、PoW 缓存）见 install_attestation_test.dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesRepository prefs;
  late DateTime clock;

  Future<PreferencesRepository> makePrefs() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    return repo;
  }

  final List<Map<String, String>> sent = <Map<String, String>>[];
  bool fail = false;

  final InstallAttestation install = InstallAttestation(
    InstallIdentity.fromMachineId('heartbeat-test-machine'),
    '1',
  );
  int resolves = 0;
  Future<InstallAttestation> fakeResolve(PreferencesRepository _) async {
    resolves++;
    return install;
  }

  Future<void> fakeSend({
    required InstallAttestation install,
    required String version,
    required String platform,
    required String channel,
  }) async {
    if (fail) throw StateError('offline');
    sent.add(<String, String>{
      'installId': install.installId,
      'version': version,
      'platform': platform,
      'channel': channel,
    });
  }

  UsageHeartbeat heartbeat({String os = 'windows'}) => UsageHeartbeat(
    prefs: prefs,
    send: fakeSend,
    version: () => '2.10.0-debug.8',
    channel: () => 'debug',
    operatingSystem: os,
    now: () => clock,
    install: fakeResolve,
  );

  setUp(() async {
    prefs = await makePrefs();
    clock = DateTime.utc(2026, 10, 17, 12);
    sent.clear();
    fail = false;
    resolves = 0;
  });

  test('平台键：四个桌面 / 安卓平台发，iOS 与其它不发', () {
    expect(usageHeartbeatPlatformFor('android'), 'android');
    expect(usageHeartbeatPlatformFor('windows'), 'windows');
    expect(usageHeartbeatPlatformFor('macos'), 'macos');
    expect(usageHeartbeatPlatformFor('linux'), 'linux');
    expect(usageHeartbeatPlatformFor('ios'), isNull);
    expect(usageHeartbeatPlatformFor('fuchsia'), isNull);
  });

  test('到期按 UTC 日：同一 UTC 日不再发，跨过 UTC 零点就到期', () {
    final int at = DateTime.utc(2026, 10, 17, 1).millisecondsSinceEpoch;
    expect(usageHeartbeatDue(lastPingAt: 0, now: clock), isTrue);
    expect(
      usageHeartbeatDue(lastPingAt: at, now: DateTime.utc(2026, 10, 17, 23)),
      isFalse,
    );
    expect(
      usageHeartbeatDue(lastPingAt: at, now: DateTime.utc(2026, 10, 18, 0, 1)),
      isTrue,
    );
    // 本地时区的 DateTime 也按 UTC 日算。
    expect(
      usageHeartbeatDue(
        lastPingAt: at,
        now: DateTime.utc(2026, 10, 17, 20).toLocal(),
      ),
      isFalse,
    );
  });

  test('首次运行发一次，字段齐全；当天再跑不发；隔天再发且安装 id 不变', () async {
    final UsageHeartbeat hb = heartbeat();
    expect(await hb.runIfDue(), isTrue);
    expect(sent.single, <String, String>{
      'installId': install.installId,
      'version': '2.10.0-debug.8',
      'platform': 'windows',
      'channel': 'debug',
    });
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(sent.single['installId']!),
      isTrue,
      reason: '服务端只收小写 UUID v4',
    );
    expect(prefs.usageStatsLastPingAt, clock.millisecondsSinceEpoch);

    clock = clock.add(const Duration(hours: 6));
    expect(await hb.runIfDue(), isFalse);
    expect(sent, hasLength(1));

    clock = clock.add(const Duration(days: 1));
    expect(await hb.runIfDue(), isTrue);
    expect(sent, hasLength(2));
    expect(sent[1]['installId'], sent[0]['installId']);
  });

  test('关掉开关不发', () async {
    await prefs.setUsageStatsEnabled(false);
    expect(await heartbeat().runIfDue(), isFalse);
    expect(sent, isEmpty);
  });

  test('iOS 不发，也不解析安装身份', () async {
    final UsageHeartbeat hb = heartbeat(os: 'ios');
    hb.start();
    expect(hb.isRunning, isFalse);
    expect(await hb.runIfDue(), isFalse);
    expect(sent, isEmpty);
    expect(resolves, 0);
    expect(prefs.getPref('usage_stats_install_id', defaultValue: ''), '');
  });

  test('发送失败不记时刻，下次 tick 补发', () async {
    fail = true;
    final UsageHeartbeat hb = heartbeat();
    expect(await hb.runIfDue(), isFalse);
    expect(prefs.usageStatsLastPingAt, 0);
    fail = false;
    expect(await hb.runIfDue(), isTrue);
    expect(sent, hasLength(1));
  });

  test('反馈附带的安装证明：开关开着且非 iOS 才有，与心跳同一个', () async {
    final InstallAttestation? att = await usageStatsInstallIdForFeedback(
      prefs,
      operatingSystem: 'android',
      resolve: fakeResolve,
    );
    expect(att?.installId, install.installId);
    expect(
      await usageStatsInstallIdForFeedback(
        prefs,
        operatingSystem: 'ios',
        resolve: fakeResolve,
      ),
      isNull,
    );
    await prefs.setUsageStatsEnabled(false);
    expect(
      await usageStatsInstallIdForFeedback(
        prefs,
        operatingSystem: 'android',
        resolve: fakeResolve,
      ),
      isNull,
    );
    expect(resolves, 1);
  });

  test('安装统计的偏好都是设备本地：不进备份 / 同步 / Profile 快照', () {
    for (final String key in <String>[
      'usage_stats_enabled',
      'usage_stats_install_id',
      'usage_stats_install_pow',
      'usage_stats_last_ping_at',
    ]) {
      expect(
        PrefRedactionPolicy.isDeviceLocalOrCredential(key),
        isTrue,
        reason: '$key 随备份漂到另一台设备会把两台设备算成同一个安装',
      );
      expect(ProfileKeys.isExcludedPref(key), isTrue, reason: key);
    }
  });
}
