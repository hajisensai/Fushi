import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/local/irodori_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 立刻以 [code] 退出的假进程；[stdoutText] 进标准输出。
class _FakeProcess implements Process {
  _FakeProcess(int code, {String stdoutText = ''})
    : _out = Stream<List<int>>.value(utf8.encode(stdoutText)),
      _exit = Future<int>.value(code);

  final Stream<List<int>> _out;
  final Future<int> _exit;

  @override
  Stream<List<int>> get stdout => _out;
  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => 1;
  @override
  Future<int> get exitCode => _exit;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

List<int> _zip(Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// 一份全部指向假文件的小清单（结构与正式清单一致）。
class _Fixture {
  _Fixture() {
    uvZip = _zip(<String, String>{'uv.exe': 'uv', 'uvx.exe': 'uvx'});
    serverZip = _zip(<String, String>{
      'Irodori-TTS-Server-abc/pyproject.toml': '[project]',
      'Irodori-TTS-Server-abc/uv.lock': 'lock',
    });
    depZip = _zip(<String, String>{'dep-def/setup.py': 'setup()'});
    modelBytes = utf8.encode('model weights');
    tokenizerBytes = utf8.encode('{}');
    codecBytes = utf8.encode('codec');
    final IrodoriModelRepo model = IrodoriModelRepo(
      repo: 'Aratako/M',
      revision: 'r1',
      files: <IrodoriPinnedFile>[
        IrodoriPinnedFile(
          path: 'model.safetensors',
          size: modelBytes.length,
          sha256: _sha(modelBytes),
        ),
        IrodoriPinnedFile(
          path: 'tokenizer/tokenizer.json',
          size: tokenizerBytes.length,
          sha256: _sha(tokenizerBytes),
        ),
      ],
    );
    manifest = IrodoriManifest(
      uvVersion: '9.9.9',
      uvAssets: <String, IrodoriUvAsset>{
        'windows_x64': IrodoriUvAsset(
          name: 'uv-win.zip',
          size: uvZip.length,
          sha256: _sha(uvZip),
        ),
      },
      pythonVersion: '3.10',
      server: IrodoriSourceArchive(
        repo: 'Aratako/Irodori-TTS-Server',
        commit: 'abc',
        dirName: 'server',
        size: serverZip.length,
        sha256: _sha(serverZip),
      ),
      dependencies: <IrodoriSourceArchive>[
        IrodoriSourceArchive(
          repo: 'o/dep',
          commit: 'def',
          dirName: 'dep',
          size: depZip.length,
          sha256: _sha(depZip),
          lockedRequirement: 'dep @ git+https://github.com/o/dep@def',
        ),
      ],
      models: <IrodoriModelChoice, IrodoriModelRepo>{
        IrodoriModelChoice.small: model,
        IrodoriModelChoice.smallMeanFlow: model,
      },
      codec: IrodoriModelRepo(
        repo: 'Aratako/C',
        revision: 'r2',
        files: <IrodoriPinnedFile>[
          IrodoriPinnedFile(
            path: 'weights.pth',
            size: codecBytes.length,
            sha256: _sha(codecBytes),
          ),
        ],
      ),
    );
  }

  late final List<int> uvZip;
  late final List<int> serverZip;
  late final List<int> depZip;
  late final List<int> modelBytes;
  late final List<int> tokenizerBytes;
  late final List<int> codecBytes;
  late final IrodoriManifest manifest;
  final List<Uri> requested = <Uri>[];

  /// 改坏这个 URL 路径的返回（测试 sha256 不符）。
  String? corruptPath;

  List<int> bodyFor(Uri uri) {
    final String path = uri.path;
    if (path.endsWith('uv-win.zip')) return uvZip;
    if (path.contains('Irodori-TTS-Server')) return serverZip;
    if (path.contains('o/dep')) return depZip;
    if (path.endsWith('model.safetensors')) return modelBytes;
    if (path.endsWith('tokenizer.json')) return tokenizerBytes;
    if (path.endsWith('weights.pth')) return codecBytes;
    throw StateError('unexpected $uri');
  }

  Future<ResumableDownloadResponse> open(
    Uri uri,
    Map<String, String> headers,
  ) async {
    requested.add(uri);
    List<int> body = bodyFor(uri);
    if (corruptPath != null && uri.path.endsWith(corruptPath!)) {
      body = List<int>.filled(body.length, 0);
    }
    return ResumableDownloadResponse.bytes(statusCode: 200, body: body);
  }
}

/// 导出的锁定清单片段（与上游 `uv export --emit-index-url` 同形）。
const String _exported = '''
# This file was autogenerated by uv via the following command:
--index-url https://pypi.org/simple
--extra-index-url https://download.pytorch.org/whl/cpu
--extra-index-url https://download.pytorch.org/whl/cu128
--extra-index-url https://download.pytorch.org/whl/rocm7.1
dep @ git+https://github.com/o/dep@def
torch==2.10.0+cu128 ; sys_platform == 'linux' or sys_platform == 'win32' \\
    --hash=sha256:aaaa
''';

void main() {
  group('锁定清单改写', () {
    const Map<String, String> sources = <String, String>{
      'dep @ git+https://github.com/o/dep@def': r'C:\x\src\dep',
    };

    test('git 依赖换成本地目录、只留所选后端的 PyTorch 源、末尾加服务本体', () {
      final String out = rewriteIrodoriRequirements(
        _exported,
        localSources: sources,
        backend: IrodoriTorchBackend.cu128,
        isMacOS: false,
        serverDir: r'C:\x\src\server',
        windowsPaths: true,
      );
      expect(out, contains('dep @ file:///C:/x/src/dep\n'));
      expect(out, isNot(contains('git+')));
      expect(
        out,
        contains('--extra-index-url https://download.pytorch.org/whl/cu128'),
      );
      expect(out, isNot(contains('whl/cpu')));
      expect(out, isNot(contains('rocm7.1')));
      expect(out, contains('--index-url https://pypi.org/simple'));
      // 哈希续行原样保留。
      expect(out, contains('    --hash=sha256:aaaa'));
      expect(
        out.trim().split('\n').last,
        'irodori-tts-server @ file:///C:/x/src/server',
      );
    });

    test('macOS：cpu extra 走 PyPI，一个 PyTorch 源都不留', () {
      final String out = rewriteIrodoriRequirements(
        _exported,
        localSources: const <String, String>{
          'dep @ git+https://github.com/o/dep@def': '/x/src/dep',
        },
        backend: IrodoriTorchBackend.cpu,
        isMacOS: true,
        serverDir: '/x/src/server',
        windowsPaths: false,
      );
      expect(out, isNot(contains('--extra-index-url')));
      expect(out, contains('dep @ file:///x/src/dep'));
    });

    test('锁文件里缺了钉死的 git 依赖、或多出别的 git 依赖：拒绝', () {
      expect(
        () => rewriteIrodoriRequirements(
          'torch==2.10.0\n',
          localSources: sources,
          backend: IrodoriTorchBackend.cpu,
          isMacOS: false,
          serverDir: '/s',
          windowsPaths: false,
        ),
        throwsFormatException,
      );
      expect(
        () => rewriteIrodoriRequirements(
          '$_exported\nother @ git+https://example.com/x@1\n',
          localSources: sources,
          backend: IrodoriTorchBackend.cpu,
          isMacOS: false,
          serverDir: '/s',
          windowsPaths: false,
        ),
        throwsFormatException,
      );
    });
  });

  group('清单与平台', () {
    test('正式清单：每样东西都钉了 sha256，git 依赖与 uv.lock 的 commit 一致', () {
      final IrodoriManifest m = kIrodoriManifest;
      final RegExp hex = RegExp(r'^[0-9a-f]{64}$');
      for (final IrodoriUvAsset a in m.uvAssets.values) {
        expect(a.sha256, matches(hex), reason: a.name);
      }
      for (final IrodoriSourceArchive a in <IrodoriSourceArchive>[
        m.server,
        ...m.dependencies,
      ]) {
        expect(a.sha256, matches(hex), reason: a.repo);
      }
      for (final IrodoriSourceArchive d in m.dependencies) {
        expect(d.lockedRequirement, endsWith('@${d.commit}'));
      }
      for (final IrodoriModelRepo r in <IrodoriModelRepo>[
        ...m.models.values,
        m.codec,
      ]) {
        for (final IrodoriPinnedFile f in r.files) {
          expect(f.sha256, matches(hex), reason: '${r.repo}/${f.path}');
        }
      }
      expect(m.pythonVersion, '3.10');
    });

    test('模型地址按所选源拼、钉 revision', () {
      final IrodoriModelRepo r =
          kIrodoriManifest.models[IrodoriModelChoice.small]!;
      expect(
        r.url(IrodoriDownloadSource.hfMirror, r.files.first).toString(),
        'https://hf-mirror.com/Aratako/Irodori-TTS-v4.1-Small/resolve/'
        '${r.revision}/model.safetensors',
      );
    });

    test('后端默认：N 卡 → cu128，否则 cpu；macOS 恒 cpu、不给 cu128', () {
      expect(
        irodoriBackendFor(nvidiaGpu: 'RTX 4070', isMacOS: false),
        IrodoriTorchBackend.cu128,
      );
      expect(
        irodoriBackendFor(nvidiaGpu: null, isMacOS: false),
        IrodoriTorchBackend.cpu,
      );
      expect(
        irodoriBackendFor(nvidiaGpu: 'x', isMacOS: true),
        IrodoriTorchBackend.cpu,
      );
      expect(
        irodoriBackendsFor(isMacOS: true, isLinux: false),
        <IrodoriTorchBackend>[IrodoriTorchBackend.cpu],
      );
      expect(
        irodoriBackendsFor(isMacOS: false, isLinux: false),
        isNot(contains(IrodoriTorchBackend.rocm)),
      );
    });

    test('父进程里改 uv / Python 行为的变量不带给安装命令', () {
      expect(irodoriInheritedEnvBlocked('UV_INDEX_URL'), isTrue);
      expect(irodoriInheritedEnvBlocked('VIRTUAL_ENV'), isTrue);
      expect(irodoriInheritedEnvBlocked('PYTHONPATH'), isTrue);
      expect(irodoriInheritedEnvBlocked('PATH'), isFalse);
      expect(irodoriInheritedEnvBlocked('HTTPS_PROXY'), isFalse);
    });
  });

  group('安装器', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('irodori_install_'));
    tearDown(() => dir.deleteSync(recursive: true));

    IrodoriInstaller installerFor(
      _Fixture f,
      List<List<String>> commands, {
      int failExitOn = -1,
      Map<String, String>? lastEnv,
    }) => IrodoriInstaller(
      httpClientFactory: () => HttpClient(),
      manifest: f.manifest,
      open: f.open,
      platformKey: 'windows_x64',
      isMacOS: false,
      windowsPaths: true,
      childProxyEnvironment: () async => <String, String>{
        'HTTPS_PROXY': 'http://127.0.0.1:1',
      },
      spawn:
          (
            String exe,
            List<String> args, {
            required String workingDirectory,
            required Map<String, String> environment,
          }) async {
            commands.add(args);
            lastEnv
              ?..clear()
              ..addAll(environment);
            if (commands.length - 1 == failExitOn) {
              return _FakeProcess(2, stdoutText: 'error: boom');
            }
            final IrodoriInstallLayout layout = IrodoriInstallLayout(
              p.join(dir.path, kIrodoriInstallSubdir),
              windows: true,
            );
            if (args.first == 'export') {
              final int at = args.indexOf('--output-file');
              File(args[at + 1]).writeAsStringSync(_exported);
            } else if (args.first == 'venv') {
              File(layout.venvPython)
                ..createSync(recursive: true)
                ..writeAsStringSync('');
            }
            return _FakeProcess(0, stdoutText: 'ok ${args.first}');
          },
    );

    test('uv → 源码 → Python → 锁定依赖 → 模型；重装只补缺的', () async {
      final _Fixture f = _Fixture();
      final List<List<String>> commands = <List<String>>[];
      final Map<String, String> env = <String, String>{};
      final IrodoriInstaller installer = installerFor(
        f,
        commands,
        lastEnv: env,
      );
      final String root = irodoriPackageDir(dir.path);
      final bool ok = await installer.install(
        root: root,
        backend: IrodoriTorchBackend.cu128,
        model: IrodoriModelChoice.small,
        source: IrodoriDownloadSource.huggingFace,
      );
      expect(installer.detail, isNull);
      expect(ok, isTrue);
      expect(installer.step, IrodoriInstallStep.done);

      final IrodoriInstallLayout layout = IrodoriInstallLayout(
        root,
        windows: true,
      );
      expect(File(layout.uvExecutable).readAsStringSync(), 'uv');
      // GitHub zip 的顶层目录被去掉。
      expect(
        File(p.join(layout.serverDir, 'pyproject.toml')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(layout.srcDir, 'dep', 'setup.py')).existsSync(),
        isTrue,
      );
      expect(commands.map((List<String> c) => c.first).toList(), <String>[
        'python',
        'export',
        'venv',
        'pip',
      ]);
      expect(commands[0], containsAll(<String>['--no-bin', '--no-registry']));
      expect(
        commands[1],
        containsAll(<String>['--frozen', '--extra', 'cu128']),
      );
      expect(commands[2], contains('--managed-python'));
      expect(commands[3], containsAll(<String>['unsafe-best-match', 'sync']));
      // 缓存 / Python 都钉在专属目录；代理经 app 中继。
      expect(env['UV_CACHE_DIR'], layout.cacheDir);
      expect(env['UV_PYTHON_INSTALL_DIR'], layout.pythonDir);
      expect(env['HTTPS_PROXY'], 'http://127.0.0.1:1');
      expect(env.keys.where((String k) => k.startsWith('UV_INDEX')), isEmpty);
      final String req = File(layout.requirements).readAsStringSync();
      expect(req, isNot(contains('git+')));
      expect(req, contains('irodori-tts-server @ file:///'));
      final IrodoriModelRepo model =
          f.manifest.models[IrodoriModelChoice.small]!;
      expect(layout.hasModel(model), isTrue);
      expect(layout.hasModel(f.manifest.codec), isTrue);
      expect(layout.readState()!.backend, IrodoriTorchBackend.cu128);
      expect(Directory(layout.downloadsDir).existsSync(), isFalse);

      // 再装一次：环境指纹与后端都对、模型齐 → 不下载也不跑命令。
      commands.clear();
      f.requested.clear();
      expect(
        await installer.install(
          root: root,
          backend: IrodoriTorchBackend.cu128,
          model: IrodoriModelChoice.small,
          source: IrodoriDownloadSource.huggingFace,
        ),
        isTrue,
      );
      expect(commands, isEmpty);
      expect(f.requested, isEmpty);

      // 换后端：源码已在（commit 对），只重装环境。
      expect(
        await installer.install(
          root: root,
          backend: IrodoriTorchBackend.cpu,
          model: IrodoriModelChoice.small,
          source: IrodoriDownloadSource.huggingFace,
        ),
        isTrue,
      );
      expect(f.requested, isEmpty);
      expect(commands[1], contains('cpu'));
    });

    test('uv 命令失败 → environment，日志尾带输出，不写状态', () async {
      final _Fixture f = _Fixture();
      final List<List<String>> commands = <List<String>>[];
      final IrodoriInstaller installer = installerFor(
        f,
        commands,
        failExitOn: 3,
      );
      final String root = irodoriPackageDir(dir.path);
      expect(
        await installer.install(
          root: root,
          backend: IrodoriTorchBackend.cpu,
          model: IrodoriModelChoice.small,
          source: IrodoriDownloadSource.huggingFace,
        ),
        isFalse,
      );
      expect(installer.step, IrodoriInstallStep.failed);
      expect(installer.failure, IrodoriInstallFailure.environment);
      expect(installer.logTail, contains('error: boom'));
      expect(IrodoriInstallLayout(root).readState(), isNull);
    });

    test('模型 sha256 不符 → corrupt，坏文件不落成正式文件', () async {
      final _Fixture f = _Fixture()..corruptPath = 'weights.pth';
      final IrodoriInstaller installer = installerFor(f, <List<String>>[]);
      final String root = irodoriPackageDir(dir.path);
      expect(
        await installer.install(
          root: root,
          backend: IrodoriTorchBackend.cpu,
          model: IrodoriModelChoice.small,
          source: IrodoriDownloadSource.huggingFace,
        ),
        isFalse,
      );
      expect(installer.failure, IrodoriInstallFailure.corrupt);
      expect(
        IrodoriInstallLayout(root, windows: true).hasModel(f.manifest.codec),
        isFalse,
      );
    });

    test('本平台没有 uv 发行包 → unsupported，一字节不下', () async {
      final _Fixture f = _Fixture();
      final IrodoriInstaller installer = IrodoriInstaller(
        httpClientFactory: () => HttpClient(),
        manifest: f.manifest,
        open: f.open,
        platformKey: 'linux_riscv64',
      );
      expect(
        await installer.install(
          root: irodoriPackageDir(dir.path),
          backend: IrodoriTorchBackend.cpu,
          model: IrodoriModelChoice.small,
          source: IrodoriDownloadSource.huggingFace,
        ),
        isFalse,
      );
      expect(installer.failure, IrodoriInstallFailure.unsupported);
      expect(f.requested, isEmpty);
    });
  });

