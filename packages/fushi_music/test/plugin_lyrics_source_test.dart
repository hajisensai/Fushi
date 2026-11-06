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

/// 歌词来源能力（docs/specs/2026-10-30-lyrics-plugins.md §2）：纯歌词插件的搜索 / 取词、
/// 不可信候选清洗、不出现在音乐来源入口。
const String lyricsJs = r'''
module.exports = {
  lyricsSearch(a) {
    if (a.title === 'boom') throw new Error('upstream down');
    if (a.title === 'none') return { items: [] };
    const items = [
      { title: '  ' + a.title + '  ', artist: a.artist, durationMs: a.durationMs, ref: { id: 7, k: 'x' } },
      { title: 'no ref' },
      { ref: 1 },
      { title: 'neg', durationMs: -5, ref: 'r2' },
      { title: 'huge', ref: 'x'.repeat(3000) },
      { title: 'q:' + a.query, ref: 'r3' },
    ];
    for (let i = 0; i < 30; i++) items.push({ title: 't' + i, ref: 'p' + i });
    return { items };
  },
  lyricsFetch(a) {
    if (a.ref === 'missing') return null;
    if (a.ref === 'blank') return { original: { format: 'lrc', text: '  ' } };
    return {
      original: { format: 'lrc', text: '[00:01.00]hello ' + JSON.stringify(a.ref) },
      translation: { format: 'lrc', text: '[00:01.00]你好', language: 'zh-Hans' },
    };
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-lyrics-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MusicPluginManager newManager() => MusicPluginManager(
    rootDir: root,
    vaultKey: testVaultKey,
    httpClientFactory: HttpClient.new,
    resolver: fakePublicResolve,
    mediaProbe: noRedirectProbe,
    log: (_, _, _) {},
  );

  Future<void> install(
    MusicPluginManager m, {
    List<String> caps = const <String>['lyricsSearch', 'lyricsFetch'],
  }) async {
    final Uint8List zip = buildPlugin(
      manifest(caps: caps, perms: const <String>['network']),
      <String, String>{'main.js': lyricsJs},
    );
    final MusicPluginPackageInfo info = await m.inspect(zip);
    await m.install(zip, info.digest);
  }

  test('lyricsSearch：清洗候选、丢弃坏项、最多 20 条；lyricsFetch 回传 ref', () async {
    final MusicPluginManager m = newManager();
    await install(m);
    final MusicPluginSource src = m.source('moe.test.fake');
    final List<MusicPluginLyricsCandidate> c = await src.lyricsSearch(
      '夜曲',
      artist: '周杰伦',
      durationMs: 226000,
      query: '夜曲 周杰伦',
    );
    expect(c.length, 20);
    expect(c.first.title, '夜曲', reason: '去首尾空白');
    expect(c.first.artist, '周杰伦');
    expect(c.first.durationMs, 226000);
    expect(c.first.ref, <String, Object?>{'id': 7, 'k': 'x'});
    expect(c[1].title, 'neg');
    expect(c[1].durationMs, isNull, reason: '负时长当缺失');
    expect(
      c.map((MusicPluginLyricsCandidate x) => x.title),
      isNot(contains('huge')),
    );
    expect(c[2].title, 'q:夜曲 周杰伦', reason: 'query 原样传给插件');

    final MusicPluginLyrics? l = await src.lyricsFetch(c.first.ref);
    expect(l!.original!.format, 'lrc');
    expect(l.original!.text, contains('"id":7'), reason: 'ref 原样回传');
    expect(l.translation!.language, 'zh-Hans');
    await m.dispose();
  });

  test('空结果 / null / 空文本当没有；插件抛错照常抛', () async {
    final MusicPluginManager m = newManager();
    await install(m);
    final MusicPluginSource src = m.source('moe.test.fake');
    expect(await src.lyricsSearch('none'), isEmpty);
    expect(await src.lyricsFetch('missing'), isNull);
    expect(await src.lyricsFetch('blank'), isNull);
    await expectLater(
      src.lyricsSearch('boom'),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('纯歌词插件不是音乐来源；有 search 的插件两者都是', () async {
    final MusicPluginManager m = newManager();
    await install(m);
    InstalledMusicPlugin p = (await m.list()).single;
    expect(p.isLyricsSource, isTrue);
    expect(p.isMusicSource, isFalse);
    await expectLater(
      m.source('moe.test.fake').searchTracks('x'),
      throwsA(isA<MusicPluginException>()),
      reason: '没声明 search',
    );
    await m.uninstall('moe.test.fake');

    await install(
      m,
      caps: const <String>['search', 'lyricsSearch', 'lyricsFetch'],
    );
    p = (await m.list()).single;
    expect(p.isLyricsSource, isTrue);
    expect(p.isMusicSource, isTrue);
    await m.dispose();
  });

  test('只声明一个歌词来源能力拒装（需要重建后的原生库）', () async {
    final MusicPluginManager m = newManager();
    final Uint8List zip = buildPlugin(
      manifest(
        caps: const <String>['lyricsSearch'],
        perms: const <String>['network'],
      ),
      <String, String>{'main.js': lyricsJs},
    );
    await expectLater(m.inspect(zip), throwsA(isA<MusicPluginException>()));
    await m.dispose();
  });
}
