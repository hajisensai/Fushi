// 有声书转录交给互联 host 时「host 已有内容相同的文件就不上传」（反馈 j-LhVnQ6hL）。
//
// 端到端：真 InterconnectJobClient ←MockClient.streaming→ 真 handleHostJobRequest +
// HostJobManager + HostInputMatcher + FileContentHashCache（原生 SHA-256）。判定只认
// 内容哈希：host 上的文件名、目录都与本机不同；同名同大小但内容不同的文件不得命中。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show debugInterconnectAddressProbeOverride, resetInterconnectRaceCache;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/host_jobs/host_input_matcher.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart' show HostJobRecord;
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_routes.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String _host = 'http://host-a.invalid:8080';

/// 工厂建出的明文 client：转发给 [_inner]，记下是否被关。
class _OwnedClient extends http.BaseClient {
  _OwnedClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// 按输入名顺序把全部输入拼起来；记下每次看到的输入（路径 / 是否 host 本地）。
class _ConcatRunner implements HostJobRunner {
  final List<Map<String, String>> seenInputs = <Map<String, String>>[];
  final List<Set<String>> seenHostInputs = <Set<String>>[];

  /// 第一次 run 中途调用一次（模拟转录途中 host 文件被改）。
  Future<void> Function()? duringFirstRun;

  @override
  String get kind => 'asr';

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'ready': true,
  };

  @override
  void validateParams(Map<String, Object?> params) {}

  @override
  String contentTypeFor(String outputName) => 'text/plain; charset=utf-8';

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async {
    final Map<String, String> paths = <String, String>{
      for (final String name in ctx.inputNames) name: ctx.input(name).path,
    };
    seenInputs.add(paths);
    seenHostInputs.add(<String>{
      for (final String name in ctx.inputNames)
        if (ctx.isHostInput(name)) name,
    });
    final StringBuffer out = StringBuffer();
    for (final String path in paths.values) {
      out.write(await File(path).readAsString());
    }
    final Future<void> Function()? hook = duringFirstRun;
    duringFirstRun = null;
    if (hook != null) await hook();
    await ctx.output('out.txt').writeAsString(out.toString());
    return const HostJobOutcome(
      outputs: <String, String>{'out.txt': 'out.txt'},
      primaryOutput: 'out.txt',
    );
  }
}

/// host 替身的网络面：记录请求，支持在某条请求应答后插一段动作。
class _HostWire {
  _HostWire(this.jobs);

  final HostJobManager jobs;
  final List<String> requests = <String>[];
  int uploadedBytes = 0;

  /// 终局匹配应答发出之后、客户端继续之前执行（模拟 start 前 host 文件被删）。
  Future<void> Function()? afterMatch;

  /// 非 null 时匹配请求不进真路由，改由它应答（模拟 host 超时 / 出错）。
  Future<http.StreamedResponse> Function()? matchOverride;

  /// 每次匹配应答里的 `pending`。
  final List<bool> matchPending = <bool>[];

  /// 故障注入：每条请求先交给它（[nth] = 同一 method + path 的第几次，从 1 起）。
  /// 返回非 null 即作为应答、抛异常即模拟传输失败；返回 null 照常进真路由。
  Future<http.StreamedResponse?> Function(String method, String path, int nth)?
  fault;
  final Map<String, int> _nth = <String, int>{};
  final StreamController<void> _changed = StreamController<void>.broadcast();

  /// 等到 wire 上出现过满足条件的请求（客户端的尽力清理在流结束之后才发）。
  Future<void> seen(String method, bool Function(String path) where) async {
    while (count(method, where) == 0) {
      await _changed.stream.first.timeout(const Duration(seconds: 10));
    }
  }

  int count(String method, bool Function(String path) where) => requests
      .where(
        (String r) =>
            r.startsWith('$method ') && where(r.substring(method.length + 1)),
      )
      .length;

  int get puts => count('PUT', (String _) => true);
  int get creates => count('POST', (String path) => path == '/api/jobs');
  int get matches =>
      count('POST', (String path) => path.endsWith('/inputs/match'));

  /// 发过匹配请求的任务 id（去重）。
  Set<String> get matchedJobIds => <String>{
    for (final String r in requests)
      if (r.startsWith('POST ') && r.endsWith('/inputs/match')) r.split('/')[3],
  };

