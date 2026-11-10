import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「下载执行设备」偏好按 URL 存。某个地址改归另一台 host 后，偏好若还指着它，
/// 就会把下载静默投给新 host——改写为旧 host 剩余的代表地址，没剩的就回本机。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  const String moved = 'http://10.0.0.5:38765';

  test('偏好指向被改归的地址 → 改写为旧 host 剩余的代表地址', () async {
    await prefs.setDownloadExecutionHostUrl(moved);
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[
        FushiClientUrl(url: moved, hostId: 'B'),
        FushiClientUrl(
          url: 'https://10.0.0.9:38765',
          hostId: 'A',
          learned: true,
        ),
        FushiClientUrl(url: 'https://a.example', hostId: 'A'),
      ],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, 'https://a.example');
  });

  test('旧 host 一条地址都不剩 → 清空（回本机）', () async {
    await prefs.setDownloadExecutionHostUrl(moved);
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[FushiClientUrl(url: moved, hostId: 'B')],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, isEmpty);
  });

  test('偏好指向别的地址 → 不动', () async {
    await prefs.setDownloadExecutionHostUrl('https://a.example');
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[FushiClientUrl(url: moved, hostId: 'B')],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, 'https://a.example');
  });
}
