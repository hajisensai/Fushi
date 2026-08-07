import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/alias_cache.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('alias_cache_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  File cacheFile() =>
      File('${tempDir.path}${Platform.pathSeparator}scraper_alias_cache.json');

  test('put/get roundtrip 并落盘持久化', () async {
    final AliasCache cache = AliasCache(tempDir);
    expect(await cache.get('无职转生'), isNull);
    await cache.put(
      '无职转生',
      ScrapeSource.offlineDb,
      'myanimelist.net/anime/39535',
    );
    expect(
      await cache.get('无职转生'),
      (ScrapeSource.offlineDb, 'myanimelist.net/anime/39535'),
    );
    // 新实例从盘上读回（持久化生效）。
    final AliasCache reopened = AliasCache(tempDir);
    expect(
      await reopened.get('无职转生'),
      (ScrapeSource.offlineDb, 'myanimelist.net/anime/39535'),
    );
    expect(cacheFile().existsSync(), isTrue);
    // 落盘内容是合法 JSON 且无 .tmp 残留。
    expect(() => json.decode(cacheFile().readAsStringSync()), returnsNormally);
    expect(File('${cacheFile().path}.tmp').existsSync(), isFalse);
  });

  test('key 经归一化：繁体/全角/装饰变体命中同一条', () async {
    final AliasCache cache = AliasCache(tempDir);
    await cache.put(
      '無職転生（２０２１）',
      ScrapeSource.bangumi,
      '277518',
    );
    expect(
      await cache.get('无职转生 (2021)'),
      (ScrapeSource.bangumi, '277518'),
    );
    expect(
      await cache.get('無職転生 (2021)'),
      (ScrapeSource.bangumi, '277518'),
    );
    expect(await cache.get('别的作品'), isNull);
  });

  test('覆盖写：同 key 再 put 取最新值', () async {
    final AliasCache cache = AliasCache(tempDir);
    await cache.put('紫罗兰永恒花园', ScrapeSource.offlineDb, 'old-id');
    await cache.put('紫罗兰永恒花园', ScrapeSource.tmdb, 'new-id');
    expect(
      await cache.get('紫罗兰永恒花园'),
      (ScrapeSource.tmdb, 'new-id'),
    );
  });

  test('损坏文件当空重建，put 后恢复可用', () async {
    cacheFile().writeAsStringSync('{{{ not json at all');
    final AliasCache cache = AliasCache(tempDir);
    expect(await cache.get('无职转生'), isNull);
    await cache.put('无职转生', ScrapeSource.offlineDb, 'id-1');
    expect(
      await cache.get('无职转生'),
      (ScrapeSource.offlineDb, 'id-1'),
    );
    // 重建后的文件恢复为合法 JSON，新实例可读。
    final AliasCache reopened = AliasCache(tempDir);
    expect(
      await reopened.get('无职转生'),
      (ScrapeSource.offlineDb, 'id-1'),
    );
  });

  test('结构对但字段坏的条目被静默丢弃', () async {
    cacheFile().writeAsStringSync(json.encode(<String, Object?>{
      'v': 1,
      'entries': <String, Object?>{
        '好条目': <String, String>{'source': 'offlineDb', 'entryId': 'ok'},
        '坏来源': <String, String>{'source': 'notASource', 'entryId': 'x'},
        '坏形状': 42,
      },
    }));
    final AliasCache cache = AliasCache(tempDir);
    expect(await cache.get('好条目'), (ScrapeSource.offlineDb, 'ok'));
    expect(await cache.get('坏来源'), isNull);
    expect(await cache.get('坏形状'), isNull);
  });

  test('文件缺失时 get 返回 null 不抛异常', () async {
    final AliasCache cache = AliasCache(tempDir);
    expect(await cache.get('任何 key'), isNull);
    expect(cacheFile().existsSync(), isFalse);
  });
}
