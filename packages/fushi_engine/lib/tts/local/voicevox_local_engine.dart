/// 「本机 VOICEVOX / AivisSpeech」一键部署：从官方 GitHub Releases 下引擎包、解压、
/// 朗读时自动拉起 `run(.exe) --host 127.0.0.1 --port <port>`、随 app 退出停。
///
/// 两家都是 VOICEVOX ENGINE 血统，发行形态不同（2026-10-30 按 `gh api .../releases/latest`
/// 实查）：
/// - VOICEVOX ENGINE 0.26.0：每个变体一个 `.vvpp`（就是 zip，引擎文件直接在包根），
///   体积超过 2 GB 的 NVIDIA 版拆成 `.001.vvppp` / `.002.vvppp`（按序拼接即原 zip）；
///   另有 `.7z.001` 分卷，这里不用（zip 在三端都有现成的解压器）。
/// - AivisSpeech Engine 1.2.0：每个平台一个 `.7z.001`（单卷 7z，包里一层
///   `<平台>/` 目录）。
///
/// 解压后在两层以内找 `engine_manifest.json`，可执行文件按它的 `command` 字段定位；
/// 探活按 `GET /engine_manifest` 的 `uuid` 与磁盘上那份对上才算（端口上随便一个
/// VOICEVOX 兼容引擎不能被当成自己）。
///
/// 下载走宿主注入的 client（全应用代理）、按 GitHub 给的 sha256 校验、`.part` 断点续传；
/// 失败 / 取消留着 `.part` 下次续，「删除」清整个专属子目录。桌面三端有入口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_package.dart'
    show gptSovitsTarExecutable, systemTarSupports7z;
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;

/// 部署哪一家。
enum VoicevoxLocalKind { voicevox, aivisSpeech }

/// 推理加速。VOICEVOX 的 DirectML / NVIDIA 版要带 `--use_gpu` 启动。
enum VoicevoxAccel { cpu, directml, nvidia }

/// 包格式：zip（`.vvpp` / 拼接后的 `.vvppp`）或 7z。
enum VoicevoxArchiveFormat { zip, sevenZip }

/// 发行包的一个文件（分卷之一）。[sha256] 取自 GitHub Release 资产的 `digest`。
class VoicevoxPackagePart {
  const VoicevoxPackagePart(this.name, this.sizeBytes, this.sha256);

  final String name;
  final int sizeBytes;
  final String sha256;
}

class VoicevoxPackage {
  const VoicevoxPackage({
    required this.accel,
    required this.format,
    required this.parts,
  });

  final VoicevoxAccel accel;
  final VoicevoxArchiveFormat format;

  /// 按拼接顺序。
  final List<VoicevoxPackagePart> parts;

  int get totalBytes =>
      parts.fold<int>(0, (int sum, VoicevoxPackagePart x) => sum + x.sizeBytes);
}

/// 一家引擎的钉版清单：仓库、tag、默认端口、各平台可选的包。
class VoicevoxEngineManifest {
  const VoicevoxEngineManifest({
    required this.kind,
    required this.repo,
    required this.tag,
    required this.defaultPort,
    required this.installSubdir,
    required this.packages,
  });

  final VoicevoxLocalKind kind;

  /// `owner/name`。
  final String repo;
  final String tag;
  final int defaultPort;

  /// 安装目录下的专属子目录名（「删除」只删它）。
  final String installSubdir;

  /// 平台键（[voicevoxPlatformKey]）→ 可选的包（第一个是默认）。
  final Map<String, List<VoicevoxPackage>> packages;

  Uri url(VoicevoxPackagePart part) =>
      Uri.parse('https://github.com/$repo/releases/download/$tag/${part.name}');
}

/// 本机平台键：`windows-x64` / `macos-arm64` / `linux-x64` / `linux-arm64`；不支持的
/// （Windows ARM、Intel Mac——app 本身只出 Apple Silicon）返回 null。
String? voicevoxPlatformKey({String? os, String? arch}) {
  final String system = os ?? Platform.operatingSystem;
  final String cpu = (arch ?? _hostArch()).toLowerCase();
  final bool arm = cpu.contains('arm64') || cpu.contains('aarch64');
  return switch (system) {
    'windows' when !arm => 'windows-x64',
    'macos' when arm => 'macos-arm64',
    'linux' => arm ? 'linux-arm64' : 'linux-x64',
    _ => null,
  };
}

