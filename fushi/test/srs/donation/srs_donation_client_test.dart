import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi/src/srs/donation/srs_donation_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const String donorId = '0123456789abcdef0123456789abcdef';
  final String donorKey = 'a' * 64;
  final Uri base = Uri.parse('https://rank.example.test');
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('srs_donation_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  SrsDonationClient clientWith(MockClient mock) =>
      SrsDonationClient(clientFactory: () => mock, baseUrl: base);

  test('PUT 流式上传原始字节、带鉴权与统计头、报进度，解析返回', () async {
    final List<int> bytes = <int>[
      0x50, 0x4b, 0x03, 0x04, // PK\x03\x04
      for (int i = 0; i < 200000; i++) i % 251,
    ];
    final File file = File('${tmp.path}/x.apkg')..writeAsBytesSync(bytes);
    late http.BaseRequest seen;
    late List<int> body;
    final MockClient mock = MockClient.streaming((
      http.BaseRequest request,
      http.ByteStream stream,
    ) async {
      seen = request;
      body = await stream.toBytes();
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'donated': true,
              'updatedAt': 1764000000000,
            }),
          ),
        ),
        200,
      );
    });
    final List<(int, int)> progress = <(int, int)>[];
    final SrsDonationStatus status = await clientWith(mock).upload(
      donorId: donorId,
      donorKey: donorKey,
      file: file,
      reviews: 1234,
      cards: 56,
      appVersion: '1.2.3',
      onProgress: (int sent, int total) => progress.add((sent, total)),
    );
    expect(seen.method, 'PUT');
    expect(
      seen.url.toString(),
      'https://rank.example.test/v1/srs-donations/$donorId',
    );
    expect(seen.headers['Authorization'], 'Bearer $donorKey');
    expect(seen.headers['Content-Type'], 'application/octet-stream');
    expect(seen.headers['x-donation-reviews'], '1234');
    expect(seen.headers['x-donation-cards'], '56');
    expect(seen.headers['x-donation-app-version'], '1.2.3');
    expect(seen.contentLength, bytes.length);
    expect(body, bytes);
    expect(progress.first, (0, bytes.length));
    expect(progress.last, (bytes.length, bytes.length));
    expect(status.donated, isTrue);
    expect(
      status.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1764000000000),
    );
  });

  test('GET 解析状态；无记录 donated=false', () async {
    int calls = 0;
    final MockClient mock = MockClient((http.Request request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.headers['Authorization'], 'Bearer $donorKey');
      return calls == 1
          ? http.Response(
              jsonEncode(<String, Object?>{
                'donated': true,
                'reviews': 5000,
                'cards': 300,
                'updatedAt': '2026-11-20T10:00:00Z',
              }),
              200,
            )
          : http.Response('{"donated":false}', 200);
    });
    final SrsDonationClient client = clientWith(mock);
    final SrsDonationStatus a = await client.status(
      donorId: donorId,
      donorKey: donorKey,
    );
    expect(a.donated, isTrue);
    expect(a.reviews, 5000);
    expect(a.cards, 300);
    expect(a.updatedAt, DateTime.utc(2026, 11, 20, 10));
    final SrsDonationStatus b = await client.status(
      donorId: donorId,
      donorKey: donorKey,
    );
    expect(b.donated, isFalse);
    expect(b.reviews, isNull);
  });

  test('DELETE 撤回', () async {
    late http.Request seen;
    final MockClient mock = MockClient((http.Request request) async {
      seen = request;
      return http.Response('{"donated":false}', 200);
    });
    await clientWith(mock).withdraw(donorId: donorId, donorKey: donorKey);
    expect(seen.method, 'DELETE');
    expect(seen.url.path, '/v1/srs-donations/$donorId');
    expect(seen.headers['Authorization'], 'Bearer $donorKey');
  });

  test('非 2xx 抛带状态码的异常（不重试）', () async {
    int calls = 0;
    final MockClient mock = MockClient((http.Request request) async {
      calls++;
      return http.Response('{"error":"forbidden"}', 403);
    });
    await expectLater(
      clientWith(mock).status(donorId: donorId, donorKey: donorKey),
      throwsA(
        isA<SrsDonationHttpException>().having(
          (SrsDonationHttpException e) => e.statusCode,
          'statusCode',
          403,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('网络失败 / 坏 JSON 抛无状态码异常', () async {
    final SrsDonationClient broken = clientWith(
      MockClient(
        (http.Request request) async => throw const SocketException('x'),
      ),
    );
    await expectLater(
      broken.withdraw(donorId: donorId, donorKey: donorKey),
      throwsA(
        isA<SrsDonationHttpException>().having(
          (SrsDonationHttpException e) => e.statusCode,
          'statusCode',
          isNull,
        ),
      ),
    );
    final SrsDonationClient garbage = clientWith(
      MockClient((http.Request request) async => http.Response('<html>', 200)),
    );
    await expectLater(
      garbage.status(donorId: donorId, donorKey: donorKey),
      throwsA(isA<SrsDonationHttpException>()),
    );
  });

  test('默认指向 rank.fushi.moe', () async {
    late Uri seen;
    final SrsDonationClient client = SrsDonationClient(
      clientFactory: () => MockClient((http.Request request) async {
        seen = request.url;
        return http.Response('{"donated":false}', 200);
      }),
    );
    await client.status(donorId: donorId, donorKey: donorKey);
    expect(seen.toString(), 'https://rank.fushi.moe/v1/srs-donations/$donorId');
  });
}
