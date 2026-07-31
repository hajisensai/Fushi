import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:hibiki/src/media/video/jimaku_batch.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

JimakuBatchTarget _t(String uid, String path,
        {int sortIndex = 0, String? title, bool isStream = false}) =>
    JimakuBatchTarget(
      bookUid: uid,
      title: title ?? path,
      videoPath: path,
      sortIndex: sortIndex,
      isStream: isStream,
    );

JimakuFile _f(String name) => JimakuFile(name: name, url: 'https://x/$name');

void main() {
  group('resolveBatchEpisode', () {
    test('优先从路径文件名解析集号', () {
      expect(resolveBatchEpisode(_t('b', '/v/Show - 03.mkv')), 3);
      expect(resolveBatchEpisode(_t('b', '/v/Show S01E07.mkv')), 7);
    });

    test('路径无集号则用标题', () {
      expect(
        resolveBatchEpisode(_t('b', '/v/opaque.mkv', title: '第12話')),
        12,
      );
    });

    test('都认不出退回 sortIndex+1（1-based）', () {
      expect(resolveBatchEpisode(_t('b', '/v/movie.mkv', sortIndex: 0)), 1);
      expect(resolveBatchEpisode(_t('b', '/v/movie.mkv', sortIndex: 4)), 5);
    });
  });

  group('pickBestSubtitleFile', () {
    test('优先精确命中集号 + 语言权重（ja 先）', () {
      final JimakuFile? best = pickBestSubtitleFile(
        <JimakuFile>[
          _f('Show - 02.en.srt'),
          _f('Show - 03.en.srt'),
          _f('Show - 03.ja.srt'),
        ],
        episode: 3,
      );
      expect(best?.name, 'Show - 03.ja.srt');
    });

    test('preferred 语言置顶', () {
      final JimakuFile? best = pickBestSubtitleFile(
        <JimakuFile>[_f('Show - 03.ja.srt'), _f('Show - 03.zh.srt')],
        episode: 3,
        preferredLanguage: 'zh',
      );
      expect(best?.name, 'Show - 03.zh.srt');
    });

    test('无一命中集号 → 退回全体（尽力而为）', () {
      final JimakuFile? best = pickBestSubtitleFile(
        <JimakuFile>[_f('Season pack.ja.srt')],
        episode: 3,
      );
      expect(best?.name, 'Season pack.ja.srt');
    });

    test('无文本字幕候选 → null', () {
      expect(
        pickBestSubtitleFile(<JimakuFile>[_f('cover.png')], episode: 1),
        isNull,
      );
    });
  });

  test('batchSubtitleFileName 以清洗后的 bookUid 前缀避免多集同名覆盖', () {
    expect(batchSubtitleFileName('video/abc', 'ep.srt'), 'video_abc__ep.srt');
    final String a = batchSubtitleFileName('video/a', 'pack.srt');
    final String b = batchSubtitleFileName('video/b', 'pack.srt');
    expect(a == b, isFalse, reason: '不同 book 的同名字幕落盘不得互相覆盖');
  });

  group('canDownloadJimakuInventory', () {
    final JimakuFileInventory nonEmpty = JimakuFileInventory.fromFiles(
      <JimakuFile>[_f('Show - 01.ja.srt')],
    );
    final JimakuFileInventory empty =
        JimakuFileInventory.fromFiles(const <JimakuFile>[]);

    test('仅预检查成功且非空的当前来源可下载', () {
      expect(
        canDownloadJimakuInventory(
          selectedEntryId: 7,
          inventories: <int, JimakuFileInventory>{7: nonEmpty},
          loadingEntryIds: const <int>{},
          failedEntryIds: const <int>{},
        ),
        isTrue,
      );
    });

    test('未选、loading、failed、合法空库存都禁用', () {
      bool canDownload({
        int? selectedEntryId = 7,
        Map<int, JimakuFileInventory> inventories =
            const <int, JimakuFileInventory>{},
        Set<int> loading = const <int>{},
        Set<int> failed = const <int>{},
      }) =>
          canDownloadJimakuInventory(
            selectedEntryId: selectedEntryId,
            inventories: inventories,
            loadingEntryIds: loading,
            failedEntryIds: failed,
          );

      expect(canDownload(selectedEntryId: null), isFalse);
      expect(
        canDownload(
          inventories: <int, JimakuFileInventory>{7: nonEmpty},
          loading: const <int>{7},
        ),
        isFalse,
      );
      expect(
        canDownload(
          inventories: <int, JimakuFileInventory>{7: nonEmpty},
          failed: const <int>{7},
        ),
        isFalse,
      );
      expect(
        canDownload(
          inventories: <int, JimakuFileInventory>{7: empty},
        ),
        isFalse,
      );
    });
  });

  group('runJimakuBatch（编排，MockClient 注入）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jimaku_batch_test');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('逐集列文件→挑最佳→下载落盘→回调持久化', () async {
      // Mock：/entries/7/files?episode=N 回该集的 srt 文件；下载 url 回文本字节。
      final MockClient mock = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/entries/7/files')) {
          final String ep = req.url.queryParameters['episode'] ?? '0';
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Show - 0$ep.ja.srt',
                'url': 'https://x/Show-$ep.ja.srt',
              },
            ]),
            200,
          );
        }
        // 文件下载。
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nhi\n', 200);
      });
      final JimakuClient client = JimakuClient(apiKey: 'k', client: mock);
      addTearDown(client.close);

      final List<JimakuBatchItem> persisted = <JimakuBatchItem>[];
      final List<JimakuBatchItem> results = await runJimakuBatch(
        client: client,
        entryIds: <int>[7],
        targets: <JimakuBatchTarget>[
          _t('video/a', '/v/Show - 01.mkv', sortIndex: 0),
          _t('video/b', '/v/Show - 02.mkv', sortIndex: 1),
        ],
        saveDirectory: tempDir.path,
        preferredLanguage: 'ja',
        onItemDone: (JimakuBatchItem item) async {
          if (item.status == JimakuBatchStatus.done) persisted.add(item);
        },
      );

      expect(results, hasLength(2));
      expect(results.every((i) => i.status == JimakuBatchStatus.done), isTrue);
      expect(results[0].episode, 1);
      expect(results[1].episode, 2);
      expect(results[0].language, 'ja');
      // 两个文件真落盘且不同名（bookUid 前缀）。
      expect(File(results[0].subtitlePath!).existsSync(), isTrue);
      expect(results[0].subtitlePath, isNot(results[1].subtitlePath));
      expect(persisted, hasLength(2), reason: 'onItemDone 对成功集回调持久化');
    });

    test('无匹配集记 noMatch，不中断其它集', () async {
      final MockClient mock = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/entries/7/files')) {
          final String ep = req.url.queryParameters['episode'] ?? '0';
          // 只有第 1 集有字幕；第 2 集回空。
          if (ep == '1') {
            return http.Response(
              jsonEncode(<Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'Show - 01.ja.srt',
                  'url': 'https://x/1'
                },
              ]),
              200,
            );
          }
          return http.Response('[]', 200);
        }
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nhi\n', 200);
      });
      final JimakuClient client = JimakuClient(apiKey: 'k', client: mock);
      addTearDown(client.close);

      final List<JimakuBatchItem> results = await runJimakuBatch(
        client: client,
        entryIds: <int>[7],
        targets: <JimakuBatchTarget>[
          _t('video/a', '/v/Show - 01.mkv', sortIndex: 0),
          _t('video/b', '/v/Show - 02.mkv', sortIndex: 1),
        ],
        saveDirectory: tempDir.path,
      );
      expect(results[0].status, JimakuBatchStatus.done);
      expect(results[1].status, JimakuBatchStatus.noMatch);
    });

    test('HTTP 请求失败记 failed，不得 fail-open 冒充 noMatch', () async {
      final JimakuClient client = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request req) async => http.Response('unavailable', 503),
        ),
      );
      addTearDown(client.close);

      final List<JimakuBatchItem> results = await runJimakuBatch(
        client: client,
        entryIds: <int>[7],
        targets: <JimakuBatchTarget>[
          _t('video/a', '/v/Show - 01.mkv'),
        ],
        saveDirectory: tempDir.path,
      );

      expect(results.single.status, JimakuBatchStatus.failed);
      expect(results.single.message, contains('JimakuRequestException(503)'));
    });

    test('malformed HTTP 200 记 failed；合法 [] 的 noMatch 语义不变', () async {
      final JimakuClient malformed = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request req) async => http.Response('{not-json', 200),
        ),
      );
      addTearDown(malformed.close);
      final List<JimakuBatchItem> malformedResults = await runJimakuBatch(
        client: malformed,
        entryIds: <int>[7],
        targets: <JimakuBatchTarget>[
          _t('video/a', '/v/Show - 01.mkv'),
        ],
        saveDirectory: tempDir.path,
      );
      expect(malformedResults.single.status, JimakuBatchStatus.failed);

      final JimakuClient validEmpty = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request req) async => http.Response('[]', 200),
        ),
      );
      addTearDown(validEmpty.close);
      final List<JimakuBatchItem> emptyResults = await runJimakuBatch(
        client: validEmpty,
        entryIds: <int>[7],
        targets: <JimakuBatchTarget>[
          _t('video/a', '/v/Show - 01.mkv'),
        ],
        saveDirectory: tempDir.path,
      );
      expect(emptyResults.single.status, JimakuBatchStatus.noMatch);
    });
  });
}