String _hostArch() {
  // Dart 没有直接给架构的 API：`Platform.version` 末尾形如 `on "windows_x64"`。
  final RegExpMatch? m = RegExp(
    r'"[a-z]+_([a-z0-9]+)"',
  ).firstMatch(Platform.version);
  return m?.group(1) ?? '';
}

const VoicevoxEngineManifest kVoicevoxManifest = VoicevoxEngineManifest(
  kind: VoicevoxLocalKind.voicevox,
  repo: 'VOICEVOX/voicevox_engine',
  tag: '0.26.0',
  defaultPort: 50021,
  installSubdir: 'voicevox_engine',
  packages: <String, List<VoicevoxPackage>>{
    'windows-x64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-windows-cpu-0.26.0.vvpp',
            1925791376,
            '80efdaace0b6b0016727ba5e33833ffa1e0d055500b24d779a53ccde1469a8da',
          ),
        ],
      ),
      VoicevoxPackage(
        accel: VoicevoxAccel.directml,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-windows-directml-0.26.0.vvpp',
            1936066614,
            '7c2f85dfb88160c902297e5d7002ce781a48167e7f28def7a1f10f11390f9bec',
          ),
        ],
      ),
      VoicevoxPackage(
        accel: VoicevoxAccel.nvidia,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-windows-nvidia-0.26.0.001.vvppp',
            1992294400,
            'c61008f9558f6c801506b9fa8a1935c67929f6a3e68bb318222d90fb0c48ff26',
          ),
          VoicevoxPackagePart(
            'voicevox_engine-windows-nvidia-0.26.0.002.vvppp',
            1506838967,
            'c35c15c20e7b588f81fe0c694e5cf9ef21138363ab6e913981545ff778306673',
          ),
        ],
      ),
    ],
    'macos-arm64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-macos-arm64-0.26.0.vvpp',
            1925582689,
            '361dcb631617e050211c3a243583d1e911960c5296f18591521f8355fa294ad5',
          ),
        ],
      ),
    ],
    'linux-x64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-linux-cpu-x64-0.26.0.vvpp',
            1944635675,
            'bdb5109c8a84125261af10f92b811304256ad3233c1c9dfe8eb3e0e2d8739a23',
          ),
        ],
      ),
      VoicevoxPackage(
        accel: VoicevoxAccel.nvidia,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-linux-nvidia-0.26.0.001.vvppp',
            1992294400,
            'fe0583dbe56b84dc70dbfcae01e8ea2bb8810f58cfc25f661e42bbb01fd63373',
          ),
          VoicevoxPackagePart(
            'voicevox_engine-linux-nvidia-0.26.0.002.vvppp',
            1563748265,
            'dcba04c8f5054fd92ab015417b315d3f351591f6ac96c86e37c7ef117adb2ded',
          ),
        ],
      ),
    ],
    'linux-arm64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.zip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'voicevox_engine-linux-cpu-arm64-0.26.0.vvpp',
            1939650731,
            '9bba2207bb1128716d21cd9ac8b7b638c07e20106d96977cdc9fcf21186b9872',
          ),
        ],
      ),
    ],
  },
);

const VoicevoxEngineManifest kAivisSpeechManifest = VoicevoxEngineManifest(
  kind: VoicevoxLocalKind.aivisSpeech,
  repo: 'Aivis-Project/AivisSpeech-Engine',
  tag: '1.2.0',
  defaultPort: 10101,
  installSubdir: 'aivis_speech_engine',
  packages: <String, List<VoicevoxPackage>>{
    'windows-x64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.sevenZip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'AivisSpeech-Engine-Windows-x64-1.2.0.7z.001',
            216525495,
            'bfbceba2e14dc7f23c7f3695f9ac0381baf91b15d6544e98384574eaadd271f3',
          ),
        ],
      ),
    ],
    'macos-arm64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.sevenZip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'AivisSpeech-Engine-macOS-arm64-1.2.0.7z.001',
            203306908,
            '581a7f34afb2c5343ff8b27d6d88859083375868607657de95fad506939185df',
          ),
        ],
      ),
    ],
    'linux-x64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.sevenZip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'AivisSpeech-Engine-Linux-x64-1.2.0.7z.001',
            340613180,
            'a4b1cc790e9a1522d880e063d788ea2c33df909e88e764d8ae5a17e3597b15b5',
          ),
        ],
      ),
    ],
    'linux-arm64': <VoicevoxPackage>[
      VoicevoxPackage(
        accel: VoicevoxAccel.cpu,
        format: VoicevoxArchiveFormat.sevenZip,
        parts: <VoicevoxPackagePart>[
          VoicevoxPackagePart(
            'AivisSpeech-Engine-Linux-arm64-1.2.0.7z.001',
            214367206,
            'a1e439e564e8cd1e5b37e024d27e6e6759cbcdd993fc6d76555c8dd50431d971',
          ),
        ],
      ),
    ],
  },
);

