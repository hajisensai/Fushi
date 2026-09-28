import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

typedef Handler = Future<http.Response> Function(http.Request req);

final LeaderboardIdentity _id = LeaderboardIdentity.generate(random: Random(3));

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _account(String id) => <String, dynamic>{
  'id': id,
  'nickname': 'n$id',
  'discriminator': 42,
  'avatar': null,
};

/// 验签：按服务端的拼法（URL.pathname + URL.search）重建签名串。
bool _verifySigned(http.Request req, LeaderboardIdentity id) {
  final String? time = req.headers['X-Fushi-Time'];
  final String? sig = req.headers['X-Fushi-Sig'];
  if (time == null || sig == null) return false;
  final String pq = req.url.hasQuery
      ? '${req.url.path}?${req.url.query}'
      : req.url.path;
  final String msg = leaderboardSigningString(
    req.method,
    pq,
    int.parse(time),
    req.bodyBytes,
  );
  return LeaderboardIdentity.verify(id.spki, msg, sig);
}

class _Harness {
  _Harness(
    Handler handler, {
    LeaderboardIdentity? identity,
    int Function()? clock,
    String base = 'https://rank.example',
  }) {
    client = LeaderboardClient(
      baseUrl: Uri.parse(base),
      httpClientFactory: () async => MockClient((http.Request r) {
        requests.add(r);
        return handler(r);
      }),
      identity: identity,
      clockMs: clock,
    );
  }

  late final LeaderboardClient client;
  final List<http.Request> requests = <http.Request>[];
}