  /// 这些主机名的请求一律建连失败（模拟关掉的端口 / 不通的旧地址）。
  final Set<String> deadHosts = <String>{};

  /// 每条请求实际发往的主机名（含被 [deadHosts] 拒掉的）。
  final List<String> requestHosts = <String>[];

  http.Client client() => MockClient.streaming((
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    requestHosts.add(request.url.host);
    if (deadHosts.contains(request.url.host)) {
      throw const SocketException('connection refused');
    }
    final String path = request.url.path;
    requests.add('${request.method} $path');
    _changed.add(null);
    final String key = '${request.method} $path';
    final int nth = _nth[key] = (_nth[key] ?? 0) + 1;
    final Future<http.StreamedResponse?> Function(String, String, int)?
    injected = fault;
    if (injected != null) {
      final http.StreamedResponse? replaced = await injected(
        request.method,
        path,
        nth,
      );
      if (replaced != null) {
        await body.drain<void>();
        return replaced;
      }
    }
    final Future<http.StreamedResponse> Function()? override = matchOverride;
    if (override != null && path.endsWith('/inputs/match')) {
      await body.drain<void>();
      return override();
    }
    Stream<List<int>> counted = body;
    if (request.method == 'PUT') {
      counted = body.map((List<int> chunk) {
        uploadedBytes += chunk.length;
        return chunk;
      });
    }
    final shelf.Response response = await handleHostJobRequest(
      jobs,
      shelf.Request(
        request.method,
        request.url,
        body: counted,
        headers: request.headers,
      ),
      request.method,
      path,
    );
    if (path.endsWith('/inputs/match')) {
      final String text = await response.readAsString();
      final Object? decoded = jsonDecode(text);
      final bool pending = decoded is Map && decoded['pending'] == true;
      matchPending.add(pending);
      // 只在终局应答（不再 pending）之后插动作：那才是客户端据以决定上传的答复。
      final Future<void> Function()? hook = pending ? null : afterMatch;
      if (hook != null) {
        afterMatch = null;
        await hook();
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(text)),
        response.statusCode,
        headers: response.headers,
      );
    }
    return http.StreamedResponse(
      response.read(),
      response.statusCode,
      headers: response.headers,
    );
  });
}

