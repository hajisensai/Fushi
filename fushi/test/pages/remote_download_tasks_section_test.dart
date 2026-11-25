/// 下载中心「任务」tab 的互联 host 代下载任务段（R6）。
///
/// 修复前：只在 initState 探一次、取第一台 host 的单个 target 当常量；轮询失败
/// `catch (_) {}` 吞掉、既不标识也不提示；探不到的 host（凭据失效等）整段静默；
/// 条目 `kind` 写死 video、`createdAt` 取 `updatedAt`。
///
/// 这里用内存 DB 里的三台已配对 host（hostId 各异）+ 计数 MockClient 驱动真实的
/// [InterconnectDownloadClient] / [InterconnectHostChannel]，断言段产出的条目。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/remote_download_tasks_section.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

const Duration _poll = Duration(seconds: 5);

String _url(int i) => 'http://10.0.0.$i:47233';

/// 每台 host 的假后端：能力表与任务列表的应答可按拍替换。
class _FakeHosts {
  final Map<int, int> capabilityCalls = <int, int>{};
  final Map<int, int> listCalls = <int, int>{};

  /// host 序号 → 第 n 次（从 1 起）能力探测的应答。
  final Map<int, http.Response Function(int call)> capabilities =
      <int, http.Response Function(int call)>{};

  /// host 序号 → 第 n 次（从 1 起）`GET /api/downloads` 的应答。
  final Map<int, Future<http.Response> Function(int call)> jobs =
      <int, Future<http.Response> Function(int call)>{};

  MockClient client() => MockClient((http.Request request) async {
    final int host = int.parse(request.url.host.split('.').last);
    if (request.url.path == '/api/capabilities') {
      final int n = capabilityCalls[host] = (capabilityCalls[host] ?? 0) + 1;
      return capabilities[host]!(n);
    }
    if (request.method == 'GET' && request.url.path == '/api/downloads') {
      final int n = listCalls[host] = (listCalls[host] ?? 0) + 1;
      return jobs[host]!(n);
    }
    return http.Response('not found', 404);
  });
}