void main() {
  group('签名头', () {
    test('读写都带三头且能验过；时刻严格单调', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          ..._account(_id.accountId),
          'visibility': 'public',
          'createdAt': 1,
          'shelfCount': 3,
        }),
        identity: _id,
        clock: () => 1000,
      );
      final LeaderboardSelf me = await h.client.me();
      await h.client.me();
      await h.client.updateProfile(nickname: 'x');
      expect(me.shelfCount, 3);
      expect(me.account.tag, 'n${_id.accountId}#0042');
      expect(
        h.requests.map((http.Request r) => r.headers['X-Fushi-Time']),
        <String>['1000', '1001', '1002'],
      );
      for (final http.Request r in h.requests) {
        expect(r.headers['X-Fushi-Account'], _id.accountId);
        expect(_verifySigned(r, _id), isTrue, reason: '${r.method} ${r.url}');
      }
      expect(h.requests[2].method, 'PATCH');
      expect(jsonDecode(h.requests[2].body), <String, dynamic>{
        'nickname': 'x',
      });
    });

    test('时钟回拨也不重复时刻', () async {
      final List<int> ticks = <int>[5000, 4000, 4000];
      int i = 0;
      final _Harness h = _Harness(
        (http.Request r) async => http.Response('', 204),
        identity: _id,
        clock: () => ticks[i++],
      );
      await h.client.clearAvatar();
      await h.client.clearAvatar();
      await h.client.clearAvatar();
      expect(
        h.requests.map((http.Request r) => r.headers['X-Fushi-Time']),
        <String>['5000', '5001', '5002'],
      );
    });

    test('带查询串的读请求签的是 path?query', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          'metric': 'chars',
          'window': 'month',
          'scope': 'friends',
          'from': '2026-09-01',
          'total': 2,
          'me': <String, dynamic>{'rank': 2, 'value': 10},
          'rows': <Map<String, dynamic>>[
            <String, dynamic>{'rank': 1, 'value': 20, 'account': _account('a')},
          ],
        }),
        identity: _id,
        base: 'https://host.example/lb/',
      );
      final RankPage page = await h.client.rank(
        metric: LeaderboardMetric.chars,
        window: LeaderboardWindow.month,
        scope: LeaderboardScope.friends,
        limit: 10,
      );
      final http.Request r = h.requests.single;
      expect(r.url.path, '/lb/v1/rank');
      expect(r.url.queryParameters, <String, String>{
        'metric': 'chars',
        'window': 'month',
        'scope': 'friends',
        'limit': '10',
        'offset': '0',
      });
      expect(_verifySigned(r, _id), isTrue);
      expect(page.me!.rank, 2);
      expect(page.from, '2026-09-01');
      expect(page.rows.single.account.id, 'a');
      expect(page.metric, LeaderboardMetric.chars);
    });

    test('匿名客户端不带任何签名头', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          'window': 'all',
          'kind': 'game',
          'from': null,
          'rows': <Map<String, dynamic>>[
            <String, dynamic>{
              'rank': 1,
              'readers': 3,
              'work': <String, dynamic>{
                'id': 'w1',
                'kind': 'game',
                'title': 'T',
                'author': 'A',
                'cover': '/img/c/w1-x-1.jpg',
                'nsfw': true,
              },
            },
          ],
        }),
      );
      final PopularPage p = await h.client.popular(
        window: LeaderboardWindow.all,
        kind: LeaderboardKind.game,
      );
      final http.Request r = h.requests.single;
      expect(r.headers.containsKey('X-Fushi-Account'), isFalse);
      expect(r.headers.containsKey('X-Fushi-Sig'), isFalse);
      expect(r.url.queryParameters['kind'], 'game');
      expect(p.rows.single.work.nsfw, isTrue);
      expect(p.kind, LeaderboardKind.game);
      expect(p.from, isNull);
      expect(() => h.client.me(), throwsStateError);
    });
  });

  group('邮箱验证码 / 注册 / 登录', () {
    test('requestEmailCode 不签名、body 形状、202 成功', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{'sent': true}, 202),
        identity: _id,
      );
      await h.client.requestEmailCode(
        email: ' a@b.example ',
        purpose: 'register',
        lang: 'ja',
      );
      final http.Request r = h.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/v1/email/code');
      expect(r.headers.containsKey('X-Fushi-Sig'), isFalse);
      expect(r.headers.containsKey('X-Fushi-Account'), isFalse);
      expect(jsonDecode(utf8.decode(r.bodyBytes)), <String, dynamic>{
        'email': 'a@b.example',
        'purpose': 'register',
        'lang': 'ja',
      });
    });

    test('requestEmailCode 本机拒绝坏邮箱 / 坏 purpose，不发请求', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{'sent': true}, 202),
      );
      await expectLater(
        h.client.requestEmailCode(email: 'nope', purpose: 'register'),
        throwsArgumentError,
      );
      await expectLater(
        h.client.requestEmailCode(email: 'a@b.cd', purpose: 'x'),
        throwsArgumentError,
      );
      expect(h.requests, isEmpty);
    });

    test('isPlausibleLeaderboardEmail', () {
      expect(isPlausibleLeaderboardEmail('a@b.cd'), isTrue);
      expect(
        isPlausibleLeaderboardEmail(' user.name+x@mail.example.org '),
        isTrue,
      );
      expect(isPlausibleLeaderboardEmail('a@b'), isFalse);
      expect(isPlausibleLeaderboardEmail('a b@c.de'), isFalse);
      expect(isPlausibleLeaderboardEmail('@c.de'), isFalse);
      expect(isPlausibleLeaderboardEmail(''), isFalse);
    });

    test('register：body 带公钥/昵称/邮箱/验证码、不带 X-Fushi-Account、签名可验', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          ..._account(_id.accountId),
          'visibility': 'public',
          'createdAt': 99,
          'emailVerified': true,
        }, 201),
        identity: _id,
      );
      final LeaderboardSelf s = await h.client.register(
        nickname: 'ユーザー',
        email: 'a@b.cd',
        code: ' 123456 ',
      );
      final http.Request r = h.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/v1/register');
      expect(r.headers.containsKey('X-Fushi-Account'), isFalse);
      expect(r.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(utf8.decode(r.bodyBytes)), <String, dynamic>{
        'pubkey': _id.pubkeyBase64Url,
        'nickname': 'ユーザー',
        'email': 'a@b.cd',
        'code': '123456',
      });
      expect(_verifySigned(r, _id), isTrue);
      expect(s.createdAt, 99);
      expect(s.shelfCount, isNull);
      expect(s.emailVerified, isTrue);
    });

    test('login：新设备钥匙自签；返回的账户 id 可与本机钥匙 id 不同', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          ..._account('RealAccount12345'),
          'visibility': 'friends',
          'createdAt': 5,
          'emailVerified': true,
        }),
        identity: _id,
      );
      final LeaderboardSelf s = await h.client.login(
        email: 'a@b.cd',
        code: '654321',
      );
      final http.Request r = h.requests.single;
      expect(r.url.path, '/v1/login');
      expect(r.headers.containsKey('X-Fushi-Account'), isFalse);
      expect(jsonDecode(utf8.decode(r.bodyBytes)), <String, dynamic>{
        'pubkey': _id.pubkeyBase64Url,
        'email': 'a@b.cd',
        'code': '654321',
      });
      expect(_verifySigned(r, _id), isTrue);
      expect(s.account.id, 'RealAccount12345');
      expect(s.account.id, isNot(_id.accountId));
    });

    test('login 错误码透出（404 no_account）', () async {
      final _Harness h = _Harness(
        (http.Request r) async =>
            _json(<String, dynamic>{'error': 'no_account'}, 404),
        identity: _id,
      );
      await expectLater(
        h.client.login(email: 'a@b.cd', code: '1'),
        throwsA(
          isA<LeaderboardApiException>().having(
            (LeaderboardApiException e) => e.code,
            'code',
            'no_account',
          ),
        ),
      );
    });
  });

  group('错误映射', () {
    test('JSON 错误体 → status/code/detail', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{
          'error': 'bad_entry',
          'detail': '3: title',
        }, 400),
        identity: _id,
      );
      await expectLater(
        h.client.uploadShelfDelta(),
        throwsA(
          isA<LeaderboardApiException>()
              .having((LeaderboardApiException e) => e.status, 'status', 400)
              .having(
                (LeaderboardApiException e) => e.code,
                'code',
                'bad_entry',
              )
              .having(
                (LeaderboardApiException e) => e.detail,
                'detail',
                '3: title',
              ),
        ),
      );
    });

    test('非 JSON 错误体 → http_<status>', () async {
      final _Harness h = _Harness(
        (http.Request r) async =>
            http.Response('<html>bad gateway</html>', 502),
      );
      await expectLater(
        h.client.user('abc'),
        throwsA(
          isA<LeaderboardApiException>().having(
            (LeaderboardApiException e) => e.code,
            'code',
            'http_502',
          ),
        ),
      );
    });

    test('网络异常原样透出', () async {
      final _Harness h = _Harness(
        (http.Request r) async => throw http.ClientException('offline'),
      );
      await expectLater(
        h.client.work('w1'),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('uploadCover：409 cover_exists → null，其它 409 照抛', () async {
      String code = 'cover_exists';
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{'error': code}, 409),
        identity: _id,
      );
      expect(await h.client.uploadCover('w1', Uint8List(3)), isNull);
      final http.Request r = h.requests.single;
      expect(r.method, 'PUT');
      expect(r.url.path, '/v1/works/w1/cover');
      expect(r.headers['Content-Type'], 'image/jpeg');
      expect(_verifySigned(r, _id), isTrue);
      code = 'retry';
      await expectLater(
        h.client.uploadCover('w1', Uint8List(3)),
        throwsA(isA<LeaderboardApiException>()),
      );
    });

    test('非法 id 不拼进路径', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{}),
        identity: _id,
      );
      expect(() => h.client.user('../me'), throwsArgumentError);
      expect(h.requests, isEmpty);
    });
  });

  group('书架增量上报', () {
    test('body 形状、响应解析、头像字节体签名', () async {
      final _Harness h = _Harness((http.Request r) async {
        if (r.url.path == '/v1/me/avatar') {
          return _json(<String, dynamic>{'avatar': '/img/a/x-y-1.jpg'});
        }
        return _json(<String, dynamic>{
          'works': <Map<String, dynamic>>[
            <String, dynamic>{'i': 0, 'workId': 'w9', 'needsCover': true},
          ],
          'shelfCount': 7,
        });
      }, identity: _id);
      final ShelfUploadResult res = await h.client.uploadShelfDelta(
        reset: true,
        put: <ShelfEntryUpload>[
          ShelfEntryUpload(
            kind: LeaderboardKind.book,
            refs: <String>['t:a|b'],
            title: 'A',
            finished: true,
          ),
        ],
        remove: <String>['old'],
        daily: <DailyCharsUpload>[
          DailyCharsUpload(date: '2026-09-01', chars: 0),
        ],
      );
      expect(res.shelfCount, 7);
      expect(res.works.single.workId, 'w9');
      expect(res.works.single.needsCover, isTrue);
      final Map<String, dynamic> body =
          jsonDecode(utf8.decode(h.requests.single.bodyBytes))
              as Map<String, dynamic>;
      expect(body['reset'], isTrue);
      expect(body['remove'], <String>['old']);
      expect(body['daily'], <Map<String, dynamic>>[
        <String, dynamic>{'date': '2026-09-01', 'chars': 0},
      ]);
      expect((body['put'] as List<Object?>).single, <String, dynamic>{
        'kind': 'book',
        'refs': <String>['t:a|b'],
        'title': 'A',
        'author': '',
        'nsfw': false,
        'finished': true,
        'chars': 0,
        'ms': 0,
      });
      expect(_verifySigned(h.requests.single, _id), isTrue);

      expect(
        await h.client.setAvatar(Uint8List.fromList(<int>[0xff, 0xd8, 0xff])),
        '/img/a/x-y-1.jpg',
      );
      expect(_verifySigned(h.requests.last, _id), isTrue);
    });

    test('超过单批上限抛 ArgumentError 且不发请求', () async {
      final _Harness h = _Harness(
        (http.Request r) async => _json(<String, dynamic>{}),
        identity: _id,
      );
      expect(
        () => h.client.uploadShelfDelta(
          remove: List<String>.filled(kLeaderboardMaxRemove + 1, 'w'),
        ),
        throwsArgumentError,
      );
      expect(
        () => h.client.uploadShelfDelta(
          daily: List<DailyCharsUpload>.filled(
            kLeaderboardMaxDaily + 1,
            DailyCharsUpload(date: '2026-01-01', chars: 1),
          ),
        ),
        throwsArgumentError,
      );
      final ShelfEntryUpload e = ShelfEntryUpload(
        kind: LeaderboardKind.game,
        refs: <String>['vndb:v1'],
        title: 'g',
        finished: false,
      );
      expect(
        () => h.client.uploadShelfDelta(
          put: List<ShelfEntryUpload>.filled(kLeaderboardMaxPut + 1, e),
        ),
        throwsArgumentError,
      );
      expect(h.requests, isEmpty);
    });
  });

  group('读接口解析', () {
    test('user / userShelf / work', () async {
      final _Harness h = _Harness((http.Request r) async {
        final String p = r.url.path;
        if (p == '/v1/users/u1') {
          return _json(<String, dynamic>{
            'account': _account('u1'),
            'createdAt': 5,
            'firstRecordDate': null,
            'visibility': 'friends',
            'shelfVisible': false,
            'stats': <String, dynamic>{
              'book': <String, dynamic>{'value': 3, 'rank': 1},
              'chars': <String, dynamic>{'value': 0, 'rank': null},
            },
          });
        }
        if (p == '/v1/users/u1/shelf') {
          return _json(<String, dynamic>{
            'account': _account('u1'),
            'status': 'finished',
            'rows': <Map<String, dynamic>>[
              <String, dynamic>{
                'work': <String, dynamic>{
                  'id': 'w1',
                  'kind': 'manga',
                  'title': 'M',
                  'author': '',
                  'cover': null,
                  'nsfw': false,
                },
                'finishedAt': null,
                'finishedDate': null,
                'chars': 10,
                'ms': 20,
                'readers': 2,
                'wall': <Map<String, dynamic>>[_account('u2')],
              },
            ],
            'next': 'cur2',
          });
        }
        return _json(<String, dynamic>{
          'work': <String, dynamic>{
            'id': 'w1',
            'kind': 'video',
            'title': 'V',
            'author': 'S',
            'cover': 'https://image.tmdb.org/x.jpg',
            'nsfw': false,
          },
          'readers': 4,
          'rows': <Map<String, dynamic>>[
            <String, dynamic>{
              'account': _account('u3'),
              'finishedAt': 1790000000000,
              'finishedDate': '2026-09-21',
            },
          ],
          'next': null,
        });
      }, identity: _id);

      final UserCard card = await h.client.user('u1');
      expect(card.shelfVisible, isFalse);
      expect(card.standing(LeaderboardMetric.book).rank, 1);
      expect(card.standing(LeaderboardMetric.chars).rank, isNull);
      expect(card.standing(LeaderboardMetric.game).value, 0);

      final ShelfPage shelf = await h.client.userShelf(
        'u1',
        kind: LeaderboardKind.manga,
      );
      expect(h.requests[1].url.queryParameters['status'], 'finished');
      expect(h.requests[1].url.queryParameters['kind'], 'manga');
      expect(shelf.rows.single.finishedAt, isNull);
      expect(shelf.rows.single.wall.single.id, 'u2');
      expect(shelf.rows.single.work.kind, LeaderboardKind.manga);
      expect(h.requests[1].url.queryParameters.containsKey('cursor'), isFalse);
      expect(h.requests[1].url.queryParameters.containsKey('offset'), isFalse);
      expect(shelf.next, 'cur2');
      await h.client.userShelf('u1', cursor: shelf.next);
      expect(h.requests[2].url.queryParameters['cursor'], 'cur2');

      final WorkPage work = await h.client.work('w1', limit: 5, cursor: 'c9');
      expect(h.requests[3].url.queryParameters['cursor'], 'c9');
      expect(h.requests[3].url.queryParameters['limit'], '5');
      expect(work.next, isNull);
      expect(card.rankComputedAt, isNull);
      expect(() => h.client.work('w1', limit: 51), throwsArgumentError);
      expect(work.readers, 4);
      expect(work.rows.single.finishedDate, '2026-09-21');
      expect(
        h.client.resolveMedia(work.work.cover!).toString(),
        'https://image.tmdb.org/x.jpg',
      );
    });
  });

  group('社交', () {
    test(
      'friends / addFriend / removeFriend / blocks / block / unblock / report',
      () async {
        final _Harness h = _Harness((http.Request r) async {
          final String key = '${r.method} ${r.url.path}';
          switch (key) {
            case 'GET /v1/friends':
              return _json(<String, dynamic>{
                'friends': <Map<String, dynamic>>[
                  <String, dynamic>{'account': _account('f1'), 'since': 10},
                ],
                'incoming': <Map<String, dynamic>>[
                  <String, dynamic>{'account': _account('i1'), 'at': 11},
                ],
                'outgoing': <Map<String, dynamic>>[],
              });
            case 'POST /v1/friends/f2':
              return _json(<String, dynamic>{'state': 'pending'});
            case 'GET /v1/blocks':
              return _json(<String, dynamic>{
                'blocked': <Map<String, dynamic>>[_account('b1')],
              });
            case 'POST /v1/reports':
              return http.Response('', 201);
            default:
              return http.Response('', 204);
          }
        }, identity: _id);

        final FriendList fl = await h.client.friends();
        expect(fl.friends.single.since, 10);
        expect(fl.incoming.single.at, 11);
        expect(fl.outgoing, isEmpty);
        expect(await h.client.addFriend('f2'), 'pending');
        await h.client.removeFriend('f2');
        expect((await h.client.blocks()).single.id, 'b1');
        await h.client.block('b2');
        await h.client.unblock('b2');
        await h.client.report(
          targetKind: 'work',
          targetId: 'w1',
          reason: 'wrong cover',
        );
        expect(
          h.requests.map((http.Request r) => '${r.method} ${r.url.path}'),
          <String>[
            'GET /v1/friends',
            'POST /v1/friends/f2',
            'DELETE /v1/friends/f2',
            'GET /v1/blocks',
            'POST /v1/blocks/b2',
            'DELETE /v1/blocks/b2',
            'POST /v1/reports',
          ],
        );
        expect(jsonDecode(h.requests.last.body), <String, dynamic>{
          'targetKind': 'work',
          'targetId': 'w1',
          'reason': 'wrong cover',
        });
        for (final http.Request r in h.requests) {
          expect(_verifySigned(r, _id), isTrue);
        }
      },
    );
  });

  group('URL', () {
    test('resolveMedia 与分享链接保留 base 路径前缀', () {
      final LeaderboardClient c = LeaderboardClient(
        baseUrl: Uri.parse('https://host.example/lb/'),
        httpClientFactory: () async =>
            MockClient((http.Request r) async => http.Response('', 500)),
      );
      expect(
        c.resolveMedia('/img/a/x-y-1.jpg').toString(),
        'https://host.example/lb/img/a/x-y-1.jpg',
      );
      expect(
        LeaderboardClient.shareUserUrl(
          Uri.parse('https://rank.fushi.moe'),
          'abc_-1',
        ).toString(),
        'https://rank.fushi.moe/u/abc_-1',
      );
      expect(
        LeaderboardClient.shareWorkUrl(
          Uri.parse('https://rank.fushi.moe/'),
          'w1',
        ).toString(),
        'https://rank.fushi.moe/w/w1',
      );
    });
  });
}
