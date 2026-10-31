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
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/host_jobs/host_input_matcher.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_routes.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String _host = 'http://host-a.invalid:8080';

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

  /// 匹配应答发出之后、客户端继续之前执行（模拟 start 前 host 文件被删）。
  Future<void> Function()? afterMatch;

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

  http.Client client() => MockClient.streaming((
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    final String path = request.url.path;
    requests.add('${request.method} $path');
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
      final Future<void> Function()? hook = afterMatch;
      afterMatch = null;
      if (hook != null) await hook();
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
    jobs = HostJobManager(
      jobRoot: Directory(p.join(root.path, 'host_jobs')),
      runners: <HostJobRunner>[runner],
      inputMatcher: HostInputMatcher(
        candidates: () async => hostCandidates,
        cache: FileContentHashCache(
          hasher: (String path) {
            hostHashes++;
            return ffcSha256File(path);
          },
        ),
      ),
    );
    await jobs.load();
    wire = _HostWire(jobs);
  });

  tearDown(() async {
    await jobs.whenIdle();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(Map<String, File>, List<HostJobUploading>)> runJob() async {
    final InterconnectJobClient client = InterconnectJobClient(
      repo: repo,
      httpClient: wire.client(),
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

    expect(wire.matches, 1);
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

    expect(wire.matches, 1);
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
    expect(wire.matches, 1, reason: '重跑不再复用 host 文件');
    expect(wire.puts, 2);
    expect(out['out.txt']!.readAsStringSync(), '$cd1Content$cd2Content');
    expect(runner.seenHostInputs.first.length, 2);
    expect(runner.seenHostInputs.last, isEmpty);
    // 失败的那个任务已在 host 上清理。
    expect(jobs.list(), isEmpty);
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

  group('FileContentHashCache', () {
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