void main() {
  late Directory root;
  late Directory clientDir;
  late Directory hostDir;
  late FushiDatabase db;
  late SyncRepository repo;
  late _ConcatRunner runner;
  late List<String> hostCandidates;
  late int hostHashes;
  late HostInputMatcher matcher;
  late HostJobManager jobs;
  late _HostWire wire;

  File write(String path, String content) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  // 本机两份同名（不同目录）的音频：顺带钉住上传名不再互相覆盖。
  late File cd1;
  late File cd2;
  const String cd1Content = 'chapter-one-audio-bytes';
  const String cd2Content = 'chapter-two-audio-bytes';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('host_input_reuse_');
    clientDir = Directory(p.join(root.path, 'client'));
    hostDir = Directory(p.join(root.path, 'host'));
    cd1 = write(p.join(clientDir.path, 'CD1', '01.mp3'), cd1Content);
    cd2 = write(p.join(clientDir.path, 'CD2', '01.mp3'), cd2Content);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setFushiClientToken('tok');
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: _host, deviceName: 'Desk PC'),
    ]);
    runner = _ConcatRunner();
    hostCandidates = <String>[];
    hostHashes = 0;
    matcher = HostInputMatcher(
      candidates: () async => hostCandidates,
      cache: FileContentHashCache(
        hasher: (String path) {
          hostHashes++;
          return ffcSha256File(path);
        },
      ),
    );
    jobs = HostJobManager(
      jobRoot: Directory(p.join(root.path, 'host_jobs')),
      runners: <HostJobRunner>[runner],
      inputMatcher: matcher,
    );
    await jobs.load();
    wire = _HostWire(jobs);
  });

  tearDown(() async {
    await jobs.whenIdle();
    await matcher.whenWarmIdle();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(Map<String, File>, List<HostJobUploading>)> runJob({
    Duration requestTimeout = const Duration(seconds: 30),
  }) async {
    final InterconnectJobClient client = InterconnectJobClient(
      repo: repo,
      plainClientFactory: wire.client,
      requestTimeout: requestTimeout,
      pollDelay: (int _) => const Duration(milliseconds: 5),
      hashCache: FileContentHashCache(),
    );
    final HostJobTarget target = HostJobTarget(
      baseUrl: _host,
      deviceName: 'Desk PC',
      kinds: const <String>['asr'],
      capability: await jobs.capability(),
    );
    final List<HostJobUploading> uploads = <HostJobUploading>[];
    Map<String, File> outputs = const <String, File>{};
    await for (final HostJobEvent e in client.run(
      target: target,
      kind: 'asr',
      params: const <String, Object?>{'language': 'ja'},
      inputs: <File>[cd1, cd2],
      outputDir: Directory(p.join(root.path, 'out')),
    )) {
      if (e is HostJobUploading) uploads.add(e);
      if (e is HostJobDone) outputs = e.outputs;
    }
    return (outputs, uploads);
  }

  test('能力位宣告 inputMatch=sha256', () async {
    expect((await jobs.capability())['inputMatch'], 'sha256');
  });

  test('全部命中：零上传，runner 读 host 本地文件（名字 / 目录都与本机不同）', () async {
    final File h1 = write(
      p.join(hostDir.path, 'lib', 'disc-a.mp3'),
      cd1Content,
    );
    final File h2 = write(
      p.join(hostDir.path, 'lib', 'disc-b.mp3'),
      cd2Content,
    );
    hostCandidates = <String>[h2.path, h1.path];

    final (Map<String, File> out, List<HostJobUploading> uploads) =
        await runJob();

    // host 缓存是冷的：第一次应答 pending（请求里不算哈希），后台预热完再问才命中。
    expect(wire.matchPending.first, isTrue);
    expect(wire.matchPending.last, isFalse);
    expect(wire.matchedJobIds, hasLength(1));
    expect(wire.puts, 0);
    expect(wire.uploadedBytes, 0);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    // 命中的输入算作已完成，进度直接到 2/2。
    expect(uploads.last.done, 2);
    expect(uploads.last.total, 2);
    final Map<String, String> seen = runner.seenInputs.single;
    expect(seen.values, <String>[h1.path, h2.path]);
    expect(runner.seenHostInputs.single, seen.keys.toSet());
    // 任务清理绝不删 host 自己的文件。
    expect(h1.existsSync() && h2.existsSync(), isTrue);
  });

  test('部分命中：只上传 host 没有的那一份', () async {
    final File h1 = write(
      p.join(hostDir.path, 'lib', 'disc-a.mp3'),
      cd1Content,
    );
    hostCandidates = <String>[h1.path];

    final (Map<String, File> out, _) = await runJob();

    expect(wire.puts, 1);
    expect(wire.uploadedBytes, utf8.encode(cd2Content).length);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    final Map<String, String> seen = runner.seenInputs.single;
    expect(seen.values.first, h1.path);
    expect(runner.seenHostInputs.single.length, 1);
  });

  test('未命中：同名同大小但内容不同不算同一份，全部上传', () async {
    // 与本机 CD1/01.mp3 同名、同字节数，只差内容。
    final File impostor = write(
      p.join(hostDir.path, 'lib', '01.mp3'),
      cd1Content.replaceAll('one', 'uno'),
    );
    expect(impostor.lengthSync(), cd1.lengthSync());
    hostCandidates = <String>[impostor.path];

    final (Map<String, File> out, _) = await runJob();

    expect(wire.matchPending.last, isFalse);
    expect(wire.puts, 2);
    expect(hostHashes, 1, reason: '大小相同的候选才值得算哈希');
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    expect(runner.seenHostInputs.single, isEmpty);
    // 两份同名文件各自落盘，没有互相覆盖。
    expect(runner.seenInputs.single.length, 2);
  });

  test('命中后 host 文件在转录途中被改：作废这次产物，整份上传重跑', () async {
    final File h1 = write(
      p.join(hostDir.path, 'lib', 'disc-a.mp3'),
      cd1Content,
    );
    final File h2 = write(
      p.join(hostDir.path, 'lib', 'disc-b.mp3'),
      cd2Content,
    );
    hostCandidates = <String>[h1.path, h2.path];
    // 同长度改写：大小不变，只能靠整份重读发现。
    runner.duringFirstRun = () async =>
        h1.writeAsStringSync(cd1Content.replaceAll('one', 'xxx'));

    final (Map<String, File> out, _) = await runJob();

    expect(wire.creates, 2, reason: '第一次因 host 文件变化失败后重建任务');
    expect(wire.matchedJobIds, hasLength(1), reason: '重跑不再复用 host 文件');
    expect(wire.puts, 2);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    expect(runner.seenHostInputs.first.length, 2);
    expect(runner.seenHostInputs.last, isEmpty);
    // 失败的那个任务在重跑之前已在 host 上清理（成功那个的清理在交付结果之后才尽力发，
    // 不在这里断言）。
    expect(
      jobs.list().map((HostJobRecord r) => r.id),
      isNot(contains(wire.matchedJobIds.single)),
    );
  });

  test('命中后、开跑前 host 文件被删：开跑前核对发现，回退为上传', () async {
    final File h1 = write(
      p.join(hostDir.path, 'lib', 'disc-a.mp3'),
      cd1Content,
    );
    final File h2 = write(
      p.join(hostDir.path, 'lib', 'disc-b.mp3'),
      cd2Content,
    );
    hostCandidates = <String>[h1.path, h2.path];
    wire.afterMatch = () async => h2.deleteSync();

    final (Map<String, File> out, _) = await runJob();

    expect(wire.creates, 2);
    expect(wire.puts, 2);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    // 第一次根本没进 runner（开跑前就判失败），只有重跑那一次。
    expect(runner.seenInputs.length, 1);
    expect(runner.seenHostInputs.single, isEmpty);
  });

  test('host 没配 matcher（老 host）：不发清单，照旧全部上传', () async {
    final HostJobManager plain = HostJobManager(
      jobRoot: Directory(p.join(root.path, 'plain_jobs')),
      runners: <HostJobRunner>[runner],
    );
    jobs = plain;
    wire = _HostWire(plain);
    expect((await plain.capability()).containsKey('inputMatch'), isFalse);

    final (Map<String, File> out, _) = await runJob();

    expect(wire.matches, 0);
    expect(wire.puts, 2);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
  });

  group('匹配请求不在请求里读文件（2026-10-31 审查：冷哈希让请求超时、整个转录失败）', () {
    Future<List<HostInputWanted>> wantedCd1() async => <HostInputWanted>[
      HostInputWanted(
        name: '000_01.mp3',
        sha256: await ffcSha256File(cd1.path),
        size: cd1.lengthSync(),
      ),
    ];

    test('冷候选：应答 pending、不等哈希；后台算完再问才命中', () async {
      final File h1 = write(
        p.join(hostDir.path, 'lib', 'disc-a.mp3'),
        cd1Content,
      );
      final Completer<void> gate = Completer<void>();
      int hashed = 0;
      final HostInputMatcher gated = HostInputMatcher(
        candidates: () async => <String>[h1.path],
        cache: FileContentHashCache(
          hasher: (String path) async {
            hashed++;
            await gate.future;
            return ffcSha256File(path);
          },
        ),
      );
      final List<HostInputWanted> wanted = await wantedCd1();

      // 哈希卡住时匹配照样立刻应答：没命中、pending。
      final HostInputMatchResult cold = await gated.match(wanted);
      expect(cold.matched, isEmpty);
      expect(cold.pending, isTrue);
      // 预热还没完再问：仍 pending（同一路径不重复排队，见下面 hashed == 1）。
      expect((await gated.match(wanted)).pending, isTrue);

      gate.complete();
      await gated.whenWarmIdle();
      final HostInputMatchResult warm = await gated.match(wanted);
      expect(warm.pending, isFalse);
      expect(warm.matched['000_01.mp3']!.path, h1.path);
      expect(hashed, 1, reason: '两次 pending 应答只排了一次后台哈希');
    });

    test('候选哈希失败：不再 pending（客户端不会一直再问），文件没变不重试', () async {
      final File h1 = write(
        p.join(hostDir.path, 'lib', 'disc-a.mp3'),
        cd1Content,
      );
      int hashed = 0;
      final HostInputMatcher failing = HostInputMatcher(
        candidates: () async => <String>[h1.path],
        cache: FileContentHashCache(
          hasher: (String path) async {
            hashed++;
            throw FileSystemException('locked', path);
          },
        ),
      );
      final List<HostInputWanted> wanted = await wantedCd1();
      expect((await failing.match(wanted)).pending, isTrue);
      await failing.whenWarmIdle();
      final HostInputMatchResult after = await failing.match(wanted);
      expect(after.pending, isFalse);
      expect(after.matched, isEmpty);
      expect(hashed, 1);
    });

    test('匹配应答之前同名输入已上传：上传优先，不记成 host 本地文件', () async {
      final File h1 = write(
        p.join(hostDir.path, 'lib', 'disc-a.mp3'),
        cd1Content,
      );
      // 共享缓存先有 h1 的哈希：这次匹配若不处理竞态就一定会命中。
      await matcher.cache.fingerprint(h1.path);
      final Completer<void> release = Completer<void>();
      final HostJobManager racing = HostJobManager(
        jobRoot: Directory(p.join(root.path, 'racing_jobs')),
        runners: <HostJobRunner>[runner],
        inputMatcher: HostInputMatcher(
          // 候选枚举卡住，模拟客户端等不及这次应答、先按没命中上传了。
          candidates: () async {
            await release.future;
            return <String>[h1.path];
          },
          cache: matcher.cache,
        ),
      );
      await racing.load();
      final HostJobRecord rec = await racing.create(
        'asr',
        const <String, Object?>{'language': 'ja'},
      );
      final Future<({List<String> matched, bool pending})> answer = racing
          .matchInputs(rec.id, await wantedCd1());
      await racing.putInput(
        rec.id,
        '000_01.mp3',
        Stream<List<int>>.value(utf8.encode(cd1Content)),
      );
      release.complete();
      final ({List<String> matched, bool pending}) result = await answer;
      expect(result.matched, isEmpty);
      expect(racing.get(rec.id).hostInputs, isEmpty);
      expect(racing.get(rec.id).inputs, contains('000_01.mp3'));
      await racing.delete(rec.id);
      await racing.whenIdle();
    });
  });

  group('客户端：可选的匹配步骤失败一律退回上传', () {
    test('匹配请求超时：不让任务失败，全部上传', () async {
      final File h1 = write(
        p.join(hostDir.path, 'lib', 'disc-a.mp3'),
        cd1Content,
      );
      hostCandidates = <String>[h1.path];
      // 永不应答。
      wire.matchOverride = () => Completer<http.StreamedResponse>().future;

      final (Map<String, File> out, _) = await runJob(
        requestTimeout: const Duration(milliseconds: 300),
      );

      expect(wire.matches, 1);
      expect(wire.puts, 2);
      expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
      expect(runner.seenHostInputs.single, isEmpty);
    });

    test('匹配应答 500：不让任务失败，全部上传', () async {
      wire.matchOverride = () async => http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('boom')),
        500,
      );

      final (Map<String, File> out, _) = await runJob();

      expect(wire.matches, 1);
      expect(wire.puts, 2);
      expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    });
  });

  group('transient link loss（remote-job-client-lifecycle）', () {
    /// 状态轮询 `GET /api/jobs/<id>`（不含 result / input 等子路径）。
    final RegExp statusPath = RegExp(r'^/api/jobs/[^/]+$');
    bool isResult(String path) => path.contains('/result/');

    /// 跑一次任务，收齐事件与收尾错误；整条流 10 秒内必须结束。
    Future<(List<HostJobEvent>, Object?)> runEvents({
      Duration requestTimeout = const Duration(seconds: 30),
    }) async {
      final InterconnectJobClient client = InterconnectJobClient(
        repo: repo,
        plainClientFactory: wire.client,
        requestTimeout: requestTimeout,
        pollDelay: (int _) => const Duration(milliseconds: 5),
        hashCache: FileContentHashCache(),
      );
      final HostJobTarget target = HostJobTarget(
        baseUrl: _host,
        deviceName: 'Desk PC',
        kinds: const <String>['asr'],
        capability: await jobs.capability(),
      );
      final List<HostJobEvent> events = <HostJobEvent>[];
      Object? error;
      final Completer<void> finished = Completer<void>();
      client
          .run(
            target: target,
            kind: 'asr',
            params: const <String, Object?>{'language': 'ja'},
            inputs: <File>[cd1, cd2],
            outputDir: Directory(p.join(root.path, 'out')),
          )
          .listen(
            events.add,
            onError: (Object e) => error = e,
            onDone: finished.complete,
          );
      await finished.future.timeout(const Duration(seconds: 10));
      return (events, error);
    }

    test('观测途中几次传输失败不删任务：恢复后照常取回，DELETE 恰好一次且在取回之后', () async {
      final Completer<void> release = Completer<void>();
      runner.duringFirstRun = () => release.future;
      wire.fault = (String method, String path, int nth) async {
        if (method == 'GET' && statusPath.hasMatch(path) && nth <= 3) {
          if (nth == 3) release.complete();
          throw const SocketException('link flapped');
        }
        return null;
      };

      final (List<HostJobEvent> events, Object? error) = await runEvents();

      expect(error, isNull);
      expect(events.last, isA<HostJobDone>());
      final HostJobDone done = events.last as HostJobDone;
      expect(
        done.outputs['out.txt']!.readAsStringSync(),
        '$cd1Content$cd2Content',
      );
      await wire.seen('DELETE', (String _) => true);
      expect(wire.count('DELETE', (String _) => true), 1);
      final int lastResult = wire.requests.lastIndexWhere(
        (String r) => r.startsWith('GET ') && isResult(r),
      );
      final int del = wire.requests.indexWhere(
        (String r) => r.startsWith('DELETE '),
      );
      expect(lastResult, greaterThanOrEqualTo(0));
      expect(del, greaterThan(lastResult));
    });

    test('任务已不在 host（404）：报错收尾，不再发 DELETE', () async {
      wire.fault = (String method, String path, int nth) async {
        if (method == 'GET' && statusPath.hasMatch(path) && nth == 1) {
          await jobs.delete(path.split('/').last);
        }
        return null;
      };

      final (List<HostJobEvent> events, Object? error) = await runEvents();

      expect(events.whereType<HostJobDone>(), isEmpty);
      expect(error, isA<HostJobRemoteException>());
      // 尽力清理在流结束之后才发：给它足够的时间暴露出来再断言「没有」。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(wire.count('DELETE', (String _) => true), 0);
    });

    test('取回成功后清理失败（DELETE 回 503）不改结果', () async {
      wire.fault = (String method, String path, int nth) async {
        if (method == 'DELETE') {
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('busy')),
            503,
          );
        }
        return null;
      };

      final (List<HostJobEvent> events, Object? error) = await runEvents();

      expect(error, isNull);
      expect(events.last, isA<HostJobDone>());
      await wire.seen('DELETE', (String _) => true);
    });

    test('响应体卡住的状态 GET 有上界：超时后继续观测并取回', () async {
      final StreamController<List<int>> stuck = StreamController<List<int>>();
      addTearDown(stuck.close);
      wire.fault = (String method, String path, int nth) async {
        if (method == 'GET' && statusPath.hasMatch(path) && nth == 1) {
          // 只发响应头，响应体永远不结束。
          return http.StreamedResponse(stuck.stream, 200);
        }
        return null;
      };

      final (List<HostJobEvent> events, Object? error) = await runEvents(
        requestTimeout: const Duration(milliseconds: 500),
      );

      expect(error, isNull);
      expect(events.last, isA<HostJobDone>());
    });
  });

  // BUG-4392（remote-tasks 步骤 13）：job client 的传输走共享 host 通道——每次 run
  // 一条通道，工厂建出的明文 client 归这次 run、用完必关；按 host 选路，不钉死
  // target.baseUrl 那一条地址。
  group('共享 host 通道（interconnect-client-no-shared-host-channel）', () {
    setUp(resetInterconnectRaceCache);
    tearDown(() {
      debugInterconnectAddressProbeOverride = null;
      resetInterconnectRaceCache();
    });

    Future<void> eventually(bool Function() condition, String reason) async {
      for (int i = 0; i < 500 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue, reason: reason);
    }

    InterconnectJobClient ownedClient(List<_OwnedClient> made) =>
        InterconnectJobClient(
          repo: repo,
          plainClientFactory: () {
            final _OwnedClient c = _OwnedClient(wire.client());
            made.add(c);
            return c;
          },
          pollDelay: (int _) => const Duration(milliseconds: 5),
          hashCache: FileContentHashCache(),
        );

    Future<HostJobTarget> target({String baseUrl = _host}) async =>
        HostJobTarget(
          baseUrl: baseUrl,
          deviceName: 'Desk PC',
          kinds: const <String>['asr'],
          capability: await jobs.capability(),
        );

    test('完整跑完：工厂建出的每个明文 client 都在清理之后被关掉', () async {
      final List<_OwnedClient> made = <_OwnedClient>[];
      final InterconnectJobClient client = ownedClient(made);

      final List<HostJobEvent> events = await client
          .run(
            target: await target(),
            kind: 'asr',
            params: const <String, Object?>{'language': 'ja'},
            inputs: <File>[cd1, cd2],
            outputDir: Directory(p.join(root.path, 'out')),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(events.last, isA<HostJobDone>());
      expect(made, isNotEmpty);
      await eventually(
        () => made.every((_OwnedClient c) => c.closed),
        '一次 run 建出的明文 client 必须在 run 收尾时关掉',
      );
      // 关 client 不能掐掉在途的尽力清理：DELETE 照样到了 host。
      expect(wire.count('DELETE', (String _) => true), 1);
    });

    test('中途取消：DELETE 发出后通道与明文 client 一并关掉', () async {
      final Completer<void> release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      runner.duringFirstRun = () => release.future;
      final List<_OwnedClient> made = <_OwnedClient>[];
      final InterconnectJobClient client = ownedClient(made);

      final Completer<void> running = Completer<void>();
      final StreamSubscription<HostJobEvent> sub = client
          .run(
            target: await target(),
            kind: 'asr',
            params: const <String, Object?>{'language': 'ja'},
            inputs: <File>[cd1, cd2],
            outputDir: Directory(p.join(root.path, 'out')),
          )
          .listen((HostJobEvent e) {
            if (e is HostJobRunning && !running.isCompleted) running.complete();
          }, onError: (Object _) {});
      await running.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
      release.complete();

      await wire.seen('DELETE', (String _) => true);
      await eventually(
        () => made.isNotEmpty && made.every((_OwnedClient c) => c.closed),
        '取消后的 run 也必须关掉它建出的明文 client',
      );
      expect(wire.count('DELETE', (String _) => true), 1);
    });

    test('target 记的是同一台 host 已不通的旧地址：经通道换到可达地址跑完', () async {
      const String dead = 'http://host-a-old-lan.invalid:8080';
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        // 关掉的旧地址排在前面；两条同属一台 host。
        FushiClientUrl(url: dead, hostId: 'host-job-route', deviceName: 'PC'),
        FushiClientUrl(url: _host, hostId: 'host-job-route'),
      ]);
      wire.deadHosts.add(Uri.parse(dead).host);
      debugInterconnectAddressProbeOverride =
          (FushiClientUrl c, String? hostId) async => c.url == _host;

      final InterconnectJobClient client = InterconnectJobClient(
        repo: repo,
        plainClientFactory: wire.client,
        pollDelay: (int _) => const Duration(milliseconds: 5),
        hashCache: FileContentHashCache(),
      );
      final List<HostJobEvent> events = await client
          .run(
            target: await target(baseUrl: dead),
            kind: 'asr',
            params: const <String, Object?>{'language': 'ja'},
            inputs: <File>[cd1, cd2],
            outputDir: Directory(p.join(root.path, 'out')),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(events.last, isA<HostJobDone>());
      final HostJobDone done = events.last as HostJobDone;
      expect(
        done.outputs['out.txt']!.readAsStringSync(),
        '$cd1Content$cd2Content',
      );
      expect(wire.requestHosts, isNot(contains(Uri.parse(dead).host)));
    });

    test('任务进行中在用的地址断了：观测按 host 重新选路，换到同一台 host 的另一条地址取回', () async {
      const String lan = 'http://host-a-lan.invalid:8080';
      final String lanHost = Uri.parse(lan).host;
      final String otherHost = Uri.parse(_host).host;
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: lan, hostId: 'host-job-route', deviceName: 'PC'),
        FushiClientUrl(url: _host, hostId: 'host-job-route'),
      ]);
      // 开跑时只有 LAN 地址核对得通：提交与前几次观测都走它。
      String reachable = lan;
      debugInterconnectAddressProbeOverride =
          (FushiClientUrl c, String? hostId) async => c.url == reachable;

      final Completer<void> release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      runner.duringFirstRun = () => release.future;
      final RegExp statusPath = RegExp(r'^/api/jobs/[^/]+$');
      wire.fault = (String method, String path, int nth) async {
        if (method != 'GET' || !statusPath.hasMatch(path)) return null;
        if (nth == 2) {
          // 这次照常应答；此后 LAN 地址断开，只有另一条地址核对得通。
          wire.deadHosts.add(lanHost);
          reachable = _host;
        } else if (nth == 3) {
          // 第 3 次状态 GET 已经走另一条地址到了 host：放任务跑完。
          release.complete();
        }
        return null;
      };

      final InterconnectJobClient client = InterconnectJobClient(
        repo: repo,
        plainClientFactory: wire.client,
        pollDelay: (int _) => const Duration(milliseconds: 5),
        hashCache: FileContentHashCache(),
      );
      final List<HostJobEvent> events = await client
          .run(
            target: await target(baseUrl: lan),
            kind: 'asr',
            params: const <String, Object?>{'language': 'ja'},
            inputs: <File>[cd1, cd2],
            outputDir: Directory(p.join(root.path, 'out')),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(events.last, isA<HostJobDone>());
      final HostJobDone done = events.last as HostJobDone;
      expect(
        done.outputs['out.txt']!.readAsStringSync(),
        '$cd1Content$cd2Content',
      );
      // 换路前确实拨过 LAN 地址（含断开后撞上的那一次），之后改走另一条且不再回头。
      final int firstOther = wire.requestHosts.indexOf(otherHost);
      expect(firstOther, greaterThan(0));
      expect(wire.requestHosts.sublist(0, firstOther), everyElement(lanHost));
      expect(wire.requestHosts.sublist(firstOther), isNot(contains(lanHost)));
      // 断开那一下是传输失败：进断连子状态，不删任务、不报错。
      expect(
        events.whereType<HostJobRunning>().where(
          (HostJobRunning e) => e.reconnecting,
        ),
        hasLength(1),
      );
      await wire.seen('DELETE', (String _) => true);
      expect(wire.count('DELETE', (String _) => true), 1);
    });
  });

  group('FileContentHashCache', () {
    test('cachedFingerprint 只查缓存、从不读内容；落点可异步解析', () async {
      final File f = write(p.join(root.path, 'b.bin'), 'hello');
      final File store = File(p.join(root.path, 'cache_dir', 'c.json'));
      int hashed = 0;
      final FileContentHashCache cache = FileContentHashCache(
        locateStore: () async => store,
        hasher: (String path) {
          hashed++;
          return ffcSha256File(path);
        },
      );
      expect(await cache.cachedFingerprint(f.path), isNull);
      expect(hashed, 0);
      await cache.fingerprint(f.path);
      expect((await cache.cachedFingerprint(f.path))!.sha256, hasLength(64));
      expect(hashed, 1);
      await cache.flush();
      expect(store.existsSync(), isTrue);
      f.writeAsStringSync('changed!');
      expect(await cache.cachedFingerprint(f.path), isNull);
      expect(hashed, 1);
    });

    test('落盘文件名在给定缓存目录下', () {
      final Directory dir = Directory(p.join(root.path, 'cache'));
      expect(
        p.equals(
          contentHashCacheFile(dir).path,
          p.join(dir.path, 'content_hash_cache.json'),
        ),
        isTrue,
      );
    });

    test('大小 / 修改时刻没变就不重算；变了重算；落盘后新实例直接复用', () async {
      final File f = write(p.join(root.path, 'a.bin'), 'hello');
      final File store = File(p.join(root.path, 'cache.json'));
      int hashed = 0;
      Future<String> counting(String path) {
        hashed++;
        return ffcSha256File(path);
      }

      final FileContentHashCache cache = FileContentHashCache(
        store: store,
        hasher: counting,
      );
      final FileContentFingerprint first = await cache.fingerprint(f.path);
      expect(
        first.sha256,
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
      await cache.fingerprint(f.path);
      expect(hashed, 1);

      f.writeAsStringSync('hello world');
      final FileContentFingerprint second = await cache.fingerprint(f.path);
      expect(second.sha256, isNot(first.sha256));
      expect(hashed, 2);

      await cache.flush();
      final FileContentHashCache reloaded = FileContentHashCache(
        store: store,
        hasher: counting,
      );
      expect((await reloaded.fingerprint(f.path)).sha256, second.sha256);
      expect(hashed, 2);
      // force 无视缓存整份重读。
      await reloaded.fingerprint(f.path, force: true);
      expect(hashed, 3);
    });

    test('文件不存在抛 FileSystemException', () async {
      expect(
        () => FileContentHashCache().fingerprint(p.join(root.path, 'nope')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
