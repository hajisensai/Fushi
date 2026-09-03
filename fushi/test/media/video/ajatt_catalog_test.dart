import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';

/// AJATT（subtitles.ajatt.top）页面结构守卫：fixture 是 2026-08-29 从真实页面裁出的
/// （`test/fixtures/ajatt/`，目录页留 4 行、日剧页 3 行、作品页每段 2 行）。站点改版
/// 时这里先红，而不是线上「搜到 0 字幕」。
String _fixture(String name) =>
    File('test/fixtures/ajatt/$name').readAsStringSync();

void main() {
  group('parseAjattCatalogHtml', () {
    test('目录页每行解析出分类 / 作品页路径 / 三个名字 / 修改时间', () {
      final List<AjattCatalogEntry> entries = parseAjattCatalogHtml(
        _fixture('index.html'),
      );
      expect(entries, hasLength(5));
      final AjattCatalogEntry first = entries.first;
      expect(first.type, AjattEntryType.animeTv);
      expect(
        first.pagePath,
        'anime_tv/tensei-shitara-slime-datta-ken-4th-season.html',
      );
      expect(first.name, 'Tensei Shitara Slime Datta Ken 4th Season');
      expect(
        first.englishName,
        'That Time I Got Reincarnated as a Slime Season 4',
      );
      expect(first.japaneseName, '転生したらスライムだった件 第4期');
      expect(first.lastModifiedMs, 1787963826 * 1000);
      // unsorted 行没有英/日文名两格（`entry_name missing_meta` + colspan），
      // 名字仍要解析出来。
      final AjattCatalogEntry unsorted = entries.singleWhere(
        (AjattCatalogEntry e) => e.type == AjattEntryType.unsorted,
      );
      expect(unsorted.pagePath, 'unsorted/37-segundos.html');
      expect(unsorted.name, '37 Segundos');
      expect(unsorted.englishName, isEmpty);
      expect(unsorted.japaneseName, isEmpty);
      expect(unsorted.searchTitles, <String>['37 Segundos']);
      final AjattCatalogEntry kon = entries.singleWhere(
        (AjattCatalogEntry e) => e.pagePath == 'anime_tv/k-on!.html',
      );
      expect(kon.name, 'K-ON!');
      expect(kon.japaneseName, 'けいおん!');
      expect(kon.searchTitles, <String>['K-ON!', 'K-ON!', 'けいおん!']);
    });

    test('日剧页是同一结构，分类落 drama_tv / drama_movie', () {
      final List<AjattCatalogEntry> entries = parseAjattCatalogHtml(
        _fixture('drama.html'),
      );
      expect(entries, hasLength(3));
      expect(entries.first.type, AjattEntryType.dramaTv);
      expect(entries.first.pagePath, 'drama_tv/meitantei-no-mama-de-ite.html');
      expect(entries.first.japaneseName, '名探偵のままでいて');
      expect(
        entries.map((AjattCatalogEntry e) => e.type),
        contains(AjattEntryType.dramaMovie),
      );
    });

    test('结构对不上（非目录页）返回空，不抛', () {
      expect(parseAjattCatalogHtml('<html><body>oops</body></html>'), isEmpty);
      expect(parseAjattCatalogHtml(''), isEmpty);
    });
  });

  group('parseAjattEntryPageHtml', () {
    test('文件表按下载 URL 去重（srt / ass / all 三段重复列同一文件）', () {
      final List<AjattSubtitleFile> files = parseAjattEntryPageHtml(
        _fixture('k-on.html'),
      );
      final Set<String> urls = files
          .map((AjattSubtitleFile f) => f.downloadUrl)
          .toSet();
      expect(urls, hasLength(files.length));
      // fixture：srt 段 2 行 + ass 段 2 行，all 段的 2 行与 srt 段重复。
      expect(files, hasLength(4));
      final AjattSubtitleFile first = files.first;
      expect(first.name, 'けいおん!.S01E01.廃部!.WEBRip.Netflix.ja[cc].srt');
      expect(
        first.downloadUrl,
        startsWith(
          'https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/'
          'refs/heads/main/subtitles/anime_tv/K-ON%21/',
        ),
      );
      expect(first.size, 36114);
      expect(first.lastModifiedMs, 1787659912 * 1000);
      expect(first.extension, 'srt');
      expect(first.isTextSubtitle, isTrue);
      expect(first.episode, 1);
      expect(first.taggedLanguage, 'ja');
      final AjattSubtitleFile ass = files.singleWhere(
        (AjattSubtitleFile f) => f.name.startsWith('[CoalGuys]'),
      );
      expect(ass.extension, 'ass');
      expect(ass.name, '[CoalGuys] K-ON!! S2 - 07 [F58A5866].en+jp.ass');
      expect(ass.episode, 7);
    });

    test('`data-filename` 里的 HTML 实体反转义', () {
      const String html =
          '<table class="file_list_table"><tbody>'
          '<tr data-timestamp="1" data-file-size="2">'
          '<input type="checkbox" data-download-url="https://x/a%26b.srt" '
          'data-filename="Fate &amp; Zero &#39;01&#39;.srt"></tr></tbody></table>';
      final List<AjattSubtitleFile> files = parseAjattEntryPageHtml(html);
      expect(files.single.name, "Fate & Zero '01'.srt");
      expect(files.single.downloadUrl, 'https://x/a%26b.srt');
    });
  });

  group('parseAjattEntryInfoJson', () {
    test('读出 anilist_id 与三个名字', () {
      final AjattEntryInfo? info = parseAjattEntryInfoJson(
        _fixture('kitsuinfo_k-on.json'),
      );
      expect(info, isNotNull);
      expect(info!.entryId, 941);
      expect(info.name, 'K-ON!');
      expect(info.entryType, 'anime_tv');
      expect(info.japaneseName, 'けいおん!');
      expect(info.anilistId, 5680);
    });

    test('anilist_id 缺失 / 0 / 非数字 → null；非 JSON 对象 → null', () {
      expect(parseAjattEntryInfoJson('{"name":"x"}')!.anilistId, isNull);
      expect(parseAjattEntryInfoJson('{"anilist_id":0}')!.anilistId, isNull);
      expect(
        parseAjattEntryInfoJson('{"anilist_id":"abc"}')!.anilistId,
        isNull,
      );
      expect(parseAjattEntryInfoJson('[1,2]'), isNull);
      expect(parseAjattEntryInfoJson('not json'), isNull);
    });
  });

  test('infoUrl：目录名按 URL 分量编码（空格 / 斜杠 / 非 ASCII）', () {
    const AjattCatalogEntry entry = AjattCatalogEntry(
      type: AjattEntryType.animeTv,
      pagePath: 'anime_tv/k-on!.html',
      name: 'K-ON!',
      englishName: '',
      japaneseName: '',
      lastModifiedMs: 0,
    );
    // `!` 是 URL 保留可用字符，`Uri.encodeComponent` 不转义它（站点自己写成
    // `%21`，两种写法 raw.githubusercontent 都认）。
    expect(
      entry.infoUrl().toString(),
      'https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/'
      'refs/heads/main/subtitles/anime_tv/K-ON!/.kitsuinfo.json',
    );
    const AjattCatalogEntry spaced = AjattCatalogEntry(
      type: AjattEntryType.animeMovie,
      pagePath: 'anime_movie/kimi-no-na-wa.html',
      name: 'Kimi no Na wa/君の名は',
      englishName: '',
      japaneseName: '',
      lastModifiedMs: 0,
    );
    expect(
      spaced.infoUrl().toString(),
      'https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/'
      'refs/heads/main/subtitles/anime_movie/'
      'Kimi%20no%20Na%20wa%2F%E5%90%9B%E3%81%AE%E5%90%8D%E3%81%AF/'
      '.kitsuinfo.json',
    );
    expect(
      entry.pageUrl().toString(),
      'https://subtitles.ajatt.top/anime_tv/k-on!.html',
    );
  });

  test('unescapeHtml：命名 / 十进制 / 十六进制实体，未知实体原样', () {
    expect(
      unescapeHtml('a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;'),
      'a & b <c> "d" \'e\'',
    );
    expect(unescapeHtml('&#x30;&#48;'), '00');
    expect(unescapeHtml('&bogus; plain'), '&bogus; plain');
    expect(unescapeHtml('no entities'), 'no entities');
  });

  group('AjattCatalogCache', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ajatt_cache_test');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    const AjattCatalogEntry entry = AjattCatalogEntry(
      type: AjattEntryType.dramaMovie,
      pagePath: 'drama_movie/x.html',
      name: 'X',
      englishName: 'X en',
      japaneseName: 'X ja',
      lastModifiedMs: 123000,
    );

    test('write → readFresh 往返；过期后 readFresh 为 null', () async {
      DateTime now = DateTime(2026, 8, 29, 12);
      final AjattCatalogCache cache = AjattCatalogCache(
        file: File('${tmp.path}/sub/ajatt.json'),
        now: () => now,
      );
      expect(await cache.readFresh(), isNull);
      await cache.write(<AjattCatalogEntry>[entry]);
      final List<AjattCatalogEntry>? fresh = await cache.readFresh();
      expect(fresh, hasLength(1));
      expect(fresh!.single.type, AjattEntryType.dramaMovie);
      expect(fresh.single.pagePath, 'drama_movie/x.html');
      expect(fresh.single.japaneseName, 'X ja');
      expect(fresh.single.lastModifiedMs, 123000);
      now = now.add(const Duration(hours: 23, minutes: 59));
      expect(await cache.readFresh(), isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect(await cache.readFresh(), isNull);
      await cache.clear();
      expect(await cache.file.exists(), isFalse);
    });

    test('损坏的缓存文件当作没有', () async {
      final File file = File('${tmp.path}/ajatt.json');
      await file.writeAsString('{"fetchedAt": 1, "entries": "nope"');
      final AjattCatalogCache cache = AjattCatalogCache(file: file);
      expect(await cache.readFresh(), isNull);
    });
  });
}
