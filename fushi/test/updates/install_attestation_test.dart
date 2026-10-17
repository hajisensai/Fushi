import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/install_attestation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/install_identity.dart';

/// 安装证明的解析：机器标识 → 稳定 installId（重装 / 清数据不变）、取不到时回退本机随机种子、
/// 工作量证明只算一次并按 installId 缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PreferencesRepository> makePrefs() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    return repo;
  }

  int solves = 0;
  Future<String> solve(String installId) async {
    solves++;
    return solveInstallPow(installId);
  }

  setUp(() => solves = 0);

  test('同一机器标识：换一份全新偏好（等同重装 / 清数据）installId 不变', () async {
    Future<String?> reader() async => '4c4c4544-0042-3510-8050-b4c04f4e3732';
    final InstallAttestation first = await resolveInstallAttestation(
      await makePrefs(),
      readMachineId: reader,
      solvePow: solve,
    );
    final InstallAttestation reinstalled = await resolveInstallAttestation(
      await makePrefs(),
      readMachineId: reader,
      solvePow: solve,
    );
    expect(reinstalled.installId, first.installId);
    expect(
      reinstalled.identity.pubkeyBase64Url,
      first.identity.pubkeyBase64Url,
    );
    expect(
      first.installId,
      InstallIdentity.fromMachineId(
        '4c4c4544-0042-3510-8050-b4c04f4e3732',
      ).installId,
    );
    expect(installPowValid(first.installId, first.powNonce), isTrue);
  });

  test('不同机器标识 → 不同 installId', () async {
    final PreferencesRepository prefs = await makePrefs();
    final InstallAttestation a = await resolveInstallAttestation(
      prefs,
      readMachineId: () async => 'machine-aaaa-0001',
      solvePow: solve,
    );
    final InstallAttestation b = await resolveInstallAttestation(
      prefs,
      readMachineId: () async => 'machine-bbbb-0002',
      solvePow: solve,
    );
    expect(a.installId, isNot(b.installId));
  });

  test('取不到 / 不可用的机器标识回退本机随机种子：同一份偏好稳定，换偏好就变', () async {
    final PreferencesRepository prefs = await makePrefs();
    for (final Future<String?> Function() reader
        in <Future<String?> Function()>[
          () async => null,
          () async => '00000000-0000-0000-0000-000000000000',
        ]) {
      final InstallAttestation a = await resolveInstallAttestation(
        prefs,
        readMachineId: reader,
        solvePow: solve,
      );
      expect(
        a.installId,
        InstallIdentity.fromLocalRandom(
          await prefs.ensureUsageStatsInstallId(),
        ).installId,
      );
    }
    final InstallAttestation other = await resolveInstallAttestation(
      await makePrefs(),
      readMachineId: () async => null,
      solvePow: solve,
    );
    expect(
      other.installId,
      isNot(
        InstallIdentity.fromLocalRandom(
          await prefs.ensureUsageStatsInstallId(),
        ).installId,
      ),
    );
  });

  test('工作量证明只算一次：缓存属于当前 installId 时复用，installId 变了才重算', () async {
    final PreferencesRepository prefs = await makePrefs();
    Future<String?> reader() async => 'pow-cache-machine-id';
    final InstallAttestation a = await resolveInstallAttestation(
      prefs,
      readMachineId: reader,
      solvePow: solve,
    );
    final InstallAttestation b = await resolveInstallAttestation(
      prefs,
      readMachineId: reader,
      solvePow: solve,
    );
    expect(solves, 1);
    expect(b.powNonce, a.powNonce);
    expect(prefs.usageStatsInstallPowFor(a.installId), a.powNonce);
    await resolveInstallAttestation(
      prefs,
      readMachineId: () async => 'another-machine-id',
      solvePow: solve,
    );
    expect(solves, 2);
    // 缓存里的 nonce 被篡改成不满足难度的值 → 重算，不带着坏 nonce 上报。
    await prefs.setUsageStatsInstallPow(a.installId, 'x');
    final InstallAttestation c = await resolveInstallAttestation(
      prefs,
      readMachineId: reader,
      solvePow: solve,
    );
    expect(solves, 3);
    expect(installPowValid(c.installId, c.powNonce), isTrue);
  });

  test('Linux 机器标识：/etc/machine-id 优先，不可用时回退 dbus 那份', () {
    expect(
      pickLinuxMachineId(
        (String path) => <String, String>{
          '/etc/machine-id': 'aaaabbbbccccdddd\n',
          '/var/lib/dbus/machine-id': 'eeeeffff00001111',
        }[path],
      ),
      'aaaabbbbccccdddd',
    );
    expect(
      pickLinuxMachineId(
        (String path) => <String, String>{
          '/etc/machine-id': 'uninitialized\n',
          '/var/lib/dbus/machine-id': 'eeeeffff00001111',
        }[path],
      ),
      'eeeeffff00001111',
    );
    expect(pickLinuxMachineId((String _) => null), isNull);
  });
}
