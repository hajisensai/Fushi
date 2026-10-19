import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// fixture 是 2026-10 实测录下的真实响应（字段裁剪到解析用得上的部分）。
String _fixture(String name) =>
    File('test/media/metadata/dlsite/fixtures/$name').readAsStringSync();

void main() {
  group('DlsiteWorkId', () {
    test('严格解析认 6/8 位编号与四种前缀，规范成大写', () {
      expect(DlsiteWorkId.tryParse(' rj01014447 ')?.value, 'RJ01014447');
      expect(DlsiteWorkId.tryParse('RJ299717')?.site, DlsiteSite.maniax);
      expect(DlsiteWorkId.tryParse('VJ01000001')?.site, DlsiteSite.pro);
      expect(DlsiteWorkId.tryParse('BJ123456')?.site, DlsiteSite.books);
      expect(DlsiteWorkId.tryParse('RE123456')?.site, DlsiteSite.maniax);
      expect(DlsiteWorkId.tryParse('RJ1234567'), isNull, reason: '7 位不是编号');
      expect(DlsiteWorkId.tryParse('XJ123456'), isNull);
      expect(DlsiteWorkId.tryParse('RJ123456 标题'), isNull);
    });

    test('从文件夹名 / 路径里找编号，两侧紧挨字母数字的不算', () {
      expect(
        DlsiteWorkId.findIn(r'D:\ASMR\[RJ01014447] ねこぐらし')?.value,
        'RJ01014447',
      );
      expect(
        DlsiteWorkId.findIn('RJ299717_mp3')?.value,
        'RJ299717',
        reason: '下划线不是字母数字',
      );
      expect(DlsiteWorkId.findIn('XRJ299717'), isNull);
      expect(DlsiteWorkId.findIn('RJ2997170'), isNull, reason: '7 位');
      expect(DlsiteWorkId.findIn('普通书名'), isNull);
    });

    test('作品页外链按分站拼路径', () {
      expect(
        DlsiteWorkId.tryParse('VJ01000001')!.pageUrl,
        'https://www.dlsite.com/pro/work/=/product_id/VJ01000001.html',
      );
    });
  });

  test('RJ / VJ / BJ 主图 URL 按「向上取整到千」的目录规则推出（与实测 image_main.url 一致）', () {
    expect(
      dlsiteGuessCoverUrl(DlsiteWorkId.tryParse('RJ01014447')!),
      'https://img.dlsite.jp/modpub/images2/work/doujin/RJ01015000/'
      'RJ01014447_img_main.jpg',
    );
    expect(
      dlsiteGuessCoverUrl(DlsiteWorkId.tryParse('RJ299717')!),
      'https://img.dlsite.jp/modpub/images2/work/doujin/RJ300000/'
      'RJ299717_img_main.jpg',
    );
    expect(
      dlsiteGuessCoverUrl(DlsiteWorkId.tryParse('VJ01001156')!),
      'https://img.dlsite.jp/modpub/images2/work/professional/VJ01002000/'
      'VJ01001156_img_main.jpg',
    );
    expect(
      dlsiteGuessCoverUrl(DlsiteWorkId.tryParse('BJ460025')!),
      'https://img.dlsite.jp/modpub/images2/work/books/BJ461000/'
      'BJ460025_img_main.jpg',
    );
    expect(dlsiteGuessCoverUrl(DlsiteWorkId.tryParse('RE123456')!), isNull);
  });

  group('parseDlsiteProductJson', () {
    final DlsiteWorkId id = DlsiteWorkId.tryParse('RJ01014447')!;

    test('真实响应：标题 / 社团 / 类型 / 分级 / 标签 / 创作者 / 封面', () {
      final DlsiteWork work = parseDlsiteProductJson(
        _fixture('product_RJ01014447_zh_CN.json'),
        id,
      )!;
      expect(work.title, contains('ねこぐらし'));
      expect(work.circle, 'CANDY VOICE');
      expect(work.workType, 'SOU');
      expect(work.category, DlsiteWorkCategory.voice);
      expect(work.ageCategory, DlsiteAgeCategory.general);
      expect(work.releaseDate, DateTime(2023, 1, 16));
      expect(work.genres, contains('ASMR'));
      expect(work.voiceActors, <String>['佐倉綾音']);
      expect(work.scenarioWriters, isNotEmpty);
      expect(
        work.coverUrl,
        'https://img.dlsite.jp/modpub/images2/work/doujin/RJ01015000/RJ01014447_img_main.jpg',
      );
      expect(
        work.primaryCreators,
        work.scenarioWriters,
        reason: '没有 created_by 时作者位退到剧本',
      );
    });

    test('查无此作（`[]` + 空行）返回 null，不是异常', () {
      expect(parseDlsiteProductJson('[]\n\n\n', id), isNull);
    });

    test('回错编号的条目不当成本作', () {
      final String body = jsonEncode(<Object?>[
        <String, Object?>{'workno': 'RJ999999', 'work_name': 'other'},
      ]);
      expect(parseDlsiteProductJson(body, id), isNull);
    });

    test('结构不对 / JSON 畸形抛 DlsiteException，不吞成查无此作', () {
      expect(
        () => parseDlsiteProductJson('{}', id),
        throwsA(isA<DlsiteException>()),
      );
      expect(
        () => parseDlsiteProductJson('<html>', id),
        throwsA(isA<DlsiteException>()),
      );
    });

    test('成人向分级码 3 → isAdult', () {
      final String body = jsonEncode(<Object?>[
        <String, Object?>{
          'workno': 'RJ01014447',
          'work_name': 'x',
          'age_category': 3,
          'work_type': 'ADV',
        },
      ]);
      final DlsiteWork work = parseDlsiteProductJson(body, id)!;
      expect(work.ageCategory!.isAdult, isTrue);
      expect(work.category, DlsiteWorkCategory.game);
      expect(work.coverUrl, isNull);
      expect(work.primaryCreators, isEmpty);
    });
  });

  test('商业书作者在独立 author 数组里（creaters 为空时用它）', () {
    final String body = jsonEncode(<Object?>[
      <String, Object?>{
        'workno': 'BJ460025',
        'work_name': '進撃の巨人（１）',
        'work_type': 'MNG',
        'creaters': <Object?>[],
        'author': <Object?>[
          <String, Object?>{'author_name': '諫山創', 'author_name_kana': 'x'},
        ],
      },
    ]);
    final DlsiteWork work = parseDlsiteProductJson(
      body,
      DlsiteWorkId.tryParse('BJ460025')!,
    )!;
    expect(work.authors, <String>['諫山創']);
    expect(work.primaryCreators, <String>['諫山創']);
    expect(work.category, DlsiteWorkCategory.manga);
  });

  test('parseDlsiteRatingJson：真实响应取两位小数均分，归一到 10 分制', () {
    final DlsiteRating rating = parseDlsiteRatingJson(
      _fixture('info_RJ01014447.json'),
      DlsiteWorkId.tryParse('RJ01014447')!,
    )!;
    expect(rating.average, 4.87);
    expect(rating.scoreOutOfTen, closeTo(9.74, 1e-9));
    expect(rating.count, greaterThan(0));
    expect(rating.downloads, greaterThan(0));
    expect(
      parseDlsiteRatingJson('[]', DlsiteWorkId.tryParse('RJ01014447')!),
      isNull,
    );
  });

  test('parseDlsiteSuggestJson：真实响应解析出候选并按编号去重', () {
    final List<DlsiteSearchCandidate> list = parseDlsiteSuggestJson(
      _fixture('suggest_nekogurashi.json'),
    );
    expect(list, isNotEmpty);
    expect(
      list.every((DlsiteSearchCandidate c) => c.workType == 'SOU'),
      isTrue,
    );
    expect(
      list.map((DlsiteSearchCandidate c) => c.id).toSet().length,
      list.length,
    );
    expect(parseDlsiteSuggestJson('{"work":[]}'), isEmpty);
    expect(() => parseDlsiteSuggestJson('[]'), throwsA(isA<DlsiteException>()));
  });

  group('DlsiteClient', () {
    test('限速跨实例生效：两个实例并发打出的请求开始时刻也至少相隔一个间隔', () async {
      DlsiteClient.resetRateLimitForTesting();
      addTearDown(DlsiteClient.resetRateLimitForTesting);
      const Duration interval = Duration(milliseconds: 120);
      final List<DateTime> starts = <DateTime>[];
      MockClient mock() => MockClient((http.Request req) async {
        starts.add(DateTime.now());
        return http.Response.bytes(
          utf8.encode(_fixture('info_RJ01014447.json')),
          200,
        );
      });
      final DlsiteClient a = DlsiteClient(
        minRequestInterval: interval,
        client: mock(),
      );
      final DlsiteClient b = DlsiteClient(
        minRequestInterval: interval,
        client: mock(),
      );
      final DlsiteWorkId id = DlsiteWorkId.tryParse('RJ01014447')!;
      await Future.wait(<Future<Object?>>[
        a.fetchRating(id),
        b.fetchRating(id),
        a.fetchRating(id),
        b.fetchRating(id),
      ]);
      expect(starts, hasLength(4));
      starts.sort();
      for (int i = 1; i < starts.length; i++) {
        expect(
          starts[i].difference(starts[i - 1]),
          // 计时器粒度（Windows ~15ms）留一点余量；旧实现两实例同刻放行，差值是 0。
          greaterThanOrEqualTo(interval - const Duration(milliseconds: 20)),
          reason: '第 $i 个请求与上一个间隔不足',
        );
      }
    });

    test('fetchWork 打 product.json（带 locale），withRating 再打评分端点', () async {
      final List<Uri> requested = <Uri>[];
      final DlsiteClient client = DlsiteClient(
        locale: 'zh_CN',
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request req) async {
          requested.add(req.url);
          final String body = req.url.path.endsWith('product.json')
              ? _fixture('product_RJ01014447_zh_CN.json')
              : _fixture('info_RJ01014447.json');
          return http.Response.bytes(utf8.encode(body), 200);
        }),
      );
      final DlsiteWork work = (await client.fetchWork(
        DlsiteWorkId.tryParse('RJ01014447')!,
        withRating: true,
      ))!;
      expect(requested.first.path, '/maniax/api/=/product.json');
      expect(requested.first.queryParameters['workno'], 'RJ01014447');
      expect(requested.first.queryParameters['locale'], 'zh_CN');
      expect(requested.last.path, '/maniax/product/info/ajax');
      expect(work.rating?.average, 4.87);
    });

    test('search 按大类过滤；输入是编号时直取详情', () async {
      final DlsiteClient client = DlsiteClient(
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request req) async {
          if (req.url.path == '/suggest/') {
            return http.Response.bytes(
              utf8.encode(_fixture('suggest_nekogurashi.json')),
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(_fixture('product_RJ01014447_zh_CN.json')),
            200,
          );
        }),
      );
      expect(
        await client.search(
          'ねこぐらし',
          categories: <DlsiteWorkCategory>{DlsiteWorkCategory.game},
        ),
        isEmpty,
        reason: 'fixture 全是音声，游戏库搜不到',
      );
      expect(
        await client.search(
          'ねこぐらし',
          categories: <DlsiteWorkCategory>{DlsiteWorkCategory.voice},
        ),
        isNotEmpty,
      );
      final List<DlsiteSearchCandidate> direct = await client.search(
        'rj01014447',
      );
      expect(direct.single.id.value, 'RJ01014447');
    });

    test('多个检索面按序查、按编号去重', () async {
      final List<String> sites = <String>[];
      final DlsiteClient client = DlsiteClient(
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request req) async {
          final String site = req.url.queryParameters['site']!;
          sites.add(site);
          final List<Object?> works = <Object?>[
            <String, Object?>{
              'workno': 'RJ299717',
              'work_name': 'dup',
              'work_type': 'SOU',
            },
            if (site == 'comic')
              <String, Object?>{
                'workno': 'BJ460025',
                'work_name': 'manga',
                'work_type': 'MNG',
              },
          ];
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, Object?>{'work': works})),
            200,
          );
        }),
      );
      final List<DlsiteSearchCandidate> list = await client.search(
        'x',
        sites: kDlsiteSuggestSitesBooks,
      );
      expect(sites, <String>['adult-jp', 'comic']);
      expect(list.map((DlsiteSearchCandidate c) => c.id.value), <String>[
        'RJ299717',
        'BJ460025',
      ]);
    });

    test('非 2xx 抛带状态码的 DlsiteException', () async {
      final DlsiteClient client = DlsiteClient(
        minRequestInterval: Duration.zero,
        client: MockClient((_) async => http.Response('', 503)),
      );
      await expectLater(
        client.fetchWork(DlsiteWorkId.tryParse('RJ299717')!),
        throwsA(
          isA<DlsiteException>().having(
            (DlsiteException e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });
  });
}
