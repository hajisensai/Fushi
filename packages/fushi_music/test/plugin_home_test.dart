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

/// 推荐（`home`）与我的歌单（`library`）契约（docs/specs/2026-10-28-music-plugins.md §4）：
/// 坏段丢弃、空段丢弃、段数 / 条数上限、未登录空页。
const String homeJs = r'''
module.exports = {
  search() { return { items: [], hasMore: false }; },
  album() {}, stream() {}, lyrics() { return null; },
  async account() {
    return (await fushi.credentials.get('c')) ? { loggedIn: true, name: 'A' } : { loggedIn: false };
  },
  async login(a) { await fushi.credentials.set('c', '1'); return { state: 'done' }; },
  home() {
    const many = [];
    for (let i = 0; i < 80; i++) many.push({ id: 't' + i, title: 'T' + i, artists: [] });
    const secs = [
      { id: 'daily', title: '每日推荐', kind: 'tracks', items: many },
      { id: 'pl', title: '推荐歌单', subtitle: '', kind: 'playlists',
        items: [{ id: 'p1', title: 'P1', coverUrl: 'https://img.example.com/a.jpg',
                  previewTracks: [
                    { id: 'r1', title: 'R1', artists: [{ name: 'X' }], coverUrl: 'https://evil.com/c.jpg' },
                    { id: 'bad' },
                    'junk',
                    { id: 'r2', title: 'R2', artists: [] },
                    { id: 'r3', title: 'R3', artists: [{ name: 'Y' }, { name: 'Z' }] },
                    { id: 'r4', title: 'R4', artists: [] },
                  ] },
                { id: 'p2', title: 'P2', coverUrl: 'https://evil.com/b.jpg' }] },
      { id: 'empty', title: '空', kind: 'albums', items: [] },
      { id: 'bad', title: '坏', kind: 'videos', items: [{ id: 'x' }] },
      { title: '缺 id', kind: 'tracks', items: many },
    ];
    for (let i = 0; i < 20; i++) secs.push({ id: 'more' + i, title: 'M' + i, kind: 'albums', items: [{ id: 'a' + i, title: 'A' + i, artists: [] }] });
    return { sections: secs };
  },
  async library(a) {
    if (!(await fushi.credentials.get('c'))) return { items: [], hasMore: false };
    return { items: [{ id: 'like', title: '我喜欢的音乐' }, { id: 'mine', title: 'Mine' }], hasMore: a.page === 0 };
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-home-'));
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
        caps: const <String>[
          'search',
          'album',
          'stream',
          'lyrics',
          'login',
          'account',
          'home',
          'library',
        ],
        perms: const <String>['network', 'credentials'],
      ),
      <String, String>{'main.js': homeJs},
    );
    await m.install(zip, (await m.inspect(zip)).digest);
    return (m, m.source('moe.test.fake'));
  }

  test('home：坏段 / 空段丢弃，段数与条数封顶，越权封面清空', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final List<MusicPluginHomeSection> secs = await src.home();
    expect(secs.length, MusicPluginHomeSection.maxSections);
    expect(secs.first.id, 'daily');
    expect(secs.first.kind, MusicPluginHomeKind.tracks);
    expect(secs.first.items.length, MusicPluginHomeSection.maxItems);
    final MusicPluginHomeSection pl = secs[1];
    expect(pl.subtitle, isNull, reason: '空副标题当没有');
    final List<MusicPluginPlaylist> lists = pl.items
        .cast<MusicPluginPlaylist>();
    expect(lists.map((MusicPluginPlaylist p) => p.coverUrl), <String?>[
      null,
      null,
    ], reason: '测试清单的网络授权不含这两个域');
    final List<MusicPluginTrack> preview = lists.first.previewTracks;
    expect(preview.map((MusicPluginTrack t) => t.id), <String>[
      'r1',
      'r2',
      'r3',
    ], reason: '坏条目丢弃、截断到 3 条');
    expect(preview.first.artistText, 'X');
    expect(
      preview.map((MusicPluginTrack t) => t.coverUrl),
      everyElement(isNull),
      reason: '预览曲目不带封面',
    );
    expect(lists[1].previewTracks, isEmpty);
    expect(
      secs.map((MusicPluginHomeSection s) => s.id),
      isNot(contains(anyOf('empty', 'bad'))),
    );
    await m.dispose();
  });

  test('library：未登录空页，登录后列出', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    expect((await src.library()).items, isEmpty);
    await src.loginSubmit(
      'x',
      null,
      'windows',
      action: 'submit',
      inputs: const <String, String>{},
    );
    final MusicPluginPage<MusicPluginPlaylist> page = await src.library();
    expect(page.items.map((MusicPluginPlaylist p) => p.id), <String>[
      'like',
      'mine',
    ]);
    expect(page.hasMore, isTrue);
    await m.dispose();
  });
}