/// 不能用的端口：其它本机服务（Irodori 工作台 7870 / GPT-SoVITS 工作台 7871 /
/// GPT-SoVITS api_v2 9880 / Irodori-TTS-Server 8088）。
const Set<int> kVoicevoxReservedPorts = <int>{7870, 7871, 9880, 8088};

bool voicevoxPortAllowed(int port) =>
    port >= 1024 && port <= 65535 && !kVoicevoxReservedPorts.contains(port);

/// 装好的引擎：引擎根（`engine_manifest.json` 所在目录）与清单内容。
class VoicevoxInstallLayout {
  const VoicevoxInstallLayout({
    required this.root,
    required this.engineDir,
    required this.executable,
    required this.uuid,
    required this.version,
  });

  /// 专属子目录。
  final String root;
  final String engineDir;
  final String executable;
  final String uuid;
  final String version;

  /// 在 [root] 下两层以内找 `engine_manifest.json`（VVPP 在包根，AivisSpeech 的 7z
  /// 多一层平台目录）。找不到 / 清单坏 / 可执行文件不在返回 null。
  static VoicevoxInstallLayout? find(String root, {String? engineDirHint}) {
    final List<String> candidates = <String>[
      if (engineDirHint != null) engineDirHint,
      p.join(root, 'engine'),
    ];
    final Directory engineRoot = Directory(p.join(root, 'engine'));
    if (engineRoot.existsSync()) {
      for (final FileSystemEntity e in engineRoot.listSync()) {
        if (e is Directory) candidates.add(e.path);
      }
    }
    for (final String dir in candidates) {
      final VoicevoxInstallLayout? layout = _read(root, dir);
      if (layout != null) return layout;
    }
    return null;
  }

