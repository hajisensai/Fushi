import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_package.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 在 [root] 下造一份能被认出的整合包布局。
void _makeLayout(String root) {
  File(p.join(root, 'runtime', 'python.exe'))
    ..createSync(recursive: true)
    ..writeAsStringSync('');
  File(p.join(root, 'api_v2.py')).writeAsStringSync('');
  File(p.join(root, 'GPT_SoVITS', 'configs', 'tts_infer.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('custom:\n  device: cuda\n');
}

class _FakeTar implements Process {
  _FakeTar(this.onRun);
  final void Function() onRun;
  final StreamController<List<int>> _err = StreamController<List<int>>();
  late final Future<int> _exit = Future<int>(() async {
    onRun();
    _err.add(utf8.encode('x GPT-SoVITS-v2pro-20261006/\nx a\nx b\n'));
    await _err.close();
    return 0;
  });

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => 1;
  @override
  Future<int> get exitCode => _exit;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  group('清单解析', () {
    test('HF tree：认 7z 整合包、取 lfs.oid 作 sha256、跳过更新包与杂项', () {
      final List<GptSovitsPackage> list = parseHfGptSovitsListing(<Object?>[
        <String, Object?>{'type': 'file', 'path': '.gitattributes', 'size': 10},
        <String, Object?>{
          'type': 'file',
          'path': 'GPT-SoVITS-v5-20261005.7z',
          'size': 1,
          'lfs': <String, Object?>{'oid': 'A' * 64, 'size': 10869231773},
        },
        <String, Object?>{
          'type': 'file',
          'path': 'GPT-SoVITS-v5-20261005nvidia50x0.7z',
          'size': 5,
        },
        <String, Object?>{
          'type': 'file',
          'path': 'GPT-SoVITS-v2pro-20250604-nvidia50.7z',
          'size': 7,
        },
        <String, Object?>{
          'type': 'file',
          'path': 'GPT-SoVITS_v5update20261006.zip',
          'size': 9,
        },
      ]);
      expect(list.map((GptSovitsPackage e) => e.name), <String>[
        'GPT-SoVITS-v5-20261005.7z',
        'GPT-SoVITS-v5-20261005nvidia50x0.7z',
        'GPT-SoVITS-v2pro-20250604-nvidia50.7z',
      ]);
      expect(list.first.sizeBytes, 10869231773);
      expect(list.first.sha256, 'a' * 64);
      expect(list[1].sha256, isNull);
      expect(list[1].variant, GptSovitsPackageVariant.nvidia50);
      expect(list[2].variant, GptSovitsPackageVariant.nvidia50);
      expect(
        pickLatestGptSovitsPackage(
          list,
          GptSovitsPackageVariant.nvidia50,
        )!.date,
        '20261005',
      );
    });

    test('ModelScope files：Data.Files[].Path/Size/Sha256', () {
      final List<GptSovitsPackage> list = parseModelScopeGptSovitsListing(
        <String, Object?>{
          'Data': <String, Object?>{
            'Files': <Object?>[
              <String, Object?>{
                'Path': 'GPT-SoVITS-v4-20250529.7z',
                'Size': 3,
                'Sha256': 'b' * 64,
                'Type': 'blob',
              },
              <String, Object?>{'Path': 'sub', 'Type': 'tree'},
            ],
          },
        },
      );
      expect(list.single.date, '20250529');
      expect(list.single.sha256, 'b' * 64);
      expect(parseModelScopeGptSovitsListing('nonsense'), isEmpty);
    });

    test('镜像下载地址', () {
      final GptSovitsPackage pkg = kGptSovitsFallbackPackages.first;
      expect(
        pkg.url(GptSovitsPackageSource.huggingFace).toString(),
        'https://huggingface.co/lj1995/GPT-SoVITS-windows-package/resolve/main/'
        'GPT-SoVITS-v5-20261005.7z',
      );
      expect(
        pkg.url(GptSovitsPackageSource.modelScope).toString(),
        'https://www.modelscope.cn/models/FlowerCry/gpt-sovits-7z-pacakges/'
        'resolve/master/GPT-SoVITS-v5-20261005.7z',
      );
    });

    test('RTX 50 系才用 nvidia50 包', () {
      expect(
        gptSovitsVariantForGpu('NVIDIA GeForce RTX 5070 Ti'),
        GptSovitsPackageVariant.nvidia50,
      );
      expect(
        gptSovitsVariantForGpu('NVIDIA GeForce RTX 4070 Ti'),
        GptSovitsPackageVariant.standard,
      );
      expect(gptSovitsVariantForGpu(null), GptSovitsPackageVariant.standard);
    });

    test('tar 版本里没有 liblzma → 不能解 7z', () async {
      expect(
        await systemTarSupports7z(
          run: (String exe, List<String> args) async => (
            exitCode: 0,
            output: 'bsdtar 3.8.9 - libarchive 3.8.9 zlib/1.3 liblzma/5.8.1',
          ),
        ),
        isTrue,
      );
      expect(
        await systemTarSupports7z(
          run: (String exe, List<String> args) async => (
            exitCode: 0,
            output: 'bsdtar 3.5.2 - libarchive 3.5.2 zlib/1.2.5',
          ),
        ),
        isFalse,
      );
      expect(
        await systemTarSupports7z(
          run: (String exe, List<String> args) async =>
              (exitCode: 0, output: 'tar (GNU tar) 1.35'),
        ),
        isFalse,
      );
    });
  });

  group('布局', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gsv_layout_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('顶层目录名不跟包名走：在子目录里按内容找', () {
      final String root = p.join(dir.path, 'GPT-SoVITS-v2pro-20261006');
      _makeLayout(root);
      Directory(p.join(dir.path, 'unrelated')).createSync();
      expect(GptSovitsInstallLayout.find(dir.path)!.root, root);
      expect(GptSovitsInstallLayout.find(root)!.root, root);
      expect(
        GptSovitsInstallLayout.find(p.join(dir.path, 'unrelated')),
        isNull,
      );
    });

    test('启动参数与官方 go-webui.bat 同形，配置用 app 自己的副本', () async {
      _makeLayout(dir.path);
      final GptSovitsInstallLayout layout = GptSovitsInstallLayout.find(
        dir.path,
      )!;
      await layout.ensureAppConfig();
      expect(File(layout.appConfig).readAsStringSync(), contains('device'));
      final GptSovitsLaunchSpec spec = layout.launchSpec(9880);
      expect(spec.executable, p.join(dir.path, 'runtime', 'python.exe'));
      expect(spec.arguments, <String>[
        '-I',
        '-X',
        'utf8',
        'api_v2.py',
        '-a',
        '127.0.0.1',
        '-p',
        '9880',
        '-c',
        'GPT_SoVITS/configs/fushi_tts_infer.yaml',
      ]);
      expect(spec.workingDirectory, dir.path);
    });
  });

  group('安装器', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gsv_install_'));
    tearDown(() => dir.deleteSync(recursive: true));

    GptSovitsCommandRunner tarOk() =>
        (String exe, List<String> args) async => (
          exitCode: 0,
          output: 'bsdtar 3.8.9 - libarchive 3.8.9 liblzma/5.8.1',
        );

    test('下载（校验 sha256）→ 解压 → 找到布局 → 写配置副本 → 删包', () async {
      final List<int> body = utf8.encode('fake 7z bytes');
      final String digest = sha256.convert(body).toString();
      final List<Uri> requested = <Uri>[];
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) async {
        requested.add(request.uri);
        if (request.uri.path.startsWith('/api/')) {
          request.response.write(
            jsonEncode(<Object?>[
              <String, Object?>{
                'type': 'file',
                'path': 'GPT-SoVITS-v9-20300101.7z',
                'size': body.length,
                'lfs': <String, Object?>{'oid': digest, 'size': body.length},
              },
            ]),
          );
        } else {
          request.response.add(body);
        }
        await request.response.close();
      });
      // 把 huggingface.co 的请求改写到本地假服务器。
      HttpClient factory() => _RedirectingClient(server.port);
      List<String>? tarArgs;
      final GptSovitsInstaller installer = GptSovitsInstaller(
        httpClientFactory: factory,
        run: tarOk(),
        spawn: (String exe, List<String> args) async {
          tarArgs = args;
          return _FakeTar(
            () => _makeLayout(
              p.join(
                gptSovitsPackageDir(dir.path),
                'GPT-SoVITS-v2pro-20261006',
              ),
            ),
          );
        },
      );
      final GptSovitsInstallLayout? layout = await installer.install(
        installDir: dir.path,
        source: GptSovitsPackageSource.huggingFace,
        variant: GptSovitsPackageVariant.standard,
      );
      await server.close(force: true);
      expect(installer.failure, isNull);
      expect(installer.step, GptSovitsInstallStep.done);
      expect(installer.package!.name, 'GPT-SoVITS-v9-20300101.7z');
      expect(layout, isNotNull);
      expect(File(layout!.appConfig).existsSync(), isTrue);
      expect(tarArgs!.first, '-xvf');
      // 解到安装目录下的专属子目录，不直接解进用户选的目录。
      expect(tarArgs, contains(gptSovitsPackageDir(dir.path)));
      expect(tarArgs, isNot(contains(dir.path)));
      expect(installer.extractedEntries, 3);
      // 解完删包。
      expect(
        File(
          p.join(gptSovitsPackageDir(dir.path), 'GPT-SoVITS-v9-20300101.7z'),
        ).existsSync(),
        isFalse,
      );
      expect(requested.last.path, endsWith('GPT-SoVITS-v9-20300101.7z'));
    });

    test('系统 tar 不认 7z：一字节不下，直接报 noExtractor', () async {
      int clients = 0;
      final GptSovitsInstaller installer = GptSovitsInstaller(
        httpClientFactory: () {
          clients++;
          return HttpClient();
        },
        run: (String exe, List<String> args) async =>
            (exitCode: 0, output: 'tar (GNU tar) 1.35'),
      );
      expect(
        await installer.install(
          installDir: dir.path,
          source: GptSovitsPackageSource.huggingFace,
          variant: GptSovitsPackageVariant.standard,
        ),
        isNull,
      );
      expect(installer.failure, GptSovitsInstallFailure.noExtractor);
      expect(clients, 1);
      expect(dir.listSync(), isEmpty);
    });

    test('清单不给 sha256：不装清单里的包，退回钉死摘要的兜底包', () async {
      final List<int> body = utf8.encode('tampered 7z bytes');
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) async {
        if (request.uri.path.startsWith('/api/')) {
          request.response.write(
            jsonEncode(<Object?>[
              <String, Object?>{
                'type': 'file',
                'path': 'GPT-SoVITS-v9-20300101.7z',
                'size': body.length,
              },
            ]),
          );
        } else {
          request.response.add(body);
        }
        await request.response.close();
      });
      int tarRuns = 0;
      final GptSovitsInstaller installer = GptSovitsInstaller(
        httpClientFactory: () => _RedirectingClient(server.port),
        run: tarOk(),
        spawn: (String exe, List<String> args) async {
          tarRuns++;
          return _FakeTar(() {});
        },
      );
      final GptSovitsInstallLayout? layout = await installer.install(
        installDir: dir.path,
        source: GptSovitsPackageSource.huggingFace,
        variant: GptSovitsPackageVariant.standard,
      );
      await server.close(force: true);
      expect(layout, isNull);
      expect(installer.package!.name, kGptSovitsFallbackPackages.first.name);
      expect(installer.package!.sha256, isNotNull);
      // 假服务器回的是篡改内容：兜底包校验失败，一字节不解压。
      expect(installer.failure, GptSovitsInstallFailure.corrupt);
      expect(tarRuns, 0);
    });

    test('没有摘要的包只能借用同名同体积的钉死摘要', () {
      final GptSovitsPackage pinned = kGptSovitsFallbackPackages.first;
      GptSovitsPackage unsigned(int size) => GptSovitsPackage(
        name: pinned.name,
        sizeBytes: size,
        sha256: null,
        date: pinned.date,
        variant: pinned.variant,
      );
      expect(
        gptSovitsWithTrustedDigest(unsigned(pinned.sizeBytes))?.sha256,
        pinned.sha256,
      );
      expect(
        gptSovitsWithTrustedDigest(unsigned(pinned.sizeBytes + 1)),
        isNull,
      );
    });
  });

  group('引擎门面', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gsv_engine_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('指向已有整合包、按需拉起只认托管端口', () async {
      _makeLayout(p.join(dir.path, 'pkg'));
      final List<int> started = <int>[];
      final GptSovitsLocalEngine engine = GptSovitsLocalEngine(
        prefs: MemoryPrefStore(),
        httpClientFactory: HttpClient.new,
        supported: true,
        server: GptSovitsLocalServer(
          spawn:
              (
                String exe,
                List<String> args, {
                workingDirectory,
                environment,
              }) async {
                started.add(int.parse(args[args.indexOf('-p') + 1]));
                return _FakeTar(() {});
              },
          probe: _probeAfter(1),
          probeInterval: Duration.zero,
        ),
      );
      expect(engine.isInstalled, isFalse);
      expect(await engine.useExisting(p.join(dir.path, 'missing')), isFalse);
      expect(await engine.useExisting(dir.path), isTrue);
      expect(engine.isInstalled, isTrue);
      expect(engine.settings.owned, isFalse);
      expect(engine.endpoint, 'http://127.0.0.1:9880');

      await engine.ensureRunningFor('http://192.168.1.2:9880');
      await engine.ensureRunningFor('http://127.0.0.1:9881');
      expect(started, isEmpty);
      await engine.ensureRunningFor('http://localhost:9880/tts');
      expect(started, <int>[9880]);
      expect(engine.server.isRunning, isTrue);

      // 不是 app 装的：删除只忘掉，不动用户的文件。
      await engine.remove(deleteFiles: true);
      expect(engine.isInstalled, isFalse);
      expect(Directory(p.join(dir.path, 'pkg')).existsSync(), isTrue);
    });

    /// 预置一份已保存设置的偏好仓（模拟安装器已经装好、引擎已经记下）。
    MemoryPrefStore prefsWith(GptSovitsLocalSettings settings) =>
        MemoryPrefStore()
          ..values[kGptSovitsLocalPrefKey] = jsonEncode(settings.toJson());

    test('删除只删 app 专属子目录，用户选的安装目录与其中别的文件不动', () async {
      final String installDir = p.join(dir.path, 'D_drive_root');
      final File userFile = File(p.join(installDir, 'my_notes.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('keep me');
      final String packageDir = gptSovitsPackageDir(installDir);
      _makeLayout(p.join(packageDir, 'GPT-SoVITS-v2pro-20261006'));
      File(
        p.join(packageDir, 'GPT-SoVITS-v5-20261005.7z.part'),
      ).writeAsStringSync('partial');
      final GptSovitsLocalEngine engine = GptSovitsLocalEngine(
        prefs: prefsWith(GptSovitsLocalSettings(dir: packageDir, owned: true)),
        httpClientFactory: HttpClient.new,
        supported: true,
        server: GptSovitsLocalServer(probe: (int port) async => false),
      );
      expect(engine.isInstalled, isTrue);
      expect(engine.canDeleteFiles, isTrue);

      await engine.remove(deleteFiles: true);
      expect(engine.isInstalled, isFalse);
      expect(Directory(packageDir).existsSync(), isFalse);
      expect(Directory(installDir).existsSync(), isTrue);
      expect(userFile.readAsStringSync(), 'keep me');
    });

    test('记录指向的不是专属子目录：即使 owned 也绝不删', () async {
      final String userDir = p.join(dir.path, 'user_dir');
      _makeLayout(userDir);
      final GptSovitsLocalEngine engine = GptSovitsLocalEngine(
        prefs: prefsWith(GptSovitsLocalSettings(dir: userDir, owned: true)),
        httpClientFactory: HttpClient.new,
        supported: true,
        server: GptSovitsLocalServer(probe: (int port) async => false),
      );
      expect(engine.canDeleteFiles, isFalse);
      await engine.remove(deleteFiles: true);
      expect(File(p.join(userDir, 'api_v2.py')).existsSync(), isTrue);
    });

    test('自动拉起失败一次后不再每句重拉，手动启动解除', () async {
      _makeLayout(p.join(dir.path, 'pkg'));
      int spawns = 0;
      final GptSovitsLocalEngine engine = GptSovitsLocalEngine(
        prefs: MemoryPrefStore(),
        httpClientFactory: HttpClient.new,
        supported: true,
        server: GptSovitsLocalServer(
          spawn:
              (
                String exe,
                List<String> args, {
                workingDirectory,
                environment,
              }) async {
                spawns++;
                throw const ProcessException('python.exe', <String>[], 'nope');
              },
          probe: (int port) async => false,
          probeInterval: Duration.zero,
        ),
      );
      expect(await engine.useExisting(dir.path), isTrue);
      await engine.ensureRunningFor('http://127.0.0.1:9880');
      expect(spawns, 1);
      expect(engine.autoStartBlocked, isTrue);
      await engine.ensureRunningFor('http://127.0.0.1:9880');
      await engine.ensureRunningFor('http://127.0.0.1:9880');
      expect(spawns, 1);
      expect(await engine.start(), isFalse);
      expect(spawns, 2);
    });

    test('等服务就绪期间取消合成：立刻报 cancelled，不干等启动', () async {
      _makeLayout(p.join(dir.path, 'pkg'));
      final Completer<bool> probeGate = Completer<bool>();
      final GptSovitsLocalEngine engine = GptSovitsLocalEngine(
        prefs: MemoryPrefStore(),
        httpClientFactory: HttpClient.new,
        supported: true,
        // 首次探活一直不返回：模拟加载底模的漫长等待。
        server: GptSovitsLocalServer(probe: (int port) => probeGate.future),
      );
      expect(await engine.useExisting(dir.path), isTrue);
      final TtsProvider provider = AutoStartGptSovitsTtsDescriptor(engine)
          .create(
            const TtsVoicePreset(
              id: 'v',
              providerId: GptSovitsTtsDescriptor.providerId,
              name: 'v',
              params: <String, String>{
                GptSovitsTtsDescriptor.endpointKey: 'http://127.0.0.1:9880',
              },
            ),
            const TtsHost(),
          );
      final TtsCancelToken cancel = TtsCancelToken();
      final Future<TtsResult> pending = provider.synthesize(
        'テスト',
        outputPath: p.join(dir.path, 'out.wav'),
        cancel: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();
      await expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.cancelled,
          ),
        ),
      );
      await engine.stop();
      probeGate.complete(false);
    });

    test('设置的 JSON 往返，坏值回落默认', () {
      final GptSovitsLocalSettings s = GptSovitsLocalSettings.fromJson(
        jsonDecode(
          jsonEncode(
            const GptSovitsLocalSettings(
              dir: 'D:/gsv',
              port: 9999,
              source: GptSovitsPackageSource.modelScope,
              owned: true,
            ).toJson(),
          ),
        ),
      );
      expect(s.dir, 'D:/gsv');
      expect(s.port, 9999);
      expect(s.source, GptSovitsPackageSource.modelScope);
      expect(s.owned, isTrue);
      final GptSovitsLocalSettings bad = GptSovitsLocalSettings.fromJson(
        <String, Object?>{'port': 70000, 'source': 'nope', 'dir': ''},
      );
      expect(bad.port, kGptSovitsDefaultPort);
      expect(bad.source, GptSovitsPackageSource.huggingFace);
      expect(bad.dir, isNull);
    });
  });

  test('托管地址判据', () {
    expect(gptSovitsEndpointIsManaged('http://127.0.0.1:9880', 9880), isTrue);
    expect(gptSovitsEndpointIsManaged('http://[::1]:9880/tts', 9880), isTrue);
    expect(gptSovitsEndpointIsManaged('http://127.0.0.1', 9880), isFalse);
    expect(gptSovitsEndpointIsManaged('http://10.0.0.2:9880', 9880), isFalse);
  });
}

/// 第一次（启动前的占用检查）为否，之后第 [n] 次起为真。
GptSovitsProbe _probeAfter(int n) {
  int calls = 0;
  return (int port) async => ++calls > n;
}

/// 把所有请求改写到 127.0.0.1:[port]（保留 path / query）。
class _RedirectingClient implements HttpClient {
  _RedirectingClient(this.port);
  final int port;
  final HttpClient _inner = HttpClient();

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _inner.getUrl(url.replace(scheme: 'http', host: '127.0.0.1', port: port));

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
