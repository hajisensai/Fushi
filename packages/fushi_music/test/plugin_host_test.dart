import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 现场打一个插件包：manifest + 源码 + files.json（sha256）。
Uint8List buildPlugin(Map<String, Object?> manifest, Map<String, String> js) {
  final Map<String, List<int>> files = <String, List<int>>{
    'manifest.json': utf8.encode(jsonEncode(manifest)),
    for (final MapEntry<String, String> e in js.entries)
      e.key: utf8.encode(e.value),
  };
  final Archive a = Archive();
  for (final MapEntry<String, List<int>> e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final List<int> listing = utf8.encode(
    jsonEncode(<String, Object?>{
      'files': <String, String>{
        for (final MapEntry<String, List<int>> e in files.entries)
          e.key: sha256.convert(e.value).toString(),
      },
    }),
  );
  a.addFile(ArchiveFile('files.json', listing.length, listing));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Map<String, Object?> manifest({
  List<String> caps = const <String>['search', 'album', 'stream', 'lyrics'],
  List<String> perms = const <String>['network', 'storage'],
}) => <String, Object?>{
  'schema': 1,
  'id': 'moe.test.fake',
  'name': 'Fake',
  'version': '1.2.3',
  'api': 1,
  'entry': 'main.js',
  'capabilities': caps,
  'searchTypes': <String>['song'],
  'permissions': perms,
  'network': <String, Object?>{
    'domains': <String>['api.example.com', '*.cdn.example.com'],
    'methods': <String>['GET', 'POST'],
  },
};

const String fakeJs = r'''
module.exports = {
  async search(a) {
    const r = await fushi.http.request({
      url: 'https://api.example.com/search?q=' + encodeURIComponent(a.query) + '&p=' + a.page,
      responseType: 'json',
    });
    let n = Number((await fushi.storage.get('count')) || 0) + 1;
    await fushi.storage.set('count', String(n));
    return {
      items: r.json.songs.map((s) => ({
        id: String(s.id), title: s.name, artists: [{ name: s.ar }], durationMs: s.dt,
        coverUrl: s.pic,
      })).concat([{ title: 'no id dropped' }]),
      hasMore: true, total: 99, calls: n,
    };
  },
  async album(a) {
    return { album: { id: a.id, title: 'Album ' + a.id, coverUrl: 'https://p1.cdn.example.com/a.jpg' },
             tracks: [{ id: '1', title: 'T1' }, { id: '2', title: 'T2', coverUrl: 'https://evil.com/x.jpg' }] };
  },
  async stream(a) {
    if (a.id === 'bad') return { url: 'https://evil.com/a.mp3' };
    if (a.id === 'vip') throw new Error('需要会员');
    return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3?q=' + a.quality, expiresAt: 123, codec: 'mp3' };
  },
  async lyrics(a) {
    return { original: { format: 'yrc', text: '[0,1000](0,500,0)夜(500,500,0)曲' },
             translation: { format: 'lrc', text: '[00:00.00]Nocturne' } };
  },
};
''';

/// 测试用解析：所有主机都解析到一个公网地址（不打真 DNS）。
Future<List<InternetAddress>> fakePublicResolve(String host) async =>
    <InternetAddress>[InternetAddress('93.184.216.34')];

/// 测试用媒体探测：不是重定向（不打真网络）。
Future<String?> noRedirectProbe(Uri uri, Map<String, String> headers) async =>
    null;

void main() {
  late Directory root;
  late List<Map<String, Object?>> requests;
  late List<String> logs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fmp-host-');
    requests = <Map<String, Object?>>[];
    logs = <String>[];
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MusicPluginManager makeManager() => MusicPluginManager(
    rootDir: root,
    httpClientFactory: HttpClient.new,
    resolver: fakePublicResolve,
    mediaProbe: noRedirectProbe,
    log: (String id, String level, String message) =>
        logs.add('$id/$level: $message'),
    httpPerformer: (Map<String, Object?> args) async {
      requests.add(args);
      final String body = jsonEncode(<String, Object?>{
        'songs': <Object?>[
          <String, Object?>{
            'id': 7,
            'name': '夜曲',
            'ar': '周杰伦',
            'dt': 226000,
            'pic': 'https://p2.cdn.example.com/c.jpg',
          },
          <String, Object?>{
            'id': 8,
            'name': '越权封面',
            'ar': 'x',
            'pic': 'https://evil.com/c.jpg',
          },
        ],
      });
      return <String, Object?>{
        'status': 200,
        'url': args['url'],
        'headers': <String, String>{},
        'bodyBase64': base64.encode(utf8.encode(body)),
      };
    },
  );

  test('runtime is available on this platform', () {
    expect(MusicPluginManager.isSupported, isTrue);
    expect(MusicPluginNative.apiVersion, 1);
  });

  test('inspect → install → list → typed calls → uninstall', () async {
    final MusicPluginManager m = makeManager();
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': fakeJs,
    });
    final MusicPluginPackageInfo info = await m.inspect(zip);
    expect(info.manifest.id, 'moe.test.fake');
    expect(info.signer, isNull);
    await expectLater(
      m.install(zip, 'not-the-digest'),
      throwsA(isA<MusicPluginException>()),
    );
    await m.install(zip, info.digest);

    final List<InstalledMusicPlugin> installed = await m.list();
    expect(installed.single.id, 'moe.test.fake');
    expect(installed.single.usable, isTrue);

    final MusicPluginSource src = m.source('moe.test.fake');
    final MusicPluginPage<MusicPluginTrack> page = await src.searchTracks(
      '夜曲',
      page: 2,
    );
    expect(page.items.map((MusicPluginTrack t) => t.title), <String>[
      '夜曲',
      '越权封面',
    ]);
    expect(page.items.first.artistText, '周杰伦');
    expect(page.items.first.durationMs, 226000);
    expect(page.items.first.coverUrl, 'https://p2.cdn.example.com/c.jpg');
    expect(page.items.last.coverUrl, isNull, reason: '越权封面应被丢弃');
    expect(page.hasMore, isTrue);
    expect(page.total, 99);
    expect(requests.single['method'], 'GET');
    expect(
      requests.single['url'],
      'https://api.example.com/search?q=%E5%A4%9C%E6%9B%B2&p=2',
    );

    // storage 持久化到插件存储文件。
    await src.searchTracks('again');
    final Map<String, Object?> stored =
        jsonDecode(m.storageFileFor('moe.test.fake').readAsStringSync())
            as Map<String, Object?>;
    expect(stored['count'], '2');

    final ({MusicPluginAlbum album, List<MusicPluginTrack> tracks}) album =
        await src.album('42');
    expect(album.album.title, 'Album 42');
    expect(album.tracks.first.albumTitle, 'Album 42');
    expect(album.tracks.first.coverUrl, 'https://p1.cdn.example.com/a.jpg');
    expect(
      album.tracks.last.coverUrl,
      'https://p1.cdn.example.com/a.jpg',
      reason: '越权的曲目封面回落到专辑封面',
    );

    final MusicPluginStream s = await src.stream(
      '7',
      quality: MusicPluginQuality.lossless,
    );
    expect(s.url, 'https://m1.cdn.example.com/7.mp3?q=lossless');
    expect(s.expiresAt, 123);
    await expectLater(
      src.stream('bad'),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('网络授权'),
        ),
      ),
    );
    await expectLater(
      src.stream('vip'),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('需要会员'),
        ),
      ),
    );

    final MusicPluginLyrics? lyrics = await src.lyrics('7');
    expect(lyrics!.original!.format, 'yrc');
    expect(lyrics.translation!.text, '[00:00.00]Nocturne');
    final LyricTimeline t = FushiLyrics.parse(
      Uint8List.fromList(utf8.encode(lyrics.original!.text)),
      hint: lyrics.original!.format,
    );
    expect(t.lines, isNotEmpty);

    await m.setEnabled('moe.test.fake', false);
    expect((await m.list()).single.usable, isFalse);
    await m.uninstall('moe.test.fake');
    expect(await m.list(), isEmpty);
    expect(m.storageFileFor('moe.test.fake').existsSync(), isFalse);
    await m.dispose();
  });

  test('tampered install is reported by list and refused by open', () async {
    final MusicPluginManager m = makeManager();
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': fakeJs,
    });
    await m.install(zip, (await m.inspect(zip)).digest);
    File(
      '${root.path}/moe.test.fake/main.js',
    ).writeAsStringSync('module.exports = {};');
    final InstalledMusicPlugin p = (await m.list()).single;
    expect(p.info, isNull);
    expect(p.error, contains('哈希'));
    await expectLater(
      m.source('moe.test.fake').searchTracks('x'),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('runaway plugin is killed and rebuilt on next use', () async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
      budgetMs: 300,
    );
    const String js = r'''
      module.exports = {
        search(a) { if (a.query === 'hang') { for (;;) {} } return { items: [], hasMore: false }; },
        album() {}, stream() {}, lyrics() { return null; },
      };
    ''';
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': js,
    });
    await m.install(zip, (await m.inspect(zip)).digest);
    final MusicPluginSource src = m.source('moe.test.fake');
    await expectLater(
      src.searchTracks('hang'),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('CPU'),
        ),
      ),
    );
    expect((await src.searchTracks('ok')).items, isEmpty);
    expect(await src.lyrics('1'), isNull);
    await m.dispose();
  });

  test('private address detection', () {
    for (final String a in <String>[
      '127.0.0.1',
      '10.1.2.3',
      '172.20.0.1',
      '192.168.0.1',
      '169.254.0.1',
      '100.64.1.1',
      '::1',
      'fd00::1',
      'fe80::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(
        isMusicPluginPrivateAddress(InternetAddress(a)),
        isTrue,
        reason: a,
      );
    }
    expect(isMusicPluginPrivateAddress(InternetAddress('1.1.1.1')), isFalse);
    expect(
      isMusicPluginPrivateAddress(InternetAddress('2606:4700::1111')),
      isFalse,
    );
  });
}