  static VoicevoxInstallLayout? _read(String root, String dir) {
    final File manifest = File(p.join(dir, 'engine_manifest.json'));
    if (!manifest.existsSync()) return null;
    try {
      final Object? json = jsonDecode(manifest.readAsStringSync());
      if (json is! Map) return null;
      final Object? uuid = json['uuid'];
      if (uuid is! String || uuid.isEmpty) return null;
      final Object? command = json['command'];
      final String exe = command is String && command.isNotEmpty
          ? command
          : (Platform.isWindows ? 'run.exe' : 'run');
      final String executable = p.join(dir, exe);
      if (!File(executable).existsSync()) return null;
      return VoicevoxInstallLayout(
        root: root,
        engineDir: dir,
        executable: executable,
        uuid: uuid,
        version: '${json['version'] ?? ''}',
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}

enum VoicevoxInstallStep {
  idle,
  downloading,
  joining,
  extracting,
  done,
  failed,
  cancelled,
}

enum VoicevoxInstallFailure {
  /// 本平台 / 架构没有官方包。
  unsupported,

  /// 没有能解这种包的系统工具（老 Windows 的 tar 没编 lzma；Linux 缺 unzip / 7z）。
  noExtractor,
  network,

  /// 下完 sha256 / 体积对不上。
  corrupt,
  disk,
  extractFailed,

  /// 解完找不到 `engine_manifest.json` / 可执行文件。
  layoutMissing,
}

/// 一条解压命令（[voicevoxExtractCommands] 按平台给候选，依次试到能起的那个）。
class VoicevoxExtractCommand {
  const VoicevoxExtractCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// 解压 [archive] 到 [dest] 的候选命令（纯函数，测试直接调）。
/// - Windows：System32 的 bsdtar（zip 与 7z 都认；7z 要求编进了 lzma，调用方先判）；
/// - macOS：系统 bsdtar；
/// - Linux：GNU tar 不认 zip / 7z，按 unzip → bsdtar → python3（zip）或
///   7z / 7za / 7zz → bsdtar（7z）依次试。
List<VoicevoxExtractCommand> voicevoxExtractCommands({
  required VoicevoxArchiveFormat format,
  required String archive,
  required String dest,
  required String os,
  String? windowsTar,
}) {
  if (os == 'windows') {
    return <VoicevoxExtractCommand>[
      VoicevoxExtractCommand(windowsTar ?? gptSovitsTarExecutable, <String>[
        '-xf',
        archive,
        '-C',
        dest,
      ]),
    ];
  }
  if (os == 'macos') {
    return <VoicevoxExtractCommand>[
      VoicevoxExtractCommand('/usr/bin/tar', <String>[
        '-xf',
        archive,
        '-C',
        dest,
      ]),
    ];
  }
  final VoicevoxExtractCommand bsdtar = VoicevoxExtractCommand(
    'bsdtar',
    <String>['-xf', archive, '-C', dest],
  );
  return switch (format) {
    VoicevoxArchiveFormat.zip => <VoicevoxExtractCommand>[
      VoicevoxExtractCommand('unzip', <String>[
        '-q',
        '-o',
        archive,
        '-d',
        dest,
      ]),
      bsdtar,
      VoicevoxExtractCommand('python3', <String>[
        '-m',
        'zipfile',
        '-e',
        archive,
        dest,
      ]),
    ],
    VoicevoxArchiveFormat.sevenZip => <VoicevoxExtractCommand>[
      for (final String exe in const <String>['7z', '7za', '7zz'])
        VoicevoxExtractCommand(exe, <String>['x', '-y', '-o$dest', archive]),
      bsdtar,
    ],
  };
}

/// 起一个子进程（测试注入）。
typedef VoicevoxSpawn =
    Future<Process> Function(String executable, List<String> arguments);

/// 发一次 GET（下载用；测试注入）。
typedef VoicevoxHttpOpen =
    Future<ResumableDownloadResponse> Function(
      HttpClient client,
      Uri uri,
      Map<String, String> headers,
    );

class VoicevoxInstaller extends EngineChangeNotifier {
  VoicevoxInstaller({
    required HttpClient Function() httpClientFactory,
    required this.manifest,
    LocalCommandRunner? run,
    VoicevoxSpawn? spawn,
    VoicevoxHttpOpen? open,
    String? os,
  }) : _httpClientFactory = httpClientFactory,
       _run = run ?? runLocalCommand,
       _spawn =
           spawn ??
           ((String exe, List<String> args) =>
               HelperProcessRegistry.instance.start(exe, args)),
       _open = open ?? openLocalServiceGet,
       _os = os ?? Platform.operatingSystem;

  final HttpClient Function() _httpClientFactory;
  final VoicevoxEngineManifest manifest;
  final LocalCommandRunner _run;
  final VoicevoxSpawn _spawn;
  final VoicevoxHttpOpen _open;
  final String _os;

  VoicevoxInstallStep step = VoicevoxInstallStep.idle;
  VoicevoxInstallFailure? failure;
  int receivedBytes = 0;
  int? totalBytes;

  /// 当前在下的文件名。
  String? currentItem;

  /// 失败时的技术细节（进日志尾，不直接给用户看）。
  String? detail;

  final List<String> _log = <String>[];
  List<String> get logTail => List<String>.unmodifiable(_log);

  bool get isBusy => switch (step) {
    VoicevoxInstallStep.downloading ||
    VoicevoxInstallStep.joining ||
    VoicevoxInstallStep.extracting => true,
    _ => false,
  };

  bool _cancelled = false;
  HttpClient? _client;
  Process? _extractor;

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > 200) _log.removeAt(0);
  }

  void _set(VoicevoxInstallStep next, [VoicevoxInstallFailure? why]) {
    step = next;
    failure = why;
    if (why != null) {
      _appendLog('failed: ${why.name}${detail == null ? '' : ' ($detail)'}');
    }
    notifyListeners();
  }

  void cancel() {
    if (!isBusy) return;
    _cancelled = true;
    _client?.close(force: true);
    _extractor?.kill();
  }

  VoicevoxInstallLayout? _cancel() {
    _set(VoicevoxInstallStep.cancelled);
    return null;
  }

  /// 下载并解压 [pkg] 到 [root]（专属子目录）。返回装好的布局；失败 / 取消返回 null
  /// （原因在 [failure]）。已下完的分卷不重下，下到一半的从 `.part` 续。
  Future<VoicevoxInstallLayout?> install({
    required String root,
    required VoicevoxPackage pkg,
  }) async {
    if (isBusy) return null;
    _cancelled = false;
    receivedBytes = 0;
    totalBytes = pkg.totalBytes;
    detail = null;
    currentItem = null;
    _log.clear();
    if (pkg.format == VoicevoxArchiveFormat.sevenZip &&
        _os == 'windows' &&
        !await systemTarSupports7z(run: _run)) {
      _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.noExtractor);
      return null;
    }
    final String downloads = p.join(root, 'downloads');
    try {
      await Directory(downloads).create(recursive: true);
    } on FileSystemException catch (e) {
      detail = e.message;
      _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.disk);
      return null;
    }
    final HttpClient client = _httpClientFactory();
    _client = client;
    final List<File> files = <File>[];
    try {
      _set(VoicevoxInstallStep.downloading);
      int done = 0;
      for (final VoicevoxPackagePart part in pkg.parts) {
        final File file = File(p.join(downloads, part.name));
        files.add(file);
        currentItem = part.name;
        if (await file.exists() && await file.length() == part.sizeBytes) {
          done += part.sizeBytes;
          receivedBytes = done;
          notifyListeners();
          continue;
        }
        _appendLog('download ${manifest.url(part)}');
        final int base = done;
        try {
          await ResumableDownloader(
            url: manifest.url(part).toString(),
            destination: file,
            partFile: File('${file.path}.part'),
            open: (Uri uri, Map<String, String> headers) =>
                _open(client, uri, headers),
            expectedSize: part.sizeBytes,
            expectedSha256: part.sha256,
            firstByteTimeout: const Duration(seconds: 60),
            bodyTimeout: const Duration(seconds: 60),
            onProgress: (int received, int? _) {
              receivedBytes = base + received;
              notifyListeners();
            },
          ).download();
        } on ResumableDownloadIntegrityException catch (e) {
          detail = e.message;
          _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.corrupt);
          return null;
        } on FileSystemException catch (e) {
          if (_cancelled) return _cancel();
          detail = e.message;
          _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.disk);
          return null;
        } on Object catch (e) {
          if (_cancelled) return _cancel();
          detail = '$e';
          _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.network);
          return null;
        }
        if (_cancelled) return _cancel();
        done += part.sizeBytes;
        receivedBytes = done;
      }
      if (_cancelled) return _cancel();

      // 分卷 zip（`.vvppp`）按序拼回一个 zip 再解。
      File archive = files.first;
      if (files.length > 1) {
        _set(VoicevoxInstallStep.joining);
        archive = File(p.join(downloads, 'joined.zip'));
        try {
          final IOSink sink = archive.openWrite();
          try {
            for (final File f in files) {
              if (_cancelled) break;
              await sink.addStream(f.openRead());
            }
          } finally {
            await sink.close();
          }
        } on FileSystemException catch (e) {
          detail = e.message;
          _deleteQuietly(archive);
          _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.disk);
          return null;
        }
        if (_cancelled) {
          _deleteQuietly(archive);
          return _cancel();
        }
      }

      _set(VoicevoxInstallStep.extracting);
      // 解到全新的 engine/ 下：旧版本（换加速重装）先清掉，免得新旧文件混在一起。
      final Directory engineDir = Directory(p.join(root, 'engine'));
      try {
        if (engineDir.existsSync()) await engineDir.delete(recursive: true);
        await engineDir.create(recursive: true);
      } on FileSystemException catch (e) {
        detail = e.message;
        _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.disk);
        return null;
      }
      final bool? extracted = await _extract(
        pkg.format,
        archive.path,
        engineDir.path,
      );
      if (files.length > 1) _deleteQuietly(archive);
      if (_cancelled) return _cancel();
      if (extracted == null) {
        _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.noExtractor);
        return null;
      }
      if (!extracted) {
        _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.extractFailed);
        return null;
      }
      final VoicevoxInstallLayout? layout = VoicevoxInstallLayout.find(root);
      if (layout == null) {
        _set(VoicevoxInstallStep.failed, VoicevoxInstallFailure.layoutMissing);
        return null;
      }
      if (_os != 'windows') {
        // python3 -m zipfile 不保留可执行位；其余解压器保留，补一次无害。
        await _run('chmod', <String>['+x', layout.executable]);
      }
      // 解完就删包：2 GB 的包留着没用。
      for (final File f in files) {
        _deleteQuietly(f);
      }
      _set(VoicevoxInstallStep.done);
      return layout;
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 被占用：留给「删除」整个目录时一起清。
    }
  }

  /// 依次试候选解压器。全部起不来返回 null（没有解压器）；起来了返回是否成功。
  Future<bool?> _extract(
    VoicevoxArchiveFormat format,
    String archive,
    String dest,
  ) async {
    for (final VoicevoxExtractCommand cmd in voicevoxExtractCommands(
      format: format,
      archive: archive,
      dest: dest,
      os: _os,
    )) {
      final Process process;
      try {
        process = await _spawn(cmd.executable, cmd.arguments);
      } on ProcessException catch (e) {
        _appendLog('${cmd.executable}: ${e.message}');
        continue;
      }
      _extractor = process;
      _appendLog('extract with ${cmd.executable}');
      final Future<void> out = process.stdout.drain<void>();
      final Future<void> err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((String line) {
            if (line.trim().isNotEmpty) _appendLog(line);
          })
          .asFuture<void>();
      final int code = await process.exitCode;
      await Future.wait(<Future<void>>[
        out,
        err,
      ]).catchError((Object _) => <void>[]);
      _extractor = null;
      if (code != 0) detail = 'extract exit $code';
      return code == 0;
    }
    return null;
  }
}

