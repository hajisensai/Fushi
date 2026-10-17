import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3147（issue #1997 问题一）：互联「上传 / 下载配置」直接用单例后端，不经同步
/// 编排。以前它不重载配置，拿的是进程里上一次留下的候选与 token——重新配对只改了库，
/// 旧 token 照旧打到 host → 401 →「对方设备已拒绝本机的配对凭据」，重新配对也没用；
/// 直到某次词典同步顺手 restoreAuth 了才恢复。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  final List<({String url, String token})> probed =
      <({String url, String token})>[];

  setUp(() {
    db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    repo = SyncRepository(db);
    probed.clear();
  });

  tearDown(() => db.close());

  InterconnectSyncBackend backend() => InterconnectSyncBackend.withProbe(
        (String url, String token) async {
          probed.add((url: url, token: token));
          return true;
        },
      );

  Future<void> pair(String url, String token) async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: url, enabled: true, token: token),
    ]);
  }

  test('下载配置按库里此刻的配对重建会话（重新配对后不再用旧 token）', () async {
    final InterconnectSyncBackend b = backend();
    await pair('http://10.0.0.1:8765', 'old-token');
    await b.restoreAuth(repo);
    await b.ensureResolved();
    expect(b.activeBaseUrl, 'http://10.0.0.1:8765');

    // 用户按提示「重新配对」：库里换成新地址 + 新 token，单例没人通知。
    await pair('http://10.0.0.2:8765', 'new-token');
    probed.clear();

    // 明文会话本地短路返回 null（整份配置只走 HTTPS），但会话必须先按新配置重建。
    expect(await b.getRemoteProfileJson(repo: repo), isNull);
    expect(b.activeBaseUrl, 'http://10.0.0.2:8765');
    expect(probed.map((p) => p.token), everyElement('new-token'));
  });

  test('上传配置同样先重载会话', () async {
    final InterconnectSyncBackend b = backend();
    await pair('http://10.0.0.1:8765', 'old-token');
    await b.restoreAuth(repo);
    await b.ensureResolved();

    await pair('http://10.0.0.3:8765', 'new-token');
    expect(await b.putRemoteProfileJson('{}', repo: repo), isNull);
    expect(b.activeBaseUrl, 'http://10.0.0.3:8765');
  });

  test('一台对端都没配对时如实报「未配对」，不是「凭据被拒」', () async {
    final InterconnectSyncBackend b = backend();
    await expectLater(
      b.getRemoteProfileJson(repo: repo),
      throwsA(
        isA<SyncAuthError>().having(
          (SyncAuthError e) => e.kind,
          'kind',
          SyncAuthFailureKind.pairingNotConfigured,
        ),
      ),
    );
  });
}