http.Response _supported() => http.Response(
  jsonEncode(<String, Object?>{
    'downloads': <String, Object?>{
      'supported': true,
      'backend': 'embedded',
      'kinds': <String>['video', 'manga'],
    },
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _jobs(List<Map<String, Object?>> jobs) => http.Response(
  jsonEncode(<String, Object?>{'jobs': jobs}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _job(
  String id, {
  String? mediaKind,
  int createdAt = 100,
  int updatedAt = 200,
}) => <String, Object?>{
  'jobId': id,
  'title': 'Job $id',
  'lifecycle': VideoDownloadJobLifecycle.active,
  'stage': 'downloading',
  'stageProgress': 0.5,
  'createdAt': createdAt,
  'updatedAt': updatedAt,
  'mediaKind': ?mediaKind,
};

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    resetInterconnectRaceCache();
    debugInterconnectAddressProbeOverride =
        (FushiClientUrl candidate, String? expectedHostId) async => true;
  });

  tearDown(() {
    debugInterconnectAddressProbeOverride = null;
    resetInterconnectRaceCache();
  });

  Future<List<DownloadTaskEntry> Function()> pumpSection(
    WidgetTester tester,
    _FakeHosts hosts, {
    String preferred = '',
    int hostCount = 3,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await SyncRepository(db).setFushiClientUrls(<FushiClientUrl>[
      for (int i = 1; i <= hostCount; i++)
        FushiClientUrl(
          url: _url(i),
          deviceName: 'PC$i',
          hostId: 'h$i',
          token: 'tok$i',
        ),
    ]);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    if (preferred.isNotEmpty) {
      await prefs.setDownloadExecutionHostUrl(preferred);
    }
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wirePreferencesForTesting(prefs);
    final InterconnectDownloadClient client = InterconnectDownloadClient(
      repo: SyncRepository(db),
      httpClient: hosts.client(),
    );
    addTearDown(client.close);
    List<DownloadTaskEntry> latest = const <DownloadTaskEntry>[];
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: RemoteDownloadTasksSection(
                clientOverride: client,
                pollInterval: _poll,
                tasksBuilder:
                    (BuildContext context, List<DownloadTaskEntry> entries) {
                      latest = entries;
                      return SingleChildScrollView(
                        child: Column(
                          children: <Widget>[
                            for (final DownloadTaskEntry e in entries)
                              e.builder(context),
                          ],
                        ),
                      );
                    },
              ),
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return () => latest;
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  List<DownloadTaskEntry> ofHost(List<DownloadTaskEntry> all, int i) => all
      .where((DownloadTaskEntry e) => e.collectionKey == 'remote:host:h$i')
      .toList();

  testWidgets('多台 host 都宣告 downloads：每台的任务都列出；任务域与创建时间按 wire', (
    WidgetTester tester,
  ) async {
    final _FakeHosts hosts = _FakeHosts()
      ..capabilities[1] = ((_) => _supported())
      ..capabilities[2] = ((_) => _supported())
      ..capabilities[3] = ((_) => _supported())
      ..jobs[1] = ((_) async =>
          _jobs(<Map<String, Object?>>[_job('a', mediaKind: 'manga')]))
      ..jobs[2] = ((_) async => _jobs(<Map<String, Object?>>[
        _job('b', mediaKind: 'tv', createdAt: 7, updatedAt: 9),
      ]))
      ..jobs[3] = ((_) async => _jobs(const <Map<String, Object?>>[]));
    final List<DownloadTaskEntry> Function() entries = await pumpSection(
      tester,
      hosts,
      preferred: _url(2),
    );

    final List<DownloadTaskEntry> h1 = ofHost(entries(), 1);
    final List<DownloadTaskEntry> h2 = ofHost(entries(), 2);
    expect(h1, hasLength(1), reason: '修复前只看第一台 host');
    expect(h2, hasLength(1), reason: '修复前只看第一台 host');
    expect(h1.single.id, 'remote:host:h1:a');
    expect(h1.single.kind, DownloadTaskKind.manga);
    expect(h1.single.createdAt, 100, reason: '修复前取的是 updatedAt');
    expect(h2.single.kind, DownloadTaskKind.video, reason: 'tv = 视频任务');
    expect(h2.single.createdAt, 7);
    // 「下载执行设备」那台排第一。
    expect(entries().first.collectionKey, 'remote:host:h2');
  });

  testWidgets('轮询失败：保留上次的任务并标「过期」，不静默吞掉', (WidgetTester tester) async {
    final _FakeHosts hosts = _FakeHosts()
      ..capabilities[1] = ((_) => _supported())
      ..capabilities[2] = ((_) => _supported())
      ..jobs[1] = ((_) async => _jobs(<Map<String, Object?>>[_job('a')]))
      ..jobs[2] = ((int n) async => n == 1
          ? _jobs(<Map<String, Object?>>[_job('b')])
          : http.Response('boom', 500));
    final List<DownloadTaskEntry> Function() entries = await pumpSection(
      tester,
      hosts,
      hostCount: 2,
    );
    expect(ofHost(entries(), 2), hasLength(1));
    expect(find.textContaining('last known progress'), findsNothing);

    await tester.pump(_poll);
    await settle(tester);

    expect(hosts.listCalls[2], greaterThanOrEqualTo(2));
    expect(ofHost(entries(), 2), hasLength(1), reason: '一次失败不清列表');
    expect(
      find.textContaining('last known progress'),
      findsOneWidget,
      reason: '修复前失败无任何标识',
    );
  });

  testWidgets('凭据失效的 host：出一条 attention 条目说明原因，点重试重探', (
    WidgetTester tester,
  ) async {
    final _FakeHosts hosts = _FakeHosts()
      ..capabilities[1] = ((_) => _supported())
      ..capabilities[2] = ((_) => _supported())
      ..capabilities[3] = ((int n) => n == 1
          ? http.Response('{"message":"unauthorized"}', 401)
          : _supported())
      ..jobs[1] = ((_) async => _jobs(<Map<String, Object?>>[_job('a')]))
      ..jobs[2] = ((_) async => _jobs(<Map<String, Object?>>[_job('b')]))
      ..jobs[3] = ((_) async => _jobs(<Map<String, Object?>>[_job('c')]));
    final List<DownloadTaskEntry> Function() entries = await pumpSection(
      tester,
      hosts,
    );

    final List<DownloadTaskEntry> h3 = ofHost(entries(), 3);
    expect(h3, hasLength(1), reason: '修复前探不到的 host 整段静默');
    expect(h3.single.status, DownloadTaskStatus.attention);
    expect(h3.single.title, 'PC3');
    expect(
      find.textContaining(t.interconnect_host_failure_auth_rejected),
      findsWidgets,
    );

    // 永久性失败不随轮询重探。
    await tester.pump(_poll);
    await settle(tester);
    expect(hosts.capabilityCalls[3], 1);

    final Future<void> Function()? retry = h3.single.actions.retry;
    expect(retry, isNotNull);
    await retry!();
    await settle(tester);
    expect(hosts.capabilityCalls[3], 2);
    expect(ofHost(entries(), 3).single.id, 'remote:host:h3:c');
  });

  testWidgets(
    '不提供代下载 / 连不上的 host 不是在用的下载设备：段里不出条目（评审 correctness-1 / compat-2）',
    (WidgetTester tester) async {
      final _FakeHosts hosts = _FakeHosts()
        ..capabilities[1] = ((_) => _supported())
        // 只配对来同步 / 查词：能力表里没有 downloads。
        ..capabilities[2] = ((_) => http.Response('{}', 200))
        // 关机。
        ..capabilities[3] = ((_) => throw http.ClientException('refused'))
        ..jobs[1] = ((_) async => _jobs(<Map<String, Object?>>[_job('a')]));
      final List<DownloadTaskEntry> Function() entries = await pumpSection(
        tester,
        hosts,
      );
      expect(ofHost(entries(), 1), hasLength(1));
      expect(ofHost(entries(), 2), isEmpty, reason: '修复前常驻一条「不提供这项功能」');
      expect(ofHost(entries(), 3), isEmpty, reason: '修复前常驻一条「连不上」');
      expect(
        find.textContaining(t.interconnect_host_failure_unsupported),
        findsNothing,
      );
    },
  );

  testWidgets('「下载执行设备」那台不提供代下载：照样出 attention 条目说明原因', (
    WidgetTester tester,
  ) async {
    final _FakeHosts hosts = _FakeHosts()
      ..capabilities[1] = ((_) => http.Response('{}', 200));
    final List<DownloadTaskEntry> Function() entries = await pumpSection(
      tester,
      hosts,
      preferred: _url(1),
      hostCount: 1,
    );
    final List<DownloadTaskEntry> h1 = ofHost(entries(), 1);
    expect(h1, hasLength(1));
    expect(h1.single.status, DownloadTaskStatus.attention);
    expect(
      find.textContaining(t.interconnect_host_failure_unsupported),
      findsWidgets,
    );
  });

  testWidgets('上一拍的请求还没回来：本拍不对该 host 叠加请求；挂起中 dispose 不抛', (
    WidgetTester tester,
  ) async {
    final Completer<http.Response> hang = Completer<http.Response>();
    final _FakeHosts hosts = _FakeHosts()
      ..capabilities[1] = ((_) => _supported())
      ..jobs[1] = ((_) => hang.future);
    await pumpSection(tester, hosts, hostCount: 1);
    expect(hosts.listCalls[1], 1);

    await tester.pump(_poll);
    await settle(tester);
    await tester.pump(_poll);
    await settle(tester);
    expect(hosts.listCalls[1], 1, reason: '修复前每拍都再发一次');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    hang.complete(_jobs(const <Map<String, Object?>>[]));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