/// 设备本地设置：`{dir, port, accel, owned}`（不进同步 / 备份）。
class VoicevoxLocalSettings {
  const VoicevoxLocalSettings({
    required this.port,
    this.dir,
    this.accel,
    this.owned = false,
  });

  final String? dir;
  final int port;

  /// 用户选的加速；null = 用平台默认（第一个包）。
  final VoicevoxAccel? accel;
  final bool owned;

  VoicevoxLocalSettings copyWith({
    String? dir,
    bool clearDir = false,
    int? port,
    VoicevoxAccel? accel,
    bool? owned,
  }) => VoicevoxLocalSettings(
    dir: clearDir ? null : (dir ?? this.dir),
    port: port ?? this.port,
    accel: accel ?? this.accel,
    owned: owned ?? this.owned,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (dir != null) 'dir': dir,
    'port': port,
    if (accel != null) 'accel': accel!.name,
    'owned': owned,
  };

  static VoicevoxLocalSettings fromJson(Object? raw, int defaultPort) {
    if (raw is! Map) return VoicevoxLocalSettings(port: defaultPort);
    final Object? dir = raw['dir'];
    final Object? port = raw['port'];
    return VoicevoxLocalSettings(
      dir: dir is String && dir.isNotEmpty ? dir : null,
      port: port is int && voicevoxPortAllowed(port) ? port : defaultPort,
      accel: VoicevoxAccel.values
          .where((VoicevoxAccel a) => a.name == raw['accel'])
          .firstOrNull,
      owned: raw['owned'] == true,
    );
  }
}

