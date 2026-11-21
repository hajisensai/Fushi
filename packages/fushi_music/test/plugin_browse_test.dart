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

/// 原生浏览（`browse`）契约（docs/specs/2026-10-28-music-plugins.md §4）：筛选项定义、带条件
/// 分页列表、分类目录；作品的可点标签 / 结构化信息 / 关联作品 / 曲目分组；推荐段的「查看全部」条件。
const String browseJs = r'''
const tags = [
  { facet: 'tag', id: '12', name: '低语' },
  { facet: 'va', id: 'v1', name: '某声优' },
  { facet: 'tag', id: '12', name: '重复' },
  { facet: 'tag', name: '缺 id' },
  'junk',
];
module.exports = {
  search() { return { items: [], hasMore: false }; },
  album() {
    return {
      album: {
        id: 'RJ1', title: '作品', tags,
        code: 'RJ01000001', language: '简体中文', durationMs: 3600000, hasSubtitles: true,
        sourceUrl: 'https://asmr.example.com/work/RJ1',
        related: [
          { label: '原版', album: { id: 'RJ0', title: '原作', coverUrl: 'https://img.example.com/0.jpg',
                                   related: [{ album: { id: 'deep', title: '不递归' } }] } },
          { label: '坏', album: { title: '缺 id' } },
        ],
      },
      tracks: [
        { id: 't1', title: '正篇 1', group: '正篇' },
        { id: 't2', title: '环境音', group: '  环境音版  ' },
        { id: 't3', title: '无组' },
      ],
    };
  },
  stream() {}, lyrics() { return null; },
  home() {
    return { sections: [
      { id: 'sub', title: '简中 · 带字幕', kind: 'albums',
        items: [{ id: 'a1', title: 'A1' }],
        more: { filters: [{ facet: 'lang', id: 'zh', name: '简中' }], toggles: ['subtitle'], sort: 'new' } },
      { id: 'plain', title: '无条件', kind: 'albums', items: [{ id: 'a2', title: 'A2' }], more: 'junk' },
    ] };
  },
  browse(a) {
    if (a.op === 'schema') {
      return {
        facets: [{ id: 'tag', label: '标签' }, { id: 'va', label: '声优' }, { id: 'tag', label: '重复' }, { label: '缺 id' }],
        sorts: [{ id: 'new', label: '最新' }, { id: 'sales', label: '销量' }],
        toggles: [{ id: 'subtitle', label: '带字幕' }],
        choices: [
          { id: 'lang', label: '语言', values: [{ id: 'ja', label: '日语' }, { id: 'zh', label: '简中' }] },
          { id: 'empty', label: '空', values: [] },
        ],
      };
    }
    if (a.op === 'list') {
      if (a.query.sort === 'boom') throw new Error('炸了');
      const items = [];
      for (let i = 0; i < a.pageSize; i++) {
        items.push({ id: `p${a.page}-${i}`, title: 'W', tags: [{ facet: 'tag', id: '12', name: '低语' }],
                     coverUrl: i === 0 ? 'https://evil.com/x.jpg' : undefined });
      }
      items.push({ title: '缺 id' });
      return { items, hasMore: a.page < 1, total: 99, echo: a.query };
    }
    if (a.op === 'catalog') {
      return {
        items: [
          { id: '12', name: '低语', count: 30 },
          { id: '12', name: '重复', count: 1 },
          { id: '13', name: a.query ? '过滤:' + a.query : '耳舐', count: -1, facet: 'other' },
          { name: '缺 id' },
        ],
        hasMore: true,
      };
    }
    return null;
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-browse-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(MusicPluginManager, MusicPluginSource)> install({
    bool browse = true,
  }) async {
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
        caps: <String>[
          'search',
          'album',
          'stream',
          'lyrics',
          'home',
          if (browse) 'browse',
        ],
      ),
      <String, String>{'main.js': browseJs},
    );
    await m.install(zip, (await m.inspect(zip)).digest);
    return (m, m.source('moe.test.fake'));
  }

  test('schema：坏项 / 重复 id / 空单选丢弃', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginBrowseSchema schema = await src.browseSchema();
    expect(schema.facets.map((MusicPluginBrowseOption f) => f.id), <String>[
      'tag',
      'va',
    ]);
    expect(schema.facetLabel('va'), '声优');
    expect(schema.sorts.map((MusicPluginBrowseOption s) => s.id), <String>[
      'new',
      'sales',
    ]);
    expect(schema.toggles.single.id, 'subtitle');
    expect(schema.choices.single.id, 'lang');
    expect(schema.choices.single.values.length, 2);
    await m.dispose();
  });

  test('list：条件原样传给插件、坏条目丢弃、hasMore 续页、越权封面清空', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    const MusicPluginTag whisper = MusicPluginTag(
      facet: 'tag',
      id: '12',
      name: '低语',
    );
    final MusicPluginBrowseQuery q = const MusicPluginBrowseQuery()
        .withFilter(whisper)
        .withToggle('subtitle', on: true)
        .withSort('sales')
        .withChoice('lang', 'zh');
    final MusicPluginBrowseResult p0 = await src.browseList(q, pageSize: 5);
    expect(p0.kind, MusicPluginHomeKind.albums);
    expect(p0.items.length, 5, reason: '缺 id 的条目丢弃');
    expect(p0.hasMore, isTrue);
    expect(p0.total, 99);
    final MusicPluginAlbum first = p0.items.first as MusicPluginAlbum;
    expect(first.coverUrl, isNull, reason: '越权封面清空');
    expect(first.tags.single, whisper);
    final MusicPluginBrowseResult p1 = await src.browseList(
      q,
      page: 1,
      pageSize: 5,
    );
    expect((p1.items.first as MusicPluginAlbum).id, 'p1-0');
    expect(p1.hasMore, isFalse);
    await expectLater(
      src.browseList(q.withSort('boom')),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('query：增删条件、开关、单选不改原对象，toJson / fromJson 往返', () {
    const MusicPluginTag a = MusicPluginTag(facet: 'tag', id: '1', name: 'A');
    const MusicPluginTag b = MusicPluginTag(facet: 'va', id: '1', name: 'B');
    const MusicPluginBrowseQuery base = MusicPluginBrowseQuery();
    final MusicPluginBrowseQuery q = base
        .withFilter(a)
        .withFilter(b)
        .withFilter(a)
        .withToggle('subtitle', on: true)
        .withChoice('lang', 'ja')
        .withSort('new');
    expect(base.filters, isEmpty);
    expect(q.filters, <MusicPluginTag>[a, b], reason: '同一条件只加一次');
    final MusicPluginBrowseQuery back = MusicPluginBrowseQuery.fromJson(
      q.toJson(),
    );
    expect(back.filters, q.filters);
    expect(back.sort, 'new');
    expect(back.toggles, <String>{'subtitle'});
    expect(back.choices, <String, String>{'lang': 'ja'});
    final MusicPluginBrowseQuery off = q
        .withoutFilter(a)
        .withToggle('subtitle', on: false)
        .withChoice('lang', null)
        .withSort(null);
    expect(off.filters, <MusicPluginTag>[b]);
    expect(off.toggles, isEmpty);
    expect(off.choices, isEmpty);
    expect(off.sort, isNull);
  });

  test('catalog：facet 按请求记、按 id 去重、负计数当缺失、query 透传', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginPage<MusicPluginCatalogEntry> page = await src
        .browseCatalog('tag', query: ' 耳 ');
    expect(page.items.map((MusicPluginCatalogEntry e) => e.tag.id), <String>[
      '12',
      '13',
    ]);
    expect(page.items.first.count, 30);
    expect(page.items[1].count, isNull);
    expect(page.items[1].tag.facet, 'tag');
    expect(page.items[1].tag.name, '过滤:耳');
    expect(page.hasMore, isTrue);
    await m.dispose();
  });

  test('album：可点标签去重、结构化信息、关联作品不递归、曲目分组', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final ({MusicPluginAlbum album, List<MusicPluginTrack> tracks}) r =
        await src.album('RJ1');
    final MusicPluginAlbum a = r.album;
    expect(a.tags.map((MusicPluginTag t) => t.name), <String>['低语', '某声优']);
    expect(a.code, 'RJ01000001');
    expect(a.language, '简体中文');
    expect(a.durationMs, 3600000);
    expect(a.hasSubtitles, isTrue);
    expect(a.sourceUrl, 'https://asmr.example.com/work/RJ1');
    expect(a.related.length, 1);
    expect(a.related.single.label, '原版');
    expect(a.related.single.album.id, 'RJ0');
    expect(a.related.single.album.related, isEmpty);
    expect(r.tracks.map((MusicPluginTrack t) => t.group), <String?>[
      '正篇',
      '环境音版',
      null,
    ]);
    await m.dispose();
  });

  test('home：声明 browse 时段带「查看全部」条件，坏条件丢弃', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final List<MusicPluginHomeSection> secs = await src.home();
    final MusicPluginBrowseQuery? more = secs.first.more;
    expect(more, isNotNull);
    expect(more!.filters.single.id, 'zh');
    expect(more.toggles, <String>{'subtitle'});
    expect(more.sort, 'new');
    expect(secs[1].more, isNull);
    await m.dispose();
  });

  test('home：没声明 browse 的插件不认「查看全部」条件', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install(
      browse: false,
    );
    final List<MusicPluginHomeSection> secs = await src.home();
    expect(secs.first.more, isNull);
    await expectLater(src.browseSchema(), throwsA(isA<MusicPluginException>()));
    await m.dispose();
  });

  test('sourceUrl 只收 https', () {
    MusicPluginAlbum? parse(Object? url) => MusicPluginAlbum.fromJson(
      <String, Object?>{'id': 'x', 'title': 'X', 'sourceUrl': url},
    );
    expect(parse('http://a.example.com/')?.sourceUrl, isNull);
    expect(parse('javascript:alert(1)')?.sourceUrl, isNull);
    expect(parse('https://')?.sourceUrl, isNull);
    expect(parse(42)?.sourceUrl, isNull);
    expect(
      parse('https://a.example.com/w')?.sourceUrl,
      'https://a.example.com/w',
    );
  });
}
