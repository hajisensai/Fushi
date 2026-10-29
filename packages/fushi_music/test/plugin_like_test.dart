import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show
        buildPlugin,
        manifest,
        fakePublicResolve,
        noRedirectProbe,
        testVaultKey;

/// 「喜欢」（`like`）契约（docs/specs/2026-10-28-music-plugins.md §4）：未登录 list 为 null、
/// set 抛错；登录后 list 给喜欢集合与平台歌单，set 改得回来；越权歌单封面清空。
const String likeJs = r'''
module.exports = {
  search() { return { items: [], hasMore: false }; },
  async account() {
    return (await fushi.credentials.get('c')) ? { loggedIn: true } : { loggedIn: false };
  },
  async login(a) { await fushi.credentials.set('c', '1'); return { state: 'done' }; },
  async like(a) {
    const loggedIn = !!(await fushi.credentials.get('c'));
    const ids = JSON.parse((await fushi.storage.get('liked')) || '["1", 2, ""]');
    if (a.op === 'list') {
      if (!loggedIn) return null;
      return { ids, playlist: { id: 'fav', title: '我喜欢的音乐', coverUrl: 'https://evil.com/c.jpg' } };
    }
    if (a.op === 'set') {
      if (!loggedIn) throw new Error('请先登录');
      const next = ids.filter((x) => String(x) !== a.id);
      if (a.liked) next.push(a.id);
      await fushi.storage.set('liked', JSON.stringify(next));
      return null;
    }
    throw new Error('bad op');
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-like-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(MusicPluginManager, MusicPluginSource)> install() async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    final Uint8List zip = buildPlugin(
      manifest(
        caps: const <String>['search', 'login', 'account', 'like'],
        perms: const <String>['network', 'storage', 'credentials'],
      ),
      <String, String>{'main.js': likeJs},
    );
    final MusicPluginPackageInfo info = await m.inspect(zip);
    expect(info.manifest.can(MusicPluginCapability.like), isTrue);
    await m.install(zip, info.digest);
    return (m, m.source('moe.test.fake'));
  }

  test('like：未登录 list 为 null、set 抛错；登录后读写喜欢集合', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    expect(await src.likes(), isNull);
    await expectLater(
      src.setLiked('3', liked: true),
      throwsA(isA<MusicPluginException>()),
    );
    await src.loginSubmit(
      'x',
      null,
      'windows',
      action: 'submit',
      inputs: const <String, String>{},
    );
    final MusicPluginLikes? first = await src.likes();
    expect(first!.trackIds, <String>{'1', '2'}, reason: '数字 id 转字符串、空串丢弃');
    expect(first.playlist!.id, 'fav');
    expect(first.playlist!.coverUrl, isNull, reason: '封面不在网络授权内');
    await src.setLiked('3', liked: true);
    await src.setLiked('1', liked: false);
    expect((await src.likes())!.trackIds, <String>{'2', '3'});
    await m.dispose();
  });

  test('like 能力必须随登录能力声明，否则拒装', () async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    final Uint8List zip = buildPlugin(
      manifest(caps: const <String>['search', 'like']),
      <String, String>{'main.js': likeJs},
    );
    await expectLater(m.inspect(zip), throwsA(isA<MusicPluginException>()));
    await m.dispose();
  });
}