/// 探活：`GET /engine_manifest` 的 uuid 与 [expectedUuid] 一致才算就绪。
Future<bool> voicevoxProbe(
  HttpClient Function() clientFactory,
  int port,
  String? expectedUuid,
) async {
  if (expectedUuid == null) return false;
  final HttpClient client = clientFactory()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/engine_manifest'),
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((Object _) {});
      return false;
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 5),
    )) {
      bytes.add(chunk);
      if (bytes.length > 4 * 1024 * 1024) return false;
    }
    return voicevoxManifestMatches(
      utf8.decode(bytes.takeBytes(), allowMalformed: true),
      expectedUuid,
    );
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// `/engine_manifest` 响应是不是 [uuid] 这台引擎（纯函数，测试直接调）。
bool voicevoxManifestMatches(String body, String uuid) {
  try {
    final Object? json = jsonDecode(body);
    return json is Map && json['uuid'] == uuid;
  } on FormatException {
    return false;
  }
}

/// 本机 VOICEVOX / AivisSpeech 的应用级门面（与 `IrodoriLocalEngine` 同形）。
class VoicevoxLocalEngine extends EngineChangeNotifier {
  VoicevoxLocalEngine({
    required PrefStore prefs,
    required HttpClient Function() httpClientFactory,
    required this.manifest,
    Future<Map<String, String>> Function()? childProxyEnvironment,
    VoicevoxInstaller? installer,
    LocalServiceProcess? server,
    String? platformKey,
    bool? supported,
  }) : _prefs = prefs,
       _childProxyEnvironment = childProxyEnvironment,
       platformKey = platformKey ?? voicevoxPlatformKey(),
       installer =
           installer ??
           VoicevoxInstaller(
             httpClientFactory: httpClientFactory,
             manifest: manifest,
           ) {
    this.server =
        server ??
        LocalServiceProcess(
          probe: (int port) =>
              voicevoxProbe(httpClientFactory, port, layout?.uuid),
          pidFileName: '.fushi_${manifest.installSubdir}.pid',
          // 首次启动要加载声学模型（AivisSpeech 还会先下默认模型）。
          readyTimeout: const Duration(minutes: 10),
          portReleaseTimeout: const Duration(seconds: 10),
        );
    isSupported =
        supported ??
        ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
            this.platformKey != null &&
            manifest.packages.containsKey(this.platformKey));
    this.installer.addListener(notifyListeners);
    this.server.addListener(notifyListeners);
  }

  final PrefStore _prefs;
  final Future<Map<String, String>> Function()? _childProxyEnvironment;
  final VoicevoxEngineManifest manifest;
  final String? platformKey;
  final VoicevoxInstaller installer;
  late final LocalServiceProcess server;
  late final bool isSupported;

  String get prefKey => 'tts_${manifest.installSubdir}_local';

  VoicevoxLocalSettings get settings {
    final Object? raw = _prefs.getPref(prefKey, defaultValue: '');
    if (raw is! String || raw.isEmpty) {
      return VoicevoxLocalSettings(port: manifest.defaultPort);
    }
    try {
      return VoicevoxLocalSettings.fromJson(
        jsonDecode(raw),
        manifest.defaultPort,
      );
    } on FormatException {
      return VoicevoxLocalSettings(port: manifest.defaultPort);
    }
  }

  Future<void> _save(VoicevoxLocalSettings next) async {
    await _prefs.setPref(prefKey, jsonEncode(next.toJson()));
    _layoutCache = null;
    _layoutCacheDir = null;
    notifyListeners();
  }

  /// 本平台可选的包（第一个是默认）。
  List<VoicevoxPackage> get packages =>
      manifest.packages[platformKey] ?? const <VoicevoxPackage>[];

  /// 实际要装的包：用户选的加速 → 平台默认。
  VoicevoxPackage? get selectedPackage {
    final List<VoicevoxPackage> all = packages;
    if (all.isEmpty) return null;
    final VoicevoxAccel? want = settings.accel;
    return all.where((VoicevoxPackage x) => x.accel == want).firstOrNull ??
        all.first;
  }

  Future<void> setAccel(VoicevoxAccel accel) =>
      _save(settings.copyWith(accel: accel));

  Future<bool> setPort(int port) async {
    if (!voicevoxPortAllowed(port)) return false;
    _autoStartBlocked = false;
    if (server.phase != LocalServicePhase.stopped) await server.stop();
    await _save(settings.copyWith(port: port));
    return true;
  }

  bool _autoStartBlocked = false;
  bool get autoStartBlocked => _autoStartBlocked;

  VoicevoxInstallLayout? _layoutCache;
  String? _layoutCacheDir;

  /// 可用的安装（引擎清单与可执行文件都在）；没装 / 被删返回 null。
  VoicevoxInstallLayout? get layout {
    final String? dir = settings.dir;
    if (dir == null) return null;
    final VoicevoxInstallLayout? cached = _layoutCache;
    if (cached != null &&
        _layoutCacheDir == dir &&
        File(cached.executable).existsSync()) {
      return cached;
    }
    final VoicevoxInstallLayout? found = VoicevoxInstallLayout.find(dir);
    _layoutCache = found;
    _layoutCacheDir = dir;
    return found;
  }

  bool get isInstalled => layout != null;

  bool get canDeleteFiles {
    final VoicevoxLocalSettings s = settings;
    final String? dir = s.dir;
    return s.owned && dir != null && p.basename(dir) == manifest.installSubdir;
  }

  String get endpoint => 'http://127.0.0.1:${settings.port}';

  String defaultInstallDir(Directory supportRoot) =>
      p.join(supportRoot.path, 'tts_engines');

  Future<bool> install({required String installDir}) async {
    final VoicevoxPackage? pkg = selectedPackage;
    if (pkg == null) return false;
    _autoStartBlocked = false;
    if (server.phase != LocalServicePhase.stopped) await server.stop();
    final String root = p.join(installDir, manifest.installSubdir);
    // 先记目录：下到一半的东西在专属子目录里，「删除」要能找到它清掉。
    await _save(settings.copyWith(dir: root, owned: true, accel: pkg.accel));
    final VoicevoxInstallLayout? installed = await installer.install(
      root: root,
      pkg: pkg,
    );
    _layoutCache = null;
    notifyListeners();
    return installed != null;
  }

  Future<void> remove({required bool deleteFiles}) async {
    installer.cancel();
    await server.stop();
    _autoStartBlocked = false;
    final VoicevoxLocalSettings current = settings;
    final bool deletable = canDeleteFiles;
    await _save(current.copyWith(clearDir: true, owned: false));
    final String? dir = current.dir;
    if (deleteFiles && deletable && dir != null) {
      try {
        await Directory(dir).delete(recursive: true);
      } on FileSystemException {
        // 文件被占用：已经忘掉了，剩下的让用户自己删。
      }
    }
  }

  /// 启动参数（纯函数式：只读设置与布局）。
  LocalServiceLaunchSpec launchSpec(
    VoicevoxInstallLayout layout, {
    Map<String, String> environment = const <String, String>{},
  }) {
    final VoicevoxLocalSettings s = settings;
    final VoicevoxAccel accel = selectedPackage?.accel ?? VoicevoxAccel.cpu;
    return LocalServiceLaunchSpec(
      executable: layout.executable,
      arguments: <String>[
        '--host',
        '127.0.0.1',
        '--port',
        '${s.port}',
        if (manifest.kind == VoicevoxLocalKind.voicevox &&
            accel != VoicevoxAccel.cpu)
          '--use_gpu',
      ],
      workingDirectory: layout.engineDir,
      port: s.port,
      environment: <String, String>{
        ...environment,
        // 中文 Windows 控制台是 GBK：引擎（PyInstaller 打包的 Python）打日文日志会抛。
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
      },
    );
  }

  Future<bool> start() {
    _autoStartBlocked = false;
    return _launch();
  }

  Future<bool> _launch() async {
    final VoicevoxInstallLayout? found = layout;
    if (found == null) return false;
    // AivisSpeech 首次启动会从 AivisHub 下默认模型：经本机中继走 app 代理。
    final Map<String, String> env =
        await (_childProxyEnvironment?.call() ??
            Future<Map<String, String>>.value(const <String, String>{}));
    return server.start(launchSpec(found, environment: env));
  }

  Future<void> stop() => server.stop();

  /// 退出 app 时调用：停服务、取消进行中的安装（解压子进程一并杀掉）。
  Future<void> shutdown() async {
    installer.cancel();
    await server.stop();
  }

  Future<void> ensureRunningFor(String endpoint) async {
    if (!isSupported || !isInstalled || server.isRunning) return;
    if (_autoStartBlocked || installer.isBusy) return;
    if (!localServiceEndpointIsManaged(endpoint, settings.port)) return;
    final bool ok = await _launch();
    if (!ok && server.phase == LocalServicePhase.failed) {
      _autoStartBlocked = true;
    }
  }

  @override
  void dispose() {
    installer.removeListener(notifyListeners);
    server.removeListener(notifyListeners);
    server.dispose();
    installer.dispose();
    super.dispose();
  }
}

/// 注册表里替换 [VoicevoxTtsDescriptor] 的版本：合成 / 列声音前先确保本机托管的
/// 服务在跑。id、参数表、缓存键不变。
class AutoStartVoicevoxTtsDescriptor extends VoicevoxTtsDescriptor {
  const AutoStartVoicevoxTtsDescriptor(this.engine);

  final VoicevoxLocalEngine engine;

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      AutoStartTtsProvider(
        super.create(preset, host),
        () => engine.ensureRunningFor(
          preset.param(
            VoicevoxCompatibleTtsDescriptor.endpointKey,
            fallback: defaultEndpoint,
          ),
        ),
      );
}

/// 同上，[AivisSpeechTtsDescriptor] 版。
class AutoStartAivisSpeechTtsDescriptor extends AivisSpeechTtsDescriptor {
  const AutoStartAivisSpeechTtsDescriptor(this.engine);

  final VoicevoxLocalEngine engine;

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      AutoStartTtsProvider(
        super.create(preset, host),
        () => engine.ensureRunningFor(
          preset.param(
            VoicevoxCompatibleTtsDescriptor.endpointKey,
            fallback: defaultEndpoint,
          ),
        ),
      );
}