  group('引擎门面', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('irodori_engine_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('设置 JSON 往返；保留端口与坏值回落默认', () {
      const IrodoriLocalSettings s = IrodoriLocalSettings(
        dir: '/x/fushi-irodori-tts',
        port: 18088,
        source: IrodoriDownloadSource.hfMirror,
        backend: IrodoriTorchBackend.cpu,
        model: IrodoriModelChoice.smallMeanFlow,
        owned: true,
      );
      final IrodoriLocalSettings back = IrodoriLocalSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())),
      );
      expect(back.toJson(), s.toJson());
      final IrodoriLocalSettings bad = IrodoriLocalSettings.fromJson(
        <String, Object?>{'port': 7870, 'model': '??', 'backend': 'xpu'},
      );
      expect(bad.port, kIrodoriDefaultPort);
      expect(bad.model, IrodoriModelChoice.small);
      expect(bad.backend, isNull);
      expect(irodoriPortAllowed(9880), isFalse);
      expect(irodoriPortAllowed(80), isFalse);
      expect(irodoriPortAllowed(8088), isTrue);
    });

    test('启动参数与环境：官方模块、回环、模型走本地路径、预加载', () async {
      final IrodoriInstallLayout layout = IrodoriInstallLayout(
        p.join(dir.path, kIrodoriInstallSubdir),
      );
      final IrodoriModelRepo model =
          kIrodoriManifest.models[IrodoriModelChoice.small]!;
      final Map<String, String> env = irodoriServerEnvironment(
        layout: layout,
        model: model,
        codec: kIrodoriManifest.codec,
        port: 8088,
        source: IrodoriDownloadSource.hfMirror,
      );
      expect(env['IRODORI_CHECKPOINT'], endsWith('model.safetensors'));
      expect(env['IRODORI_CHECKPOINT'], startsWith(layout.modelsDir));
      expect(env['IRODORI_CODEC_REPO'], endsWith('weights.pth'));
      expect(env['IRODORI_HF_CHECKPOINT'], 'Aratako/Irodori-TTS-v4.1-Small');
      expect(env['IRODORI_VOICES_DIR'], layout.voicesDir);
      expect(env['IRODORI_PRELOAD'], 'true');
      expect(env['HF_ENDPOINT'], 'https://hf-mirror.com');
      expect(env['HF_HOME'], layout.hfHome);
      expect(env['PYTHONUTF8'], '1');

      final MemoryPrefStore prefs = MemoryPrefStore();
      final IrodoriLocalEngine engine = IrodoriLocalEngine(
        prefs: prefs,
        httpClientFactory: () => HttpClient(),
        supported: true,
      );
      await engine.setPort(18088);
      final LocalServiceLaunchSpec spec = engine.launchSpec(layout);
      expect(spec.executable, layout.venvPython);
      expect(spec.arguments, <String>[
        '-m',
        'irodori_openai_tts',
        '--host',
        '127.0.0.1',
        '--port',
        '18088',
      ]);
      expect(spec.workingDirectory, layout.serverDir);
      expect(await engine.setPort(7871), isFalse);
      expect(engine.settings.port, 18088);
      engine.dispose();
    });

    test('没装 → isInstalled 为假，按需拉起什么都不做；删除只删专属子目录', () async {
      final MemoryPrefStore prefs = MemoryPrefStore();
      int spawns = 0;
      final IrodoriLocalEngine engine = IrodoriLocalEngine(
        prefs: prefs,
        httpClientFactory: () => HttpClient(),
        supported: true,
        server: IrodoriLocalServer(
          probe: (int _) async => false,
          spawn:
              (
                String exe,
                List<String> args, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async {
                spawns++;
                return _FakeProcess(1);
              },
        ),
      );
      expect(engine.isInstalled, isFalse);
      await engine.ensureRunningFor('http://127.0.0.1:8088');
      expect(spawns, 0);

      // 记录指向专属子目录、且 app 所装：删除连同里面的东西一起删；用户目录不动。
      final File keep = File(p.join(dir.path, 'keep.txt'))
        ..writeAsStringSync('x');
      final Directory sub = Directory(irodoriPackageDir(dir.path))
        ..createSync(recursive: true);
      File(p.join(sub.path, 'voices', 'a.wav'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      await prefs.setPref(
        kIrodoriLocalPrefKey,
        jsonEncode(IrodoriLocalSettings(dir: sub.path, owned: true).toJson()),
      );
      expect(engine.canDeleteFiles, isTrue);
      await engine.remove(deleteFiles: true);
      expect(sub.existsSync(), isFalse);
      expect(keep.existsSync(), isTrue);
      expect(engine.settings.dir, isNull);

      // 记录被改坏、指向的不是专属子目录：即使 owned 也不删。
      await prefs.setPref(
        kIrodoriLocalPrefKey,
        jsonEncode(IrodoriLocalSettings(dir: dir.path, owned: true).toJson()),
      );
      expect(engine.canDeleteFiles, isFalse);
      await engine.remove(deleteFiles: true);
      expect(dir.existsSync(), isTrue);
      engine.dispose();
    });
  });
}
