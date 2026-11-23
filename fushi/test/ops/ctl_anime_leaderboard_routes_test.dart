import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/ops/ctl_anime_download_routes.dart';
import 'package:fushi/src/ops/ctl_leaderboard_routes.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

AnimeDownloadPlan _plan(String id, {String status = 'downloading'}) =>
    AnimeDownloadPlan(
      id: id,
      createdAtMs: 0,
      seriesTitle: 'Series $id',
      torrentTitle: 'Torrent $id',
      magnet: 'magnet:?xt=urn:btih:$id',
      qbCategory: 'anime',
      status: status,
    );

class _FakeStore implements AnimeDownloadPlanStore {
  _FakeStore(this.plans);

  final List<AnimeDownloadPlan> plans;

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async => plans;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _FakeAnime implements AnimeDownloadService {
  _FakeAnime(this.store);

  @override
  final AnimeDownloadPlanStore store;
  final List<String> importedNow = <String>[];
  bool ready = true;

  @override
  Future<bool> importNow(String planId) async {
    if (!ready) return false;
    importedNow.add(planId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _FakeLeaderboard implements LeaderboardService {
  final List<(String, bool)> imported = <(String, bool)>[];
  bool active = false;

  @override
  Future<void> load() async {}

  @override
  LeaderboardStatus get status =>
      active ? LeaderboardStatus.active : LeaderboardStatus.disabled;

  @override
  bool get hasConsent => imported.isNotEmpty && imported.last.$2;

  @override
  Null get self => null;

  @override
  Future<void> importRecoveryCode(String code, {required bool consent}) async {
    if (code == 'bad') throw const FormatException('bad');
    imported.add((code, consent));
    active = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Future<Object?> _call(
  List<CtlRoute> routes,
  String method,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
  bool fromModel = false,
}) {
  for (final CtlRoute route in routes) {
    if (route.method != method) continue;
    final Map<String, String>? params = route.match(path);
    if (params == null) continue;
    return route.handler(
      CtlCall(
        method: method,
        path: path,
        params: params,
        body: body,
        fromModel: fromModel,
      ),
    );
  }
  throw StateError('没有路由 $method $path');
}

void main() {
  group('动画下载计划', () {
    late _FakeAnime anime;
    late List<CtlRoute> routes;
    late bool available;

    setUp(() {
      available = true;
      anime = _FakeAnime(
        _FakeStore(<AnimeDownloadPlan>[
          _plan('a'),
          _plan('b', status: AnimeDownloadPlan.statusImported),
        ]),
      );
      routes = buildAnimeDownloadCtlRoutesFor(() => available ? anime : null);
    });

    test('列出计划；边下边播只认下载中的计划', () async {
      final Map<Object?, Object?> listed =
          await _call(routes, 'GET', kAnimeDownloadCtlRoot)
              as Map<Object?, Object?>;
      expect(listed['plans'], hasLength(2));
      await _call(routes, 'POST', '$kAnimeDownloadCtlRoot/a/import-now');
      expect(anime.importedNow, <String>['a']);
      expect(
        () => _call(routes, 'POST', '$kAnimeDownloadCtlRoot/b/import-now'),
        _status(409),
      );
      expect(
        () => _call(routes, 'POST', '$kAnimeDownloadCtlRoot/x/import-now'),
        _status(404),
      );
    });

    test('元数据没就绪 409；服务不可用 501', () async {
      anime.ready = false;
      expect(
        () => _call(routes, 'POST', '$kAnimeDownloadCtlRoot/a/import-now'),
        _status(409),
      );
      available = false;
      expect(() => _call(routes, 'GET', kAnimeDownloadCtlRoot), _status(501));
    });
  });

  group('排行榜恢复码', () {
    late _FakeLeaderboard service;
    late List<CtlRoute> routes;

    setUp(() {
      service = _FakeLeaderboard();
      routes = buildLeaderboardCtlRoutesFor(() => service);
    });

    test('用户导入：带 consent；格式错 400', () async {
      final Map<Object?, Object?> r =
          await _call(
                routes,
                'POST',
                '$kLeaderboardCtlRoot/recovery-code',
                body: <String, Object?>{'code': 'FUSHI-1', 'consent': true},
              )
              as Map<Object?, Object?>;
      expect(r['status'], 'active');
      expect(service.imported.single, ('FUSHI-1', true));
      expect(
        () => _call(
          routes,
          'POST',
          '$kLeaderboardCtlRoot/recovery-code',
          body: <String, Object?>{'code': 'bad'},
        ),
        _status(400),
      );
    });

    test('模型（AI 助手）调用一律拒绝，恢复码不经手', () async {
      expect(
        () => _call(
          routes,
          'POST',
          '$kLeaderboardCtlRoot/recovery-code',
          body: <String, Object?>{'code': 'FUSHI-1'},
          fromModel: true,
        ),
        _status(422),
      );
      expect(service.imported, isEmpty);
      final Map<Object?, Object?> s =
          await _call(routes, 'GET', kLeaderboardCtlRoot)
              as Map<Object?, Object?>;
      expect(s['status'], 'disabled');
    });
  });
}
