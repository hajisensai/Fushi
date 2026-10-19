/// 书族（书 / 漫画 / 有声书）封面刮削的 DLsite 源。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _product(String workno, {String type = 'SOU', int age = 1}) =>
    jsonEncode(<Object?>[
      <String, Object?>{
        'workno': workno,
        'work_name': '作品$workno',
        'maker_name': 'サークル',
        'work_type': type,
        'regist_date': '2023-01-16 00:00:00',
        'age_category': age,
        'creaters': <String, Object?>{
          'created_by': <Object?>[
            <String, Object?>{'name': '作者'},
          ],
        },
        'image_main': <String, Object?>{
          'url': '//img.dlsite.jp/modpub/images2/work/$workno.jpg',
        },
      },
    ]);

void main() {
  test('mapDlsiteWork：作者位优先 created_by、带年份与成人标记、无封面跳过', () {
    final BookScrapeCandidate c = mapDlsiteWork(
      parseDlsiteProductJson(
        _product('RJ01014447', age: 3),
        DlsiteWorkId.tryParse('RJ01014447')!,
      )!,
    )!;
    expect(c.source, BookScrapeSource.dlsite);
    expect(c.subjectId, 'RJ01014447');
    expect(c.author, '作者');
    expect(c.year, 2023);
    expect(c.isAdult, isTrue);
    expect(
      c.coverUrl,
      'https://img.dlsite.jp/modpub/images2/work/RJ01014447.jpg',
    );
    expect(
      c.detailUrl,
      'https://www.dlsite.com/maniax/work/=/product_id/RJ01014447.html',
    );
    expect(
      mapDlsiteWork(
        DlsiteWork(id: DlsiteWorkId.tryParse('RJ299717')!, title: 'x'),
      ),
      isNull,
    );
  });

  test('Bangumi 候选的来源与详情页不变（默认 source）', () {
    const BookScrapeCandidate c = BookScrapeCandidate(
      subjectId: '9999',
      title: 't',
      coverUrl: 'https://img/l.jpg',
    );
    expect(c.source, BookScrapeSource.bangumi);
    expect(c.detailUrl, 'https://bgm.tv/subject/9999');
  });

  test('searchDlsite：只留音声/漫画/小说；RJ 用推导主图，RE 补抓详情拿封面', () async {
    final List<String> paths = <String>[];
    final BookMetadataScraper scraper = BookMetadataScraper(
      dlsiteClient: DlsiteClient(
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          final String body = req.url.path == '/suggest/'
              ? jsonEncode(<String, Object?>{
                  'work': <Object?>[
                    <String, Object?>{
                      'workno': 'RJ299717',
                      'work_name': '音声',
                      'work_type': 'SOU',
                      'maker_name': 'サークル',
                    },
                    <String, Object?>{
                      'workno': 'RJ111111',
                      'work_name': '游戏',
                      'work_type': 'RPG',
                    },
                    <String, Object?>{
                      'workno': 'RE123456',
                      'work_name': '商业漫画',
                      'work_type': 'MNG',
                    },
                  ],
                })
              : _product('RE123456', type: 'MNG');
          return http.Response.bytes(utf8.encode(body), 200);
        }),
      ),
    );
    final List<BookScrapeCandidate> list = await scraper.searchDlsite('x');
    expect(list.map((BookScrapeCandidate c) => c.subjectId), <String>[
      'RJ299717',
      'RE123456',
    ]);
    expect(
      list.first.coverUrl,
      'https://img.dlsite.jp/modpub/images2/work/doujin/RJ300000/'
      'RJ299717_img_main.jpg',
    );
    expect(list.first.author, 'サークル');
    expect(paths, <String>[
      '/suggest/', // adult-jp
      '/suggest/', // comic（同一批结果按编号去重）
      '/maniax/api/=/product.json',
    ], reason: '书族查两个检索面；RJ 不补抓，只有 RE 补抓一次详情');
    scraper.close();
  });

  test('DLsite 失败折成带状态码的 BookScrapeException（弹窗据此给原因）', () async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      dlsiteClient: DlsiteClient(
        minRequestInterval: Duration.zero,
        client: MockClient((_) async => http.Response('', 502)),
      ),
    );
    await expectLater(
      scraper.fetchDlsiteById('RJ299717'),
      throwsA(
        isA<BookScrapeException>().having(
          (BookScrapeException e) => e.statusCode,
          'statusCode',
          502,
        ),
      ),
    );
    expect(await scraper.fetchDlsiteById('not-an-id'), isNull);
    scraper.close();
  });

  test('弹窗初始源：标题里认出编号 → DLsite + 编号；否则 Bangumi + 原词', () {
    expect(bookScrapeInitialState('[RJ01014447] ねこぐらし'), (
      BookScrapeSource.dlsite,
      'RJ01014447',
    ));
    expect(bookScrapeInitialState('よつばと！'), (
      BookScrapeSource.bangumi,
      'よつばと！',
    ));
  });
}
